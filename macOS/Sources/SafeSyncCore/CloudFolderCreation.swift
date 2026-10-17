import Foundation

public enum CloudFolderCreation {
    public static func validatedName(_ proposed: String) throws -> String {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BackupError.unsafe("폴더 이름을 입력하세요.") }
        guard name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BackupError.unsafe("폴더 이름에 경로 구분자나 제어 문자를 사용할 수 없습니다.")
        }
        guard !name.lowercased().hasPrefix(".safesync-") else {
            throw BackupError.unsafe(".safesync-로 시작하는 이름은 SafeSync 내부용으로 사용합니다.")
        }
        return name
    }
    public static func create(name proposed: String, parent: String, storage: any RemoteStorage) async throws -> RemoteItem {
        let name = try validatedName(proposed)
        // Include files, not just the picker's visible folders. Drive allows duplicate names,
        // but creating one here would make the backup destination ambiguous.
        let siblings = try await storage.children(parent)
        guard !siblings.contains(where: { storage.provider == .dropbox ? $0.name.caseInsensitiveCompare(name) == .orderedSame : $0.name == name }) else {
            throw BackupError.unsafe("같은 이름의 파일 또는 폴더가 있습니다. 다른 이름을 입력하세요.")
        }
        try Task.checkCancellation()
        let folder = try await storage.createFolder(name: name, parent: parent)
        guard folder.folder else { throw BackupError.unsafe("생성된 폴더를 확인할 수 없습니다. 목록을 새로고침하세요.") }
        return folder
    }
}
