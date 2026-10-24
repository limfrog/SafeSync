# SafeSync preview.21 배포 검사 결과

- Windows 자동검사: [Windows Server 2022·2025 실행 40081237109](https://github.com/limfrog/SafeSync/actions/runs/40081237109) — 성공
- macOS 자동검사: [macOS 15 실행 40080688535](https://github.com/limfrog/SafeSync/actions/runs/40080688535) — 성공
- Windows 설치 파일: `SafeSync-Setup-1.0.0-preview.21.exe` · 77,464,576바이트 · SHA-256 `164e4dcf10379b4ecd5931efaae570e70d6ffe651db5cf322b0296661cf8c800`
- Windows 무설치 ZIP: `SafeSync-Windows-1.0.0-preview.21.zip` · 77,262,194바이트 · SHA-256 `7bc5b208885f870382c5797037bccab862e8d6bb395a01a886c2d9775466c647`
- macOS Universal ZIP: `SafeSync-macOS-0.3.17-universal.zip` · 4,269,668바이트 · SHA-256 `c5bc87ec6e1621d6c31444f69c166163e152f5bc5dcb8d1f99319f93be93a3b3`

Windows에서는 재시작·로컬/UNC 비교·스냅샷 유지·격리 회귀·설치/제거를 Windows Server 2022와 2025에서 각각 확인했다. macOS에서는 통합 회귀, XCTest, 실제 Store 경로, Apple Silicon·Intel Universal 번들과 임시 서명을 확인했다.
