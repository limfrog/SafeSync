import Foundation
import Darwin

/// A path is not a volume identity. In particular, an unmounted NAS/USB path
/// must not silently become a new empty directory with deletion authority.
struct LocalRootGuard: Sendable {
    let configuredPath: String
    let root: URL
    let identity: String

    init(_ path: String, expected: String? = nil) throws {
        configuredPath = path
        root = BackupEngine.canonical(path)
        identity = try Self.directoryIdentity(root)
        if let expected, identity != expected {
            throw BackupError.unsafe("폴더 또는 연결된 저장장치가 이전 백업과 다릅니다. 기존 백업을 보존합니다: \(path)")
        }
    }

    private static func token(_ info: Darwin.stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    private static func directoryIdentity(_ url: URL) throws -> String {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard UInt32(info.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              access(url.path, R_OK | X_OK) == 0 else {
            throw BackupError.unsafe("폴더를 읽을 수 없거나 폴더 종류가 변경되었습니다: \(url.path)")
        }
        return token(info)
    }

    func verify() throws {
        guard BackupEngine.canonical(configuredPath).path == root.path,
              try Self.directoryIdentity(root) == identity else {
            throw BackupError.unsafe("작업 중 폴더 또는 저장장치 연결이 변경되었습니다. 기존 백업을 보존합니다: \(configuredPath)")
        }
    }

    /// Only ENOENT through accessible, no-follow directory handles means absent.
    /// Permission errors, ENOTDIR and symlink substitutions are never deletions.
    func confirmedMissing(_ path: String) throws -> Bool {
        try FileComparisons.validatePath(path)
        try verify()
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var opened = Darwin.stat()
        guard fstat(fd, &opened) == 0, Self.token(opened) == identity else {
            throw BackupError.unsafe("원본 폴더의 연결이 변경되어 삭제를 보류합니다.")
        }
        let parts = path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            guard faccessat(fd, ".", R_OK | X_OK, 0) == 0 else {
                throw BackupError.unsafe("원본 상위 폴더의 접근 권한을 확인할 수 없어 삭제를 보류합니다.")
            }
            var info = Darwin.stat()
            if fstatat(fd, part, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                let code = errno
                guard code == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
                try verify()
                return true
            }
            let kind = UInt32(info.st_mode) & UInt32(S_IFMT)
            guard kind != UInt32(S_IFLNK) else { throw BackupError.unsafe("심볼릭 링크로 변경된 원본은 삭제로 처리하지 않습니다.") }
            if index == parts.count - 1 { try verify(); return false }
            guard kind == UInt32(S_IFDIR) else { throw BackupError.unsafe("원본 상위 경로가 폴더가 아니므로 삭제를 보류합니다.") }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            Darwin.close(fd); fd = next
        }
        return false
    }
}
