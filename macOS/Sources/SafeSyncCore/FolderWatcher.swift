import Foundation
import CoreServices

/// Cursor and pending paths are persisted by the owner before a backup starts.
// State and callbacks belong to the main queue. The immutable stream alone may be flushed off-main;
// retaining this owner through the flush prevents concurrent stream teardown.
public final class FolderWatcher: @unchecked Sendable {
    public struct Event: Sendable { public var path: String; public var id: UInt64; public var flags: FSEventStreamEventFlags }
    public private(set) var isOperational = false
    public private(set) var historyReady = false
    private var stream: FSEventStreamRef?
    private let changed: ([Event]) -> Void
    public init(paths: [String], since: UInt64?, changed: @escaping ([Event]) -> Void) {
        self.changed = changed
        guard !paths.isEmpty else { return }
        // SinceNow has no HistoryDone callback and can falsely report readiness
        // while the daemon is still subscribing. Replay from a concrete cursor
        // instead; until its sentinel arrives the owner must inventory the roots.
        let cursor = since ?? FSEventsGetCurrentEventId()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if (0..<count).contains(where: { flags[$0] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }) { watcher.historyReady = true }
            watcher.changed((0..<min(count, paths.count)).map { Event(path: paths[$0], id: ids[$0], flags: flags[$0]) })
        }
        let options = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        let canonicalPaths = paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        stream = FSEventStreamCreate(nil, callback, &context, canonicalPaths as CFArray, cursor, 2, FSEventStreamCreateFlags(options))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); isOperational = FSEventStreamStart(stream) }
    }
    // Never synchronously flush on the main callback queue. Awaiting lets queued events reach Store first.
    @MainActor public func flushPendingEvents() async -> Bool {
        guard isOperational, stream != nil else { return false }
        let wasReady = historyReady
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.flushStream()
                DispatchQueue.main.async { [self] in
                    withExtendedLifetime(self) { continuation.resume() }
                }
            }
        }
        // A flush cannot retroactively certify an inventory made before initial
        // subscription. Also, flushing only drains daemon-queued events; manual
        // runs explicitly scan and later events remain in the owner's journal.
        return isOperational && wasReady && historyReady
    }
    private func flushStream() { if let stream { FSEventStreamFlushSync(stream) } }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
