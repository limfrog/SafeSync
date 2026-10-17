# SafeSync 개발 인계 — Windows 1.9.12

## macOS 진행 현황 — 2026-10-17

macOS 0.2.4 구현은 `macOS/`에 있으며 배포본은 `dist/SafeSync-macOS-0.2.4-universal.zip`입니다. 아래 Windows 인계 내용은 초기 기준 자료입니다. 현재 맥의 사용·빌드·검증 범위는 [macOS 안내](macOS/README-ko.md)와 [검증 현황](macOS/STATUS.md)을 우선 참고하세요. Windows 실행 코드와 배포본은 그대로 보존합니다.

## 기준과 범위

이 저장소의 Windows 앱은 `outputs/SafeSync/SafeSync.ps1`의 `AppVersion = '1.9.12'`를 기준으로 합니다. 소스는 Windows PowerShell 5.1, WPF/XAML 및 .NET Framework 기반이며, `work/packaging/`의 C# 런처·설치 도구로 배포합니다. 이 코드는 macOS에서 그대로 실행되지 않습니다.

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

Windows 1.9.12의 모든 기능이 macOS에서 검증된 것은 아닙니다. 이 저장소의 테스트 스크립트는 Windows 회귀 검사이며, 맥용 앱의 테스트를 대신하지 않습니다.
