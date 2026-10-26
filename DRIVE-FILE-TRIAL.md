# Google Drive 제한 권한 시험본

최신 성능 개선 시험본은 Windows **1.0.0-preview.23**, macOS **0.3.19(28)**입니다. 프리뷰 22의 새 위치·작업·체크포인트를 그대로 이어 사용합니다. 재연결이나 새 백업 폴더 생성은 필요하지 않습니다. 일반 자동 업데이트 대상은 아직 이전 공개 버전이므로 아래 시험본을 직접 설치하세요.

- [Windows 프리뷰 23 설치본](dist/SafeSync-Setup-1.0.0-preview.23.exe)
- [Windows 프리뷰 23 ZIP](dist/SafeSync-Windows-1.0.0-preview.23.zip)
- [macOS 0.3.19 Universal ZIP](dist/SafeSync-macOS-0.3.19-universal.zip)
- [성능 개선 내용](windows-v2/PREVIEW23-VALIDATION.md)

아래는 최초 프리뷰 22 권한 이전 당시의 설명·검증 기록입니다. 기존 전체 권한 버전에서 처음 넘어오는 경우에만 새 계정 연결·전용 위치 이전 절차를 따릅니다.

Windows `1.0.0-preview.22`, macOS `0.3.18 (27)`의 시험 변경입니다. 공개 업데이트 목록과 Google Cloud 심사 설정은 기존 상태로 유지합니다. Windows 실계정 격리 검사는 통과했으며, 사용자 환경의 동작을 확인한 뒤 공개 전환 여부를 결정합니다.

## 내려받기

- [Windows 시험 설치본](dist/SafeSync-Setup-1.0.0-preview.22.exe)
- [Windows 시험 무설치 ZIP](dist/SafeSync-Windows-1.0.0-preview.22.zip)
- [macOS 시험 Universal ZIP](dist/SafeSync-macOS-0.3.18-universal.zip)
- [시험본 SHA-256](dist/DRIVE-FILE-SHA256SUMS.txt)

## 확인한 결과 — 2026-10-26

- [Windows Server 2022·2025 검사](https://github.com/limfrog/SafeSync/actions/runs/40232962611): 핵심 1,341개, 라이트·다크 화면 623개, 설치/제거 34개와 설치 파일 해시 511개 통과.
- [macOS 15 검사](https://github.com/limfrog/SafeSync/actions/runs/40232444604): 기존 통합 회귀, XCTest 14개(새 권한 검사 4개 포함), 실제 Store 모사 경로 24개, Apple Silicon·Intel Universal 번들·임시 서명·ZIP 통과.
- Windows 실계정: 사용자가 직접 Google 로그인을 승인하고 브라우저에서 상위 폴더를 선택했다. 실제 토큰의 `drive.file` 단독 권한을 확인하고, 새 전용 시험 폴더에서 업로드·서버 체크섬·변경 없음·교체·휴지통·복구를 통과했다. 새 서비스 인스턴스의 토큰 갱신·같은 폴더 재접속도 성공했다.
- 실계정 검사가 만든 시험 폴더와 파일은 자동 삭제됐으며 결과는 `Status=OK`, `Picker=true`, `Cleanup=true`다. 원래 작업·스냅샷·인증 토큰을 쓰는 설정은 변경하지 않았다.
- macOS 실기기·실계정 클릭 검사는 별도다. Google Cloud 심사 설정은 변경하지 않았고, 자동 업데이트 목록도 이전 공개 버전이다.

## 달라지는 동작

- 두 운영체제 모두 OAuth에서 `https://www.googleapis.com/auth/drive.file`만 요청하고 기존 권한을 합치지 않습니다. 실제 토큰 응답도 같은 제한 권한인지 확인합니다.
- 이전 전체 Drive 연결은 다시 로그인해야 합니다. 기존 작업은 자동으로 재개하지 않고 전용 폴더를 새로 선택하도록 요청합니다.
- 새 백업 폴더는 SafeSync에서 생성합니다. 기존 폴더를 상위 위치로 사용하려면 폴더 선택 화면의 **상위 위치 선택…**으로 Google 브라우저 선택기를 엽니다. 폴더 선택 자체가 기존 하위 파일 전체의 접근 승인이 되지는 않습니다.
- SafeSync가 새로 만든 폴더에는 비공개 앱 속성 `safesyncAccess=drive-file-v1`을 기록합니다. 이 속성이 없는 기존 폴더는 백업 루트로 자동 채택하지 않습니다.
- Google Drive API 연결은 단방향 백업만 지원합니다. 기존 전체 폴더의 양방향 동기화는 Google Drive 데스크톱 앱의 폴더를 로컬 위치로 지정합니다. Dropbox·일반 로컬·NAS의 양방향 동기화는 유지합니다.
- 작업 이전은 새 작업 ID와 새 기준으로 시작합니다. 이전 스냅샷과 미완료 삭제·교체 기록을 새 위치에 적용하지 않으며 이전 파일도 자동 삭제하지 않습니다.
- Google Drive API 연결에서 다른 앱이 넣은 파일이나 과거 백업 전체가 보인다고 가정하지 않습니다. 기존 백업 인계는 이번 시험본의 지원 범위가 아닙니다.

## 시험 순서

1. 기존 앱에서 작업 목록을 내보내고 현재 파일 처리를 끝냅니다. 이번 설치본은 기존 앱을 자동 교체하지 않습니다.
2. 시험본의 환경설정에서 Google 계정을 새 제한 권한으로 연결합니다. 기존 연결에서 넓은 권한이 섞여 돌아오면 연결을 저장하지 않고 중단합니다. 기존 Google 접근 권한을 계정에서 직접 해제하면 이전 버전의 연결도 영향을 받으므로 진행 중인 백업이 없는지 먼저 확인하세요.
3. **연결 검증**으로 별도의 `SafeSync-test-<ID>` 폴더에서 업로드·동일 파일 건너뛰기·교체·휴지통·복구와 자동 정리를 확인합니다.
4. 새 단방향 작업을 만들고 전용 폴더를 생성합니다. 임의 상위 위치를 선택하는 브라우저 흐름은 프로젝트의 Google Picker API 활성화가 필요할 수 있습니다. 심사 권한 목록을 먼저 변경할 필요는 없습니다.
5. 앱 재시작, 원본 변경·삭제, 휴지통 복구, 연결 취소와 접근 차단 상황을 확인합니다.

자동검사는 새 권한 요청·과도한 권한 거절·콜백 검증·이전 연결 차단·새 기준 이전·전용 폴더 속성과 기존 백업/동기화 회귀를 확인합니다. 실제 Google 로그인과 Picker 결과는 별도 실계정 검증이 필요합니다.

## 실계정 격리 검사 도구 (Windows)

`SafeSync.Tests`의 `--drive-file-trial <기존 config.json 경로>`는 기존 파일에서 OAuth 클라이언트 등록만 읽고 새 인증 토큰을 시험 폴더에 별도로 저장합니다. 원래 작업·스냅샷·인증 토큰을 수정하지 않습니다. `--pick-parent`를 함께 지정하면 Google 브라우저 선택기로 상위 폴더를 고르는 흐름도 검사합니다. 합성 파일만 업로드하고 이번 시험 폴더는 종료 시 자동 정리합니다. 토큰을 포함한 시험 설정은 GitHub에 올리지 않습니다.

## 참고

- [Google Drive 권한 안내](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)
- [데스크톱 Google Picker](https://developers.google.com/workspace/drive/picker/guides/desktop-mobile-picker)
