# Windows preview.17 · macOS 0.3.13 배포 검사 — 2026-10-22

사용자 PC가 아닌 GitHub 격리 환경에서 실행·빌드·설치 검사를 했다. Windows 환경설정의 업데이트 진입은 하나로 통합하며 백업 엔진은 preview.16과 동일하다. macOS는 재현된 네트워크 분류·재시도와 실행 중 파일 처리 예약을 보완하고 같은 버튼 정리를 적용했다.

## macOS 재현과 수정

- 수정 전 제품 코드를 유지한 [실행 39725281365](https://github.com/limfrog/SafeSync/actions/runs/39725281365), 소스 `9d8c3a031a3c312aa10e5026fefe80d4fbf2f42a`: 모의 Google Drive/Dropbox의 단방향/양방향 네 경우 모두 일회 503 오류가 일반 파일 오류로 남고 다음 엔진 실행에서 복구됐다. Store/UI 소스에서는 네트워크 오류의 메시지·알림·문제 해결 목록 구분과 실행 중 예약이 없는 것을 확인했다.
- 최종 [실행 39728552265](https://github.com/limfrog/SafeSync/actions/runs/39728552265), 소스 `7e98b45f9087d4ca235fd7ee5187d293a5e1ef55`: 기존 통합 시나리오 100개와 추가 네트워크 정책·예약 보호 검사, XCTest **10개**, 실제 앱 Store 실행 경로 **24개 시나리오 통과**.
- 24개는 두 제공자×두 모드에서 일회/지속 실패 8개, 실행 중 예약 적용/취소/파일 변경/명시 중단 16개다. 버튼 콜백이 사용하는 Store를 실제로 컴파일하여 임시 데이터·모의 원격 저장소로 실행했다. 새 버전에서 정확히 한 번의 마지막 재시도, 성공 상태 갱신, 오류 목록 보존·확인 메시지 제외, 마지막 선택 우선, 원래 동기화 이후 적용, 사본 보관 및 중단 후 수동 재비교 권한을 확인했다.
- 초기 검사에서 FSEvents 알림이 실패 횟수·재시도 대기를 초기화하는 것을 발견해 보완했다. 최종 검사에서 지속 오류의 두 번 실패 후 대기는 약 **60초**였고 빠른 반복은 없었다. 이 과정의 실패한 중간 패키지는 게시하지 않는다.
- 환경설정의 단일 업데이트 버튼 소스 조건을 검사하고 앱 전체를 컴파일했다. 실제 Mac 화면에서 마우스로 버튼을 누른 검사로 계산하지 않는다.
- **0.3.13(22)**, 기존 앱 ID `io.limfrog.SafeSync.macOS`, x86_64/arm64 Universal·실행 권한 755·ad-hoc 엄격 서명·ZIP 무결성 및 기존 Google Desktop 등록 리소스 바이트 일치 검사를 통과했다.

## Windows 검사

- [실행 39727038801](https://github.com/limfrog/SafeSync/actions/runs/39727038801), 소스 `b26c2f65244cd8707b2dce60c7c4f50ff6d4e40c`. 이후 Mac 수정이 있었으나 Windows 제품·검사·번들 문서·빌드 스크립트가 이 소스와 동일함을 대조했다.
- Windows Server 2022/2025 각각 재시작 **95개**, 핵심 **1,303개 통과**. Windows 2022의 포함 런타임/격리 설치 앱에서 라이트·다크 화면 **각각 618개**, 설치 도구 **34개**, 설치 파일 **507개 해시**, EXE 자체 검증·제거 검사 통과. 앱 빌드 경고 0·오류 0.
- 환경설정에 중복 진입 버튼이 없고 ‘업데이트 확인’만 있음을 실제 WPF 검사로 확인했다. 기존 업데이트 화면의 다운로드·검증·사용자 승인 후 설치는 유지한다.

## 검증된 배포 파일

| 파일 | 크기(bytes) | SHA-256 |
|---|---:|---|
| SafeSync-Setup-1.0.0-preview.17.exe | 77,451,776 | a8d1915d6a20bf3080a3e731fb04edc5120a792bf0e6fe8c71473790c3770236 |
| SafeSync-Windows-1.0.0-preview.17.zip | 77,249,337 | 3dab7c3b22ce7843e3bf046e9a90cfb91636d75fc205fcefaf3277496bc803ab |
| SafeSync-macOS-0.3.13-universal.zip | 4,200,678 | dfe547b67a9d3eca20de86b6054347b04cd91c46cc5b0bd3d6dde2cf49141b45 |

GitHub 산출물 다운로드 ZIP을 API의 SHA-256과 대조하고 실제 배포 파일을 바이트 변경 없이 복사했다. Windows 무설치 ZIP의 파일명만 공개 규칙으로 바꿨다.

- Windows `windows-preview17-package`, ID `12403632804`: 154,047,951 bytes / `1160b48d5d15555897ebc53089347a885e9d9cf99780390e875b0498273a212c`.
- macOS `SafeSync-macOS-0.3.13-universal`, ID `12403464167`: 4,187,472 bytes / `3e36f5dd31f34459bc857edd0774aa0e6cb247dbc6ddd2beed731ed84ea5d60f`.

## 범위

실계정 Google Drive/Dropbox API·실제 NAS 장애·실제 Mac UI 클릭/Intel 기기·Windows 10/11 일반 권한·장기 운전·전송 중 전원 차단 검사는 별도다. Windows 코드 서명과 Apple Developer ID/공증은 완료하지 않았다. 양방향 전체 비교의 증분화나 백그라운드 서비스 도입은 이번 수정이 아니다.

사용자 앱·계정·작업·스냅샷·실제 백업 파일은 변경하지 않았다. 사용자가 새 버전을 설치/교체해야 적용된다. GitHub·업데이트 목록·개별 홈페이지를 갱신하되 `/apps/` 목록의 SafeSync 비노출은 유지한다.
