# Windows preview.19 — 클라우드 연결 검증

2026-10-24 · Horizon Entertainment · apps@horizonent.co.kr

환경설정의 Dropbox·Google Drive 계정마다 **연결 검증** 버튼을 추가한다. 검증은 계정 루트 아래 새 `SafeSync-test-UUID` 폴더와 운영체제 임시 폴더만 사용하며 기존 작업·스냅샷·사용자 파일을 대상으로 하지 않는다.

연결 검증 창 안에서 계정/루트 확인, 시험 폴더 생성, 최초 전송과 서비스 체크섬, 변경 없는 파일 건너뛰기, 안전한 교체와 이전 사본 보존, 휴지통 이동과 복구 상태를 바로 표시한다. 결과는 환경설정을 닫거나 메인 창으로 돌아갈 필요 없이 같은 창의 고정 영역에서 확인한다.

GitHub [실행 40020161442](https://github.com/limfrog/SafeSync/actions/runs/40020161442)에서 Windows Server 2022/2025 재시작 재현 95개와 핵심 회귀 1,325개를 각각 통과했다. Windows 2022에서는 포함 런타임·격리 설치 화면 각각 623개, 설치 도구 34개, 설치 파일 509개 해시 검사가 통과했다. 모의 Google Drive·Dropbox 연결 검증은 전송·동일 파일·교체·휴지통·복구를 수행했다.

| 파일 | 크기 | SHA-256 |
|---|---:|---|
| `SafeSync-Setup-1.0.0-preview.19.exe` | 77,459,456 | `6094ddb14e6c37f4834243cac201c4ee9eb6932526d659051f65f116f0bc9fa1` |
| `SafeSync-Windows-1.0.0-preview.19.zip` | 77,257,009 | `f6b672220f740641ac15511ec22bff2c8fab10722934f9c0f8e14ce868b84850` |

실제 계정 검증은 사용자가 버튼을 눌렀을 때에만 수행하고 시험 폴더를 결과 확인용으로 남긴다. 자동검사는 실제 사용자 OAuth 토큰이나 기존 클라우드 파일을 사용하지 않았다.
