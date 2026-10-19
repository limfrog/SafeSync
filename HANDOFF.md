# SafeSync 개발 인계

## 현재 Windows 배포 소스 — 1.0.0-preview.10 (2026-10-19)

사용자 요청으로 검증된 preview.10 소스·설치본·검사 문서를 공개한다. 실행 중 앱·계정·작업·스냅샷은 자동으로 변경하지 않는다. macOS 소스·배포본도 유지한다.

- `Views/Main.xaml`: 중복 휴지통·동기화 상태 도구줄 버튼 제거. 환경설정은 탭 페이지 바깥 공통 제목줄 오른쪽이다. 탭 헤더 오른쪽 48픽셀을 예약하고 `PART_SelectedContentHost`를 유지한다. 작업 관리 그룹은 왼쪽이다.
- `DesktopController.cs`: 제거한 버튼의 이벤트·상태 참조를 정리했다. 탭과 보기 메뉴 동작은 유지한다.
- `WorkspaceToolbarSmoke.cs`와 `Dialogs.cs`: 세 탭·두 테마·두 창 크기, 설정 실제 열기/닫기와 탭 유지, 정렬·비겹침·안내문 회귀 검사다.
- 핵심 860개·화면 548개·설치 34개·파일 499개 해시 일치. 최종 결과와 제한은 [PREVIEW10-VALIDATION.md](windows-v2/PREVIEW10-VALIDATION.md)를 참고한다. 엔진·OAuth·설정 형식 변경은 없다. 인증 토큰과 실제 작업 자료는 공개하지 않는다.

아래는 이전 배포 시점의 기록이다.

## 이전 Windows 배포 소스 — 1.0.0-preview.9 (2026-10-19)

검증된 preview.9 소스·설치본·검사 문서를 사용자 요청으로 공개한다. 실행 중인 앱과 실제 계정·작업·스냅샷은 자동으로 변경하지 않는다. 아래 공개 프리뷰 항목은 당시 인계 기록이다.

- UI: `Workspace.cs`가 기존 화면 정의의 내용만 메인창에 장착한다. 백업 작업 / 동기화 상태 / 휴지통 관리 세 탭이며 동기화·휴지통용 정의는 실제 별도 창으로 Show하지 않는다. 설정/계정/확인은 기존 대화상자다. WPF 이름 범위와 종료 취소 핸들러를 유지하므로 이 정의들을 별도 Show로 되돌리지 않는다. `MainLayoutSplitter`는 Rows/PreviousAndNext이며 활동기록 높이를 저장한다.
- 문제 해결: `FileComparisonDialog.cs` 및 하단 UserControl. 동일 중복 파일은 `RemoteDuplicates.IdenticalAsync`에서 모든 물리 사본의 체크섬을 검사한다. `GoogleDriveDuplicates.cs`의 ID 기반 탐색/보존, `FileComparisons.PrepareDuplicatesAsync`의 확인 재검증을 사용한다. 단순 Dictionary 덮어쓰기 선택은 중복 경로 처리 권한이 아니다. 폴더 보존은 해당 폴더의 내부 파일 전체를 포함한다.
- 양방향의 동일 중복 사본에는 삭제 권한 기준을 부여하지 않는다. 비교 후 변경된 파일·계정·루트·사본 집합은 거부한다. 보존된 사본은 `.SafeSync-conflict-...` 이름의 일반 항목이며 다음 양방향 실행 시 원본에도 복사될 수 있다.
- 실계정의 해당 작업은 일반 오류가 아닌 57개 반복 충돌이었다. 카탈로그 중복 경로 12개와 관련 상위 폴더가 포함됐다. 실계정 읽기 전용으로 실제 충돌 파일 3개의 사본 각 2개가 모두 원본과 내용이 같음을 확인했다. 실제 백업을 강제 실행하거나 사본을 정리하지 않았다. 사용자 파일명과 실제 경로는 공개하지 않는다.
- 검사·산출물: `windows-v2/PREVIEW9-VALIDATION.md`, `windows-v2/README-ko.md`, `windows-v2/TEST-RESULTS.md`를 우선 참고한다. 개인정보·계정 토큰·진단 표본 경로가 든 테스트 산출물은 공개하지 않는다.

## 현재 공개 프리뷰 — 2026-10-19

현재 Windows 코드는 `windows-v2/`의 C#/.NET WPF 앱이다. 내부 개발판 2.0.0-preview 번호를 1.0.0-preview.1로 재정리했다. 데이터 폴더 `SafeSync2-Preview`, 설치 경로 `Programs/SafeSync2`와 제어 채널은 기존 프리뷰 호환을 위해 유지한다. 이전 PowerShell 버전의 설정을 자동으로 덮어쓰지 않는다.

- 진입점: `windows-v2/src/SafeSync.App/Program.cs`, `DesktopController.cs`, `Dialogs.cs`, `Views/`
- 엔진: `SafeSync.Core/BackupEngine.cs`, `TwoWayEngine.cs`, `VerifiedFiles.cs`, `Persistence.cs`, `OfflineJournal.cs`
- 클라우드: `SafeSync.Core/Cloud/`, Dropbox 기본 공개 App Key는 Directory.Build.props의 비밀이 아닌 클라이언트 ID
- 빌드/설치: `windows-v2/scripts/Build.ps1`, `Build-Installer.ps1`, `packaging/`
- 검사: `windows-v2/tests/SafeSync.Tests/`, 핵심 448개·UI 316개·설치 33개 통과, Google 양방향 35개·Dropbox 32개·NAS 22단계 통과
- 동작/주의사항: [양방향 및 Dropbox](windows-v2/TWOWAY-AND-DROPBOX.md), [현재 검증](windows-v2/RELEASE-VALIDATION.md), [Dropbox 공개 심사 인계](windows-v2/DROPBOX-PRODUCTION.md)

현재 Windows EXE/ZIP만 dist에서 제공한다. 구 Windows 배포본 12개는 현재 브랜치에서 제거하며 맥 소스/배포본 0.2.4와 0.2.5는 그대로 보존한다. Git 과거 이력은 지우지 않는다. 인증 토큰, 비밀번호, 사용자 설정, 실제 스냅샷과 테스트 자료는 공개하지 않는다. 아래 내용은 이전 개발 이력이다.

## Windows 2.0 C# 전환 — 2026-10-18

`windows-v2/`에 별도의 C#/.NET WPF 전환 검증본을 구현했습니다. 기존 PowerShell 소스와 설치본은 변경하지 않았습니다. preview.2에는 Google Drive·Dropbox OAuth/PKCE·분할 전송·서비스 체크섬·저널 복구·클라우드 휴지통과, 기존 계정/스냅샷/델타 체크포인트의 복사 승계를 추가했습니다. 실제 계정 시험·변경 커서·USN·대규모 성능·정식 설치는 아직 미완료입니다. 코드 지도, 검사 범위와 다음 단계는 [전환 현황](windows-v2/MIGRATION.md), [검증본 안내](windows-v2/README-ko.md), [검사 기록](windows-v2/TEST-RESULTS.md)을 먼저 읽으세요. 정식 배포본 다운로드는 아직 1.9.15를 가리키며 검증본은 GitHub에 자동 업로드하지 않았습니다.

## macOS 진행 현황 — 2026-10-17

macOS 0.2.5 구현은 `macOS/`에 있으며 배포본은 `dist/SafeSync-macOS-0.2.5-universal.zip`입니다. 아래 Windows 인계 내용은 초기 기준 자료입니다. 현재 맥의 사용·빌드·검증 범위는 [macOS 안내](macOS/README-ko.md)와 [검증 현황](macOS/STATUS.md)을 우선 참고하세요. Windows 실행 코드와 배포본은 그대로 보존합니다.

## 기준과 범위

이 저장소의 Windows 앱은 `outputs/SafeSync/SafeSync.ps1`의 `AppVersion = '1.9.15'`를 기준으로 합니다. 소스는 Windows PowerShell 5.1, WPF/XAML 및 .NET Framework 기반이며, `work/packaging/`의 C# 런처·설치 도구로 배포합니다. 이 코드는 macOS에서 그대로 실행되지 않습니다.

`dist/`에는 같은 버전의 설치 EXE와 무설치 ZIP을 보관합니다. Windows에서의 상세 동작은 `outputs/SafeSync/README-ko.md`를 참조하세요. GitHub Pages의 `index.html`과 `privacy.html`은 앱 빌드와 무관한 공개 안내 페이지입니다.

## 핵심 소스 지도

| 위치 | 역할 |
| --- | --- |
| `outputs/SafeSync/SafeSync.ps1` | 작업 설정, 스케줄러, 변경 감지, 스냅샷, 백업 판단, WPF 메인/진행/충돌/휴지통 UI |
| `outputs/SafeSync/SafeSync.Cloud.ps1` | Dropbox·Google Drive OAuth/API, 변경 커서, 업로드·검증·교체 |
| `outputs/SafeSync/SafeSync.Integrity.ps1` | 안전한 파일 복사와 검증, 복구 관련 로직 |
| `outputs/SafeSync/SafeSync.TrashWorker.ps1` | 휴지통 조회·복구·삭제의 백그라운드 작업 |
| `work/packaging/Launcher.cs` | Windows 앱/알림 영역 실행 런처 |
| `work/packaging/InstallerCore.cs`, `InstallerUI.cs`, `Setup.cs`, `Uninstall.cs` | 설치 및 제거 |
| `work/packaging/build.ps1`, `New-TrayIcons.ps1` | 빌드 및 알림 영역 아이콘 생성 |
| `work/safesync-*-tests.ps1` | 부분 기능 회귀 검사 |

## 보존해야 할 동작

- 로컬·외장·네트워크 드라이브와 Dropbox·Google Drive API를 백업 위치로 선택합니다.
- 파일 변경 감지 또는 예약 시간으로 자동 실행하며, 일시정지·재개와 앱 종료 후 변경 감지를 지원합니다.
- 파일의 경로·생성/수정 시간·크기를 비교하고, 충돌은 다른 파일의 백업을 막지 않은 채 사용자에게 별도 처리 선택지를 제공합니다.
- 덮어쓰기는 임시 사본, 크기·체크섬 검증, 안전한 교체와 복구 기록을 거칩니다.
- 삭제·교체된 백업 파일은 SafeSync 휴지통에 보관하고, 보관 기간과 복구·완전 삭제를 관리합니다.
- 진행 창은 독립적이고, 최소화·알림 영역 실행, 사용 중 파일의 재시도, 라이트/다크 모드와 알림음 설정을 제공합니다.

## 사용자 데이터와 보안

Windows 사용자별 설정·인증 정보·스냅샷은 `%LOCALAPPDATA%\SafeSync`에 보관됩니다. 여기에는 OAuth 토큰과 클라우드 연결 정보가 있으므로 **GitHub에 올리면 안 됩니다**. `manifests/`의 스냅샷도 실제 백업 대상 경로를 포함할 수 있습니다. 실제 원본/백업 파일, 로그, 인증 정보, `secrets.key`는 이 저장소에 포함하지 않았습니다.

macOS로 작업을 옮길 때는 저장소를 복제한 뒤 **새로운 macOS 앱 프로젝트**를 만드는 것이 적절합니다. Windows의 DPAPI 암호화 데이터는 맥에서 직접 해독할 수 없으므로 클라우드 계정은 macOS 앱에서 다시 인증해야 합니다. 작업과 스냅샷의 자동 이전은 별도 마이그레이션 설계·검증이 필요하며, 파일을 무작정 복사해서 사용하면 안 됩니다.

## macOS 이식 시 우선 결정할 사항

1. SwiftUI와 필요한 부분의 AppKit으로 데스크톱 UI·메뉴 막대를 구현합니다. Windows WPF 레이아웃의 화면 흐름은 참고할 수 있지만 픽셀 단위 동일성보다 macOS 사용성을 검증합니다.
2. Windows FileSystemWatcher/USN Journal에 대응하는 FSEvents와 재시작 후 변경 추적 방식을 설계합니다. 네트워크 볼륨에서는 이벤트 신뢰성이 다를 수 있으므로 안전한 전체 검사 대체 경로를 둡니다.
3. 임시 파일 작성·체크섬 검증·원자적 교체·휴지통 보관과 실패 복구를 macOS 파일시스템 특성에 맞춰 재구현합니다.
4. Dropbox/Google Drive API의 공통 백업 규칙은 재사용하되 OAuth 리디렉션, 토큰 저장은 macOS Keychain에 맞게 다시 구현합니다.
5. 자동 시작, 파일/네트워크 권한, 앱 서명·공증, 실제 NAS 및 클라우드 계정 테스트를 별도로 확인합니다.

## 시작 순서

1. 맥북에서 이 저장소를 복제하고 이 문서와 `README-ko.md`를 읽습니다.
2. Windows 원본과 macOS 목표 동작의 차이를 표로 정리하고, 로컬 폴더 백업·검증·휴지통부터 작은 테스트로 구현합니다.
3. 변경 감지와 재시작 복구, 클라우드 API, 독립 진행/충돌 UI를 순차적으로 추가합니다.
4. 삭제·덮어쓰기·충돌·네트워크 단절·중간 종료 테스트를 통과한 뒤 서명/공증 배포를 준비합니다.

Windows 1.9.14의 모든 기능이 macOS에서 검증된 것은 아닙니다. 이 저장소의 테스트 스크립트는 Windows 회귀 검사이며, 맥용 앱의 테스트를 대신하지 않습니다.

Windows 1.9.14 메인창은 `macOS/Sources/SafeSyncApp/SafeSyncApp.swift`의 MainView(4398b716 기준) 구성을 반영합니다. `work/safesync-main-layout-tests.ps1`은 빈 목록, 선택·일시정지 동작, 작업 관리 메뉴 전달, 라이트·다크 화면과 좁은 창의 하단 표시를 검증합니다.

Windows 1.9.14는 메인창의 메뉴·컨텍스트 메뉴를 테마별 사용자 지정 템플릿으로 표시하고 휴지통 관리 바로가기를 제공합니다. 좁은 창에서는 실제 클라이언트 영역을 기준으로 활동 기록 높이를 제한합니다.
