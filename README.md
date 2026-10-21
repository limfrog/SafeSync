# SafeSync

SafeSync는 Windows와 macOS용 자동 백업 프로그램입니다. 개발자 및 운영자는 **Horizon Entertainment**, 문의 이메일은 **apps@horizonent.co.kr**입니다. Windows는 **1.0.0-preview.12 공개 프리뷰**, macOS는 **0.3.8 검증 중 버전**입니다. Windows 네이티브 전환 개발판의 번호를 1.0.0 프리뷰로 재정리했습니다. 정식 안정판이나 클라우드 공개 심사 완료를 뜻하지 않습니다.

- [macOS 0.3.8 다운로드 — Apple Silicon·Intel Universal ZIP](dist/SafeSync-macOS-0.3.8-universal.zip)
- [macOS 사용 및 빌드 안내](macOS/README-ko.md)
- [macOS 검증 현황과 남은 차이](macOS/STATUS.md)

- [Windows 1.0.0 Preview 12 설치 파일](dist/SafeSync-Setup-1.0.0-preview.12.exe)
- [Windows 1.0.0 Preview 12 무설치 ZIP](dist/SafeSync-Windows-1.0.0-preview.12.zip)
- [Windows 사용 및 기능 안내](windows-v2/README-ko.md)
- [프리뷰 12 개발자·문의 정보 변경](windows-v2/PREVIEW12-VALIDATION.md)
- [프리뷰 11 검사 결과](windows-v2/PREVIEW11-VALIDATION.md)
- [프리뷰 11 설치본 검증과 SHA-256](windows-v2/PREVIEW11-PACKAGE-RESULT.md)
- [남은 정식 출시 조건](windows-v2/RELEASE-VALIDATION.md)
- [홈페이지](https://www.horizonent.co.kr/apps/safesync/)
- [개발·macOS 이식 인계](HANDOFF.md)

## Windows 프리뷰 12 변경사항

개발자·운영자·설치 프로그램 게시자를 Horizon Entertainment, 기술 지원·개인정보 관련 문의 이메일을 apps@horizonent.co.kr로 통일했습니다. 앱 정보창·파일 속성·Windows 설치 등록·개인정보처리방침·공개 안내에 반영했습니다. 백업 엔진은 프리뷰 11과 같습니다.

## Windows 프리뷰 11 변경사항

- 비교 대상은 크기·수정 시간이 비슷해도 내용을 검증합니다. 다른 내용을 동일 파일로 건너뛰거나 백업 완료로 기록하지 않습니다.
- 원본 폴더 연결 중단·교체 시 삭제 반영을 차단하고 기존 스냅샷과 재시도 목록을 유지합니다. 중단된 클라우드 삭제 기록도 다시 확인합니다.
- 구버전 스냅샷은 보존하면서 최초 한 번 재검증하므로 업데이트 후 첫 비교가 오래 걸릴 수 있습니다. 이후에는 기존처럼 변경·재시도 대상만 처리합니다.
- 자동 검사 958개·중단 및 복구 검사 941개·설치 도구 검사 34개와 최종 설치 파일 500개 해시 검증을 통과했습니다. 이번 클라우드 장애 재현은 모의 저장소에서 진행했습니다.
- 홈페이지 개별 페이지는 유지하지만 사용자 요청에 따라 별도 공개 지시 전까지 `/apps/` 목록에는 소개하지 않습니다. 버전 배포만으로 목록에 다시 노출하지 않습니다.

## Windows 프리뷰 10 변경사항

- 탭과 중복되는 메인 도구줄의 휴지통 관리·동기화 상태 버튼을 제거했습니다. 해당 기능은 탭과 보기 메뉴에서 이용합니다.
- 환경설정을 공통 탭 제목줄 오른쪽에 배치해 어느 탭에서도 열 수 있습니다.
- 작업 관리와 새 작업 버튼을 왼쪽으로 정렬하고 실행 버튼 그룹과 구분했습니다.
- 핵심 860개·화면 548개·설치 34개 검사와 설치 파일 499개 해시 검증을 통과했습니다. 백업 엔진·작업 설정 형식은 변경하지 않았습니다.

## Windows 프리뷰 9 변경사항

- 백업 작업·동기화 상태·휴지통을 한 창의 탭으로 통합했습니다.
- 활동기록 높이를 드래그로 조절하고 저장하며 메인 문제 해결 아이콘을 제거했습니다.
- Google Drive 중복 이름도 모든 사본의 내용 체크섬이 원본과 같으면 복사 없이 동기화 완료로 처리합니다.
- 다른 내용은 하단 문제 해결에서 양방향 덮어쓰기·둘 다 보관·이번 동기화 제외 또는 중복 이름만 정리를 선택합니다. 추가 사본은 삭제하지 않고 이름을 바꿔 보존합니다.
- 핵심 860개·화면 455개·설치 34개 검사, 설치 파일 499개 해시 검증을 통과했습니다. 실제 사용자 자료의 강제 처리를 검증했다는 의미는 아닙니다.

## 저장소 구성

- `windows-v2/`: 현재 Windows C#/.NET WPF 앱, 백업 엔진, 설치 도구 및 자동 검사
- `outputs/SafeSync/`: 이식 기준의 이전 PowerShell 소스 및 현재 앱에서도 쓰는 아이콘 자산 (현재 실행 엔진 아님)
- `work/packaging/`, `work/safesync-*-tests.ps1`: 이전 버전의 참고용 빌드·회귀 검사
- `macOS/`: SwiftUI/AppKit 앱, 백업 엔진, 원본 아이콘과 자동 검사
- `dist/`: Windows 설치/무설치 배포본과 macOS Universal 앱 ZIP
- `index.html`, `privacy.html`: GitHub Pages용 안내 및 개인정보처리방침

## macOS 0.3.8

0.3.8은 개발자와 문의 이메일을 Horizon Entertainment 및 apps@horizonent.co.kr로 통일하고 빌드 저작권을 갱신했습니다. GitHub macOS 환경에서 Universal 빌드와 서명·번들 검증을 완료했으며 기존 배포본의 Desktop Google 등록 정보를 그대로 보존했습니다. 동기화 기능은 0.3.7과 같습니다.

macOS 14 이상에서 ZIP을 풀고 `SafeSync.app`을 사용합니다. 기존 Windows 아이콘을 사용하며 로컬·외장·마운트된 네트워크 폴더, Dropbox·Google Drive 백업을 지원합니다. 작업 목록 내보내기·가져오기, 사용 중 파일 대기와 즉시 재시도, 수동 증분 백업, 완료 알림음, 클라우드 폴더 선택 창의 **새 폴더** 버튼을 포함합니다. 최신 Windows 1.0.0-preview.10에 맞춰 **백업 작업 / 동기화 상태 / 휴지통** 탭과 공통 환경설정, 실행 이력, 파일 비교·충돌 선택, 원본 휴지통을 제공합니다. **양방향 자동 동기화**도 작업별로 선택할 수 있습니다. 원본 아이콘과 별도 **About SafeSync** 정보 창을 유지합니다. 0.3.7은 일반 사용자용 클라우드 로그인, 창 닫기 시 Dock 숨김, 메뉴 막대 화살표·다크 모드 아웃라인, 전용 메시지 창을 포함하며 Dropbox의 `.DS_Store` 반복 실패를 수정했습니다.

이 배포본은 **ad-hoc 서명**이며 Developer ID 서명·Apple 공증 전입니다. 자동 검사 67개와 Universal 빌드가 통과했지만 실제 클라우드 전송·NAS·잠자기·Intel 실행 검증 등은 남아 있습니다. 확인한 범위는 [검증 현황](macOS/STATUS.md)과 [검사 결과](macOS/TEST-RESULTS.txt)를 참고하세요.

Swift 6 도구체인과 Command Line Tools에서 실행합니다.

```sh
cd macOS
./scripts/check.sh
ARCHITECTURE=universal ./scripts/build-app.sh
```

결과는 `macOS/build/SafeSync.app`입니다. 일반 사용자용 배포본은 SafeSync의 Desktop 앱 등록 정보를 포함하므로 Google Drive/Dropbox 연결 버튼에서 브라우저 로그인만 진행합니다. 개발자 빌드 설정은 [클라우드 배포 안내](macOS/CLOUD-RELEASE.md)를 참고하세요. 사용자 로그인 토큰과 개발자 원본 OAuth JSON은 저장소에 포함하지 않습니다.

## Windows 빌드

현재 Windows 앱은 PowerShell 없이 실행되는 C#/.NET WPF 앱입니다. 단방향 백업과 양방향 동기화, 로컬/NAS/Google Drive/Dropbox, 검증 복사·휴지통·충돌 처리·변경분 비교를 지원합니다. 양방향은 백업 위치의 삭제도 원본으로 전파하므로 독립 백업을 유지하세요. Dropbox 등록 App Key는 포함되어 있지만 Production 승인은 별도입니다. Google OAuth 클라이언트 설정/공개 검증도 별도입니다.

.NET 10 SDK와 Windows 런타임이 있는 개발 환경에서 `windows-v2/scripts/Build.ps1 -RunTests -BundleRuntime`을 실행합니다. 실행용 .NET 런타임이 포함된 EXE 설치본/ZIP이 생성됩니다. 개발용 빌드 스크립트만 PowerShell을 사용하며 앱이 PowerShell을 로드하지 않습니다. 설치 부트스트랩은 .NET Framework 4.8을 전제로 합니다. 배포본은 아직 코드 서명되지 않았습니다.

`dist/`에는 현재 Windows 프리뷰와 보존된 macOS 배포본을 제공합니다. 구버전 Windows 설치본/ZIP 12개는 현재 브랜치에서 제거했습니다. 과거 Git 이력과 이전 macOS 배포본은 유지합니다. 다운로드 전에 SHA-256을 [체크섬 목록](dist/SHA256SUMS.txt)과 대조하세요.

개인 설정, 사용자 OAuth 토큰, 개발자 원본 인증 설정, 실행 로그, 백업 데이터, 테스트용 임시 파일은 저장소에 포함하지 않습니다. 이 저장소를 맥에서 복제해도 Windows에 저장된 작업·스냅샷·클라우드 인증 상태는 자동으로 이전되지 않습니다.

앱의 **파일** 메뉴에서 작업 목록을 JSON으로 내보내거나 다시 가져올 수 있습니다. 내보내기에는 인증 정보와 스냅샷이 포함되지 않습니다. 기존 설정 파일을 직접 가져오면 같은 사용자에서 호환 계정과 스냅샷을 복사 승계하며 작업은 일시정지로 시작합니다. 기존 설치·설정·백업은 자동 변경하지 않습니다.

## 이전 Windows 개발 이력 (현재 다운로드 아님)

버전 1.9.12는 다크모드에서 새 작업·작업 수정 창의 글자, 버튼, 입력창과 백업 방식 선택 목록의 색 대비를 개선했습니다.

버전 1.9.13은 macOS 메인창과 같은 로고·설명·실행 상태 헤더, 주요 작업 버튼, 작업 관리 메뉴, 환경설정 바로가기와 활동 기록 패널을 Windows에 적용했습니다. 창을 좁히거나 활동 기록 높이를 조절해도 하단 표시를 확인할 수 있습니다.

버전 1.9.14는 Windows 메뉴 목록의 기본 흰 테두리와 아이콘 여백을 없애고 라이트·다크 모드에 맞는 둥근 메뉴와 선택 표시를 적용했습니다. 메인창의 휴지통 관리 바로가기와 좁은 창에서의 하단 표시 보정도 포함합니다.

버전 1.9.15는 클라우드 계정 창의 입력란·비밀키·설명·버튼을 라이트·다크 모드에 맞게 조정했습니다. 기본 창 크기를 넓히고 저장·닫기 버튼을 하단에 고정해 일반 크기에서는 스크롤 없이 표시합니다. 휴지통 버튼에도 테마에 맞는 둥근 모양과 상태별 표시를 적용하고, 작업 관리 메뉴의 중복 휴지통 항목은 제거했습니다.
