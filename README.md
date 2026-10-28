# SafeSync

SafeSync는 Windows와 macOS용 자동 백업 프로그램입니다. 개발자 및 운영자는 **Horizon Entertainment**, 문의 이메일은 **apps@horizonent.co.kr**입니다. Windows는 **1.0.0-preview.29 공개 프리뷰**, macOS는 **0.3.25 공개 프리뷰**입니다. 정식 안정판이나 클라우드 공개 심사 완료를 뜻하지 않습니다.


공개 프리뷰 29는 설치·시작 화면의 오래된 개발 문구와 배포 자료를 정리합니다. 설정·계정·스냅샷 호환, 백업 안전 검증, 선택형 상세 로그는 유지합니다. 로컬·NAS·Dropbox는 단방향/양방향, Google Drive는 제한 권한으로 앱 관리 폴더에 단방향 백업합니다.

- [버전별 Release Notes](https://www.horizonent.co.kr/apps/safesync/release-notes.php)
- [보호·복원·검증·VSS 사용법](RECOVERY-GUIDE.md)
- [이번 변경의 검증 결과](windows-v2/PREVIEW29-VALIDATION.md)
- [상세 로그 켜기/끄기와 분석 기준](windows-v2/OPERATION-LOGS.md)

- [macOS 0.3.25 다운로드 — Apple Silicon·Intel Universal ZIP](dist/SafeSync-macOS-0.3.25-universal.zip)
- [macOS 사용 및 빌드 안내](macOS/README-ko.md)
- [macOS 검증 현황과 남은 차이](macOS/STATUS.md)

- [Windows 1.0.0 Preview 29 설치 파일](dist/SafeSync-Setup-1.0.0-preview.29.exe)
- [Windows 1.0.0 Preview 29 무설치 ZIP](dist/SafeSync-Windows-1.0.0-preview.29.zip)
- [앱 업데이트 사용·배포 안내](windows-v2/UPDATES.md)
- [Windows 사용 및 기능 안내](windows-v2/README-ko.md)
- [남은 정식 출시 조건](windows-v2/RELEASE-VALIDATION.md)
- [홈페이지](https://www.horizonent.co.kr/apps/safesync/)
- [개발·macOS 이식 인계](HANDOFF.md)

## 저장소 구성

- `windows-v2/`: 현재 Windows C#/.NET WPF 앱, 백업 엔진, 설치 도구 및 자동 검사
- `outputs/SafeSync/`: 이식 기준의 이전 PowerShell 소스 및 현재 앱에서도 쓰는 아이콘 자산 (현재 실행 엔진 아님)
- `work/packaging/`, `work/safesync-*-tests.ps1`: 이전 버전의 참고용 빌드·회귀 검사
- `macOS/`: SwiftUI/AppKit 앱, 백업 엔진, 원본 아이콘과 자동 검사
- `dist/`: Windows 설치/무설치 배포본과 macOS Universal 앱 ZIP
- `index.html`, `privacy.html`: GitHub Pages용 안내 및 개인정보처리방침

## Windows 빌드

현재 Windows 앱은 .NET WPF 데스크톱 앱입니다. 로컬·NAS·Dropbox의 단방향/양방향과 Google Drive 제한 권한 단방향 백업, 검증 복사·휴지통·충돌 처리·변경분 비교를 지원합니다. 양방향은 백업 위치의 삭제도 원본으로 전파하므로 독립 백업을 유지하세요. Dropbox 등록 App Key는 포함되어 있지만 Production 승인은 별도입니다. Google OAuth 클라이언트 설정/공개 검증도 별도입니다.

.NET 10 SDK와 Windows 런타임이 있는 개발 환경에서 `windows-v2/scripts/Build.ps1 -RunTests -BundleRuntime`을 실행합니다. 실행용 .NET 런타임이 포함된 EXE 설치본/ZIP이 생성됩니다. 개발용 빌드 스크립트만 PowerShell을 사용하며 앱이 PowerShell을 로드하지 않습니다. 설치 부트스트랩은 .NET Framework 4.8을 전제로 합니다. 배포본은 아직 코드 서명되지 않았습니다.

`dist/`에는 Windows·macOS 배포 파일과 체크섬을 보관합니다. 최신 버전은 위 다운로드 링크를 사용하세요. 다운로드 전에 SHA-256을 [체크섬 목록](dist/SHA256SUMS.txt)과 대조하세요.

개인 설정, 사용자 OAuth 토큰, 개발자 원본 인증 설정, 실행 로그, 백업 데이터, 테스트용 임시 파일은 저장소에 포함하지 않습니다. 이 저장소를 맥에서 복제해도 Windows에 저장된 작업·스냅샷·클라우드 인증 상태는 자동으로 이전되지 않습니다.

앱의 **파일** 메뉴에서 작업 목록을 JSON으로 내보내거나 다시 가져올 수 있습니다. 내보내기에는 인증 정보와 스냅샷이 포함되지 않습니다. 기존 설정 파일을 직접 가져오면 같은 사용자에서 호환 계정과 스냅샷을 복사 승계하며 작업은 일시정지로 시작합니다. 기존 설치·설정·백업은 자동 변경하지 않습니다.
