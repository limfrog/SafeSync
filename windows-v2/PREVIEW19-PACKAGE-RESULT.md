# Windows preview.19 · macOS 0.3.15 배포 검사 — 2026-10-24

Windows [실행 40020161442](https://github.com/limfrog/SafeSync/actions/runs/40020161442)과 macOS [실행 40020443088](https://github.com/limfrog/SafeSync/actions/runs/40020443088)이 성공했다. Windows Server 2022/2025 재시작 95개와 핵심 1,325개, Windows 2022 화면 623개·설치 34개·페이로드 509개, macOS 통합 103개·XCTest 10개·Store 25개를 통과했다.

| 파일 | 크기 | SHA-256 |
|---|---:|---|
| `SafeSync-Setup-1.0.0-preview.19.exe` | 77,459,456 | `6094ddb14e6c37f4834243cac201c4ee9eb6932526d659051f65f116f0bc9fa1` |
| `SafeSync-Windows-1.0.0-preview.19.zip` | 77,257,009 | `f6b672220f740641ac15511ec22bff2c8fab10722934f9c0f8e14ce868b84850` |
| `SafeSync-macOS-0.3.15-universal.zip` | 4,267,377 | `2282428ed6bfa4315e8fc0dc2ac3855c8c479cbf2a2c89b5ccaacc1f6174cea2` |

실제 사용자 계정의 Dropbox/Google Drive 검증은 자동 실행하지 않았다. 앱의 연결 검증 버튼은 새 `SafeSync-test-*` 폴더만 사용하고 기존 작업·스냅샷·사용자 파일을 대상으로 하지 않는다. macOS는 Developer ID 서명·Apple 공증 전이고 Windows는 신뢰된 게시자 코드 서명 전이다.
