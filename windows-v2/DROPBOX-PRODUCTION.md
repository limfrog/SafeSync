# Dropbox 외부 배포 인계

2026-10-19 · SafeSync Windows 1.0.0-preview.1

- 앱: SafeSync Personal (이름의 Personal이 개인 전용 권한을 뜻하지 않음)
- App ID: 8752417 / 공개 App Key: 08al8ot9uye36k9
- 콘솔: https://www.dropbox.com/developers/apps/info?app_key=08al8ot9uye36k9
- 접근: Scoped access / Full Dropbox / public client / OAuth code + PKCE + offline refresh
- 권한: account_info.read, files.metadata.read, files.content.read, files.content.write
- 반환 주소: http://127.0.0.1:53682/
- 홈페이지: https://www.horizonent.co.kr/apps/safesync/
- 개인정보처리방침: https://www.horizonent.co.kr/apps/safesync/privacy.php
- Windows 설치본: https://github.com/limfrog/SafeSync/raw/main/dist/SafeSync-Setup-1.0.0-preview.1.exe
- 등록 상태: 2026-10-19 Production 신청 접수 완료. 콘솔 표시 `Awaiting review pending app eligibility`. 승인 완료가 아니며 개발 사용자 한도가 유지됨.

실제 계정의 새 폴더에서 32개 검사를 통과했다. 사용자가 최종 제출을 승인했고 새 공개 설치본·홈페이지·정책·테스트 안내로 신청을 접수했다. 콘솔은 최소 50명 연결 등 심사 적격 조건 충족을 기다리는 상태를 표시한다. 제출과 승인 완료는 별개다. 조기 심사 사유나 사용자 수를 만들어 쓰지 않았다. 설치본에 포함된 인계 문서는 빌드 당시의 제출 전 상태이며 최신 접수 상태는 이 저장소 문서를 기준으로 한다.

## 심사자 테스트 안내

1. Windows 10/11 x64에서 설치하거나 ZIP을 풀고 SafeSync.exe를 실행한다. 앱은 알림 영역으로 시작한다. 아이콘 더블클릭으로 메인창을 연다. 미서명 프리뷰임을 명시한다.
2. 환경설정 → 클라우드 계정 → Dropbox 연결. 기본 App Key가 들어 있다. 심사자의 Dropbox 계정을 브라우저에서 직접 승인한다. SafeSync 자체 회원가입·별도 비밀번호는 없다.
3. 새 작업에서 작은 테스트 원본 폴더와 Dropbox를 선택한다. 위치 선택에서 Dropbox의 원하는 하위 폴더를 탐색하거나 새 폴더를 만든다. 작업은 선택한 폴더 경로·ID·계정으로 제한한다.
4. 단방향으로 생성/변경/삭제·휴지통 복구를 확인한다. 양방향은 별도 새 작업에서 양쪽 변경과 삭제가 전파되는 것을 시험한다. 중요한 기존 파일을 시험에 쓰지 않는다.
5. 동기화 상태에서 충돌과 사용 중 파일을 확인한다. 충돌 처리로 원본/백업 선택·이름 변경 후 복사·무시를 선택할 수 있다.
6. 계정 연결 해제, Dropbox의 연결 관리 화면에서 승인 철회가 가능하다. 기존 백업 자료는 자동 삭제되지 않는다.

Full Dropbox 토큰 자체는 선택 폴더 전용으로 축소되지 않는다. 선택 폴더 제한은 앱 내부의 실행 제한이다. 앱 비밀번호·App Secret·공유 토큰·실제 작업 설정은 배포하지 않는다. 실제 사용자 인증 토큰은 해당 Windows 사용자의 DPAPI로 로컬 보호한다.
