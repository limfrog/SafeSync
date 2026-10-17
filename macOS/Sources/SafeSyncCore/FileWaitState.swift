import Foundation
import Darwin

public struct FileWaitState: Codable, Sendable {
    public var firstWait: Date
    public var lastAttempt: Date
    public var attempts: Int
    public var nextAttempt: Date
    public init(now: Date = Date()) {
        firstWait = now; lastAttempt = now; attempts = 1
        nextAttempt = now.addingTimeInterval(30)
    }
    public mutating func attempted(now: Date = Date()) {
        attempts += 1; lastAttempt = now
        nextAttempt = now.addingTimeInterval(min(300, 30 * pow(2, Double(min(4, attempts - 1)))))
    }
}

public enum FileAccess {
    /// macOS locks are advisory: cooperate with locking writers and also verify content after copying.
    public static func readLock(_ file: URL) throws -> Int32 {
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        if flock(fd, LOCK_SH | LOCK_NB) != 0 {
            let code = errno
            if code != ENOTSUP && code != EOPNOTSUPP {
                Darwin.close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        return fd
    }
    public static func unlock(_ fd: Int32) { flock(fd, LOCK_UN); Darwin.close(fd) }
    public static func isBusy(_ error: Error) -> Bool {
        if case BackupError.fileBusy = error { return true }
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain && [Int(EBUSY), Int(EAGAIN), Int(ETXTBSY)].contains(e.code) { return true }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error { return isBusy(underlying) }
        return false
    }
    public static func issue(_ error: Error, jobID: UUID, path: String) -> BackupIssue {
        BackupIssue(jobID: jobID, path: path, reason: error.localizedDescription, conflict: false,
                    waiting: isBusy(error) ? FileWaitState() : nil)
    }
}
