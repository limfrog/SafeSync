# SafeSync

SafeSync는 Windows 10/11용 개인 자동 백업 프로그램입니다. 현재 소스와 배포본 버전은 **1.9.11**입니다.

- [Windows 설치 파일](dist/SafeSync-Setup-1.9.11.exe)
- [Windows 무설치 ZIP](dist/SafeSync-Windows-1.9.11.zip)
- [사용 및 기능 안내](outputs/SafeSync/README-ko.md)
- [개발·macOS 이식 인계](HANDOFF.md)

## 저장소 구성

- `outputs/SafeSync/`: Windows 앱의 PowerShell 소스, 아이콘 원본 및 실행용 설정
- `work/packaging/`: 설치 프로그램, 런처, 아이콘 및 무설치 ZIP의 빌드 소스
- `work/safesync-*-tests.ps1`: 기능별 검증 스크립트
- `dist/`: 검증 당시의 Windows 1.9.11 설치/무설치 배포본과 이전 버전
- `index.html`, `privacy.html`: GitHub Pages용 안내 및 개인정보처리방침

## Windows 빌드

Windows PowerShell 5.1에서 `work/packaging/build.ps1`을 실행합니다. Windows에 포함된 .NET Framework C# 컴파일러가 필요합니다. 빌드 결과는 `outputs/SafeSync-Setup.exe`와 `outputs/SafeSync-Windows.zip`으로 생성됩니다. 배포본에는 코드 서명이 없습니다.

`dist/`의 배포본은 소스 인계의 편의를 위해 보관한 파일입니다. 다운로드 전에 SHA-256을 [체크섬 목록](dist/SHA256SUMS.txt)과 대조하세요.

개인 설정, OAuth 토큰·키, 실행 로그, 백업 데이터, 테스트용 임시 파일은 저장소에 포함하지 않습니다. 이 저장소를 맥에서 복제해도 Windows에 저장된 작업·스냅샷·클라우드 인증 상태는 자동으로 이전되지 않습니다.

버전 1.9.11부터 앱의 **파일** 메뉴에서 작업 목록을 JSON으로 내보내거나 다시 가져올 수 있습니다. 내보내기에는 인증 정보와 스냅샷이 포함되지 않습니다.
