# SafeSync

SafeSync는 Windows와 macOS용 개인 자동 백업 프로그램입니다. Windows는 **1.9.14**, macOS는 **0.2.5 검증 중 버전**입니다.

- [macOS 0.2.5 다운로드 — Apple Silicon·Intel Universal ZIP](dist/SafeSync-macOS-0.2.5-universal.zip)
- [macOS 사용 및 빌드 안내](macOS/README-ko.md)
- [macOS 검증 현황과 남은 차이](macOS/STATUS.md)

- [Windows 설치 파일](dist/SafeSync-Setup-1.9.14.exe)
- [Windows 무설치 ZIP](dist/SafeSync-Windows-1.9.14.zip)
- [사용 및 기능 안내](outputs/SafeSync/README-ko.md)
- [개발·macOS 이식 인계](HANDOFF.md)

## 저장소 구성

- `outputs/SafeSync/`: Windows 앱의 PowerShell 소스, 아이콘 원본 및 실행용 설정
- `work/packaging/`: 설치 프로그램, 런처, 아이콘 및 무설치 ZIP의 빌드 소스
- `work/safesync-*-tests.ps1`: 기능별 검증 스크립트
- `macOS/`: SwiftUI/AppKit 앱, 백업 엔진, 원본 아이콘과 자동 검사
- `dist/`: Windows 설치/무설치 배포본과 macOS Universal 앱 ZIP
- `index.html`, `privacy.html`: GitHub Pages용 안내 및 개인정보처리방침

## macOS 0.2.5

macOS 14 이상에서 ZIP을 풀고 `SafeSync.app`을 사용합니다. 기존 Windows 아이콘을 사용하며 로컬·외장·마운트된 네트워크 폴더, Dropbox·Google Drive 백업을 지원합니다. 작업 목록 내보내기·가져오기, 사용 중 파일 대기와 즉시 재시도, 수동 증분 백업, 완료 알림음, 클라우드 폴더 선택 창의 **새 폴더** 버튼을 포함합니다. Windows를 참고한 환경설정과 별도 **About SafeSync** 정보 창을 제공합니다.

이 배포본은 **ad-hoc 서명**이며 Developer ID 서명·Apple 공증 전입니다. 자동 검사 48개와 Universal 빌드가 통과했지만 실제 클라우드 전송·NAS·잠자기·Intel 실행 검증 등은 남아 있습니다. 확인한 범위는 [검증 현황](macOS/STATUS.md)과 [검사 결과](macOS/TEST-RESULTS.txt)를 참고하세요.

Swift 6 도구체인과 Command Line Tools에서 실행합니다.

```sh
cd macOS
./scripts/check.sh
ARCHITECTURE=universal ./scripts/build-app.sh
```

결과는 `macOS/build/SafeSync.app`입니다. Google Drive는 데스크톱 앱 OAuth Client ID/Secret을 앱에서 입력하고 다시 연결합니다. 인증 정보는 저장소에 포함하지 않습니다.

## Windows 빌드

Windows PowerShell 5.1에서 `work/packaging/build.ps1`을 실행합니다. Windows에 포함된 .NET Framework C# 컴파일러가 필요합니다. 빌드 결과는 `outputs/SafeSync-Setup.exe`와 `outputs/SafeSync-Windows.zip`으로 생성됩니다. 배포본에는 코드 서명이 없습니다.

`dist/`의 배포본은 버전별로 보관합니다. 다운로드 전에 SHA-256을 [체크섬 목록](dist/SHA256SUMS.txt)과 대조하세요.

개인 설정, OAuth 토큰·키, 실행 로그, 백업 데이터, 테스트용 임시 파일은 저장소에 포함하지 않습니다. 이 저장소를 맥에서 복제해도 Windows에 저장된 작업·스냅샷·클라우드 인증 상태는 자동으로 이전되지 않습니다.

버전 1.9.11부터 앱의 **파일** 메뉴에서 작업 목록을 JSON으로 내보내거나 다시 가져올 수 있습니다. 내보내기에는 인증 정보와 스냅샷이 포함되지 않습니다.

버전 1.9.12는 다크모드에서 새 작업·작업 수정 창의 글자, 버튼, 입력창과 백업 방식 선택 목록의 색 대비를 개선했습니다.

버전 1.9.13은 macOS 메인창과 같은 로고·설명·실행 상태 헤더, 주요 작업 버튼, 작업 관리 메뉴, 환경설정 바로가기와 활동 기록 패널을 Windows에 적용했습니다. 창을 좁히거나 활동 기록 높이를 조절해도 하단 표시를 확인할 수 있습니다.

버전 1.9.14는 Windows 메뉴 목록의 기본 흰 테두리와 아이콘 여백을 없애고 라이트·다크 모드에 맞는 둥근 메뉴와 선택 표시를 적용했습니다. 메인창의 휴지통 관리 바로가기와 좁은 창에서의 하단 표시 보정도 포함합니다.
