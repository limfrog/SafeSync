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
        historyReady = since == nil
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, ids in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            if (0..<count).contains(where: { flags[$0] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 }) { watcher.historyReady = true }
            watcher.changed((0..<min(count, paths.count)).map { Event(path: paths[$0], id: ids[$0], flags: flags[$0]) })
        }
        let options = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2, FSEventStreamCreateFlags(options))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); isOperational = FSEventStreamStart(stream) }
    }
    // Never synchronously flush on the main callback queue. Awaiting lets queued events reach Store first.
    @MainActor public func flushPendingEvents() async -> Bool {
        guard isOperational, stream != nil else { return false }
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                self.flushStream()
                withExtendedLifetime(self) { continuation.resume() }
            }
        }
        return isOperational && historyReady
    }
    private func flushStream() { if let stream { FSEventStreamFlushSync(stream) } }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}
