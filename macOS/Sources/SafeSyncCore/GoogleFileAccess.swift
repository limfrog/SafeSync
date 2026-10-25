import Foundation

public enum GoogleFileAccess {
    public static let scope = "https://www.googleapis.com/auth/drive.file"
    public static let mode = "drive-file-v1"
    public static let folderKey = "safesyncAccess"
    public static func validateScope(_ value: String?) throws {
        guard value?.split(separator: " ").map(String.init) == [scope] else {
            throw BackupError.unsafe("Google Drive 제한 권한을 확인하지 못했습니다. Google 계정의 기존 SafeSync 접근 권한을 해제한 뒤 다시 연결하세요.")
        }
    }
    public static func validateAccount(_ account: CloudAccount) throws {
        guard account.accessMode == mode else { throw BackupError.unsafe("환경설정에서 Google Drive 계정을 제한 권한으로 다시 연결하세요. 이전 백업은 보존됩니다.") }
    }
    public static func validateJob(_ job: BackupJob) throws {
        guard job.cloudAccessMode == mode, job.mode == .oneWay else { throw BackupError.unsafe("이전 Google Drive 작업은 새 전용 폴더로 다시 연결해 단방향 백업으로 저장하세요. 이전 백업과 스냅샷은 보존됩니다. 양방향은 Drive 데스크톱 폴더를 로컬 위치로 지정하세요.") }
    }
}
