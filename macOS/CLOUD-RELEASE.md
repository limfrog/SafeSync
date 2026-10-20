# 일반 사용자용 클라우드 연결 빌드

클라우드 연결 화면에는 앱키, Client ID, Client Secret 입력란이 없습니다. 계정 이름은 선택 사항이며 비우면 서비스 이름과 중복 방지 번호를 사용합니다. 로그인·동의는 시스템 브라우저에서 진행합니다. 기존 계정과 Keychain 토큰 형식은 유지합니다.

Dropbox는 기존 SafeSync 공개 앱키와 PKCE를 사용합니다. Google은 등록된 Desktop OAuth 클라이언트의 설정을 빌드 때 포함합니다. 웹 클라이언트의 비밀 값이나 사용자 access/refresh token은 포함하지 않습니다. 데스크톱 앱에 포함된 등록 정보는 추출 가능하며, 이를 서버 비밀로 간주하지 않습니다.

## 로컬 빌드 설정

- 개발자 전용 파일: `.build/private/GoogleDesktopOAuth.json` (git 제외, 소유자만 읽기/쓰기).
- 입력은 Google `installed` 형식의 JSON이며, 패키저는 `client_id`와 `client_secret`만 추출합니다.
- 다른 경로는 `GOOGLE_OAUTH_CLIENT_FILE`로 지정합니다. 인증 값 자체를 명령행 인자로 넘기지 않습니다.
- 일반 사용자용 빌드에는 `REQUIRE_GOOGLE_OAUTH=1`을 사용합니다. 설정 누락 시 패키징이 실패합니다. 개발용 누락 빌드는 Google 연결을 비활성화합니다.
- 배포 앱은 SafeSync의 Desktop OAuth 등록만 포함합니다. 사용자 access/refresh token을 포함하지 않습니다.
- 원본 OAuth JSON은 소스나 공개 문서에 추가하지 마세요. 배포용 Desktop 등록은 앱에서 추출 가능한 공개 클라이언트 정보로 취급합니다.

## 검증 범위

- universal 앱 빌드·서명·ZIP 검증.
- 별도 임시 데이터 QA 앱에서 Google/Dropbox 연결 화면과 빈 이름의 연결 버튼 활성 상태 확인.
- 패키저의 Desktop 형식 허용, 웹 형식 거절, 잘못된 필드 거절, 토큰 등 불필요 필드 제외를 확인.
- 이번 변경에서 실제 OAuth 로그인·토큰 갱신·Drive/Dropbox 전송을 새로 검증하지는 않았습니다.
