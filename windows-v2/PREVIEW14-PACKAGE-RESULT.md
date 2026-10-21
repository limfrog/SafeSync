# Preview 14 설치본 검증 — 2026-10-21

- 앱 빌드: 경고 0, 오류 0. 버전 `1.0.0-preview.14`, 회사 `Horizon Entertainment`.
- 핵심 회귀 1,004개 통과: `artifacts/tests/safesync-v2-c2c5c944c2c74eab9f99a4472a2addb2/result.json`.
- 화면 검사 585개 통과: 일반 빌드, 포함 런타임, 격리 설치본에서 각각 확인. 실제 사용자 앱과 별개 프로세스로 실행하고 모두 종료됨을 확인했다.
- 최종 포함 런타임 화면 기록: `artifacts/ui-da62b41b1d1e4052b81119e7159934c1/smoke-result.json`.
- 최종 설치 페이로드 화면 기록: `artifacts/ui-5e2d785645464f0bb98aecf6e0663360/smoke-result.json`.
- 설치 도구 34개 검사, 격리된 설치 파일 504개 해시 대조, 설치 EXE 자체 `/verify` 검사와 격리 제거 검사 통과.
- 최종 패키징 작업: `artifacts/packaging-611c1868f7f145fb93f53f7e22c8bc0a/`.
- PowerShell 미로드 및 포함된 .NET 런타임 사용을 확인했다. 원본·백업 파일의 시험은 전용 임시 자료만 사용했다.

| 파일 | 크기(bytes) | SHA-256 |
|---|---:|---|
| SafeSync-Setup-1.0.0-preview.14.exe | 77,428,224 | b4c8aa751b7dab5c1c449f1df69bdb016203aea0ccbb5c826210e54b19cce85c |
| SafeSync-Windows-1.0.0-preview.14.zip | 77,225,877 | 3910066ae2e741cf3cfc9211ee31b6133ee229d1e7bba669538344af705d3210 |

배포 사본은 상위 `dist/`에 있다. 새 설치본의 변경 사항은 [기능 검사 기록](PREVIEW14-VALIDATION.md)을 참고한다. 아직 코드 서명 전이며 실제 실행 중인 preview.12는 교체하지 않았다. 이 기록은 설치본 준비 단계의 검증이며 이후 사용자의 배포 지시에 따라 GitHub·홈페이지·공개 업데이트 목록을 갱신한다. 기존 설정·계정·스냅샷과 실제 파일은 그대로다. 설치해야 수정된 UI와 시작 문구가 반영되며, 과거에 저장한 활동기록을 지우는 수정은 아니다.
