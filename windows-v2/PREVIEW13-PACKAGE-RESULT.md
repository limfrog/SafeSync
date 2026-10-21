# 프리뷰 13 최종 배포 결과 — 2026-10-21

개발자 Horizon Entertainment · 문의 apps@horizonent.co.kr

## 최종 파일

| 배포본 | 바이트 | SHA-256 |
|---|---:|---|
| SafeSync-Setup-1.0.0-preview.13.exe | 77423616 | `a0a52121211a9420ba222cf8adf7bbb3520eeff5b93815eb71157e2a0627bdad` |
| SafeSync-Windows-1.0.0-preview.13.zip | 77220981 | `7262e225e4359c2839286cd2e04866c35cd67db51f170c1844997b496a5ef37c` |
| SafeSync-macOS-0.3.9-universal.zip | 4071408 | `433a33bb6f1eb8485ca654bcf19b32219b1d1950ac22ad9ab355560f46ddba73` |

Windows 설치 도구 34개 검사, 설치 페이로드 503개 해시 확인, 격리 설치본의 라이트·다크 화면 563개 검사, 제거 및 EXE `/verify` 검증이 통과했다. 기존 앱·사용자 설정·백업 자료에는 설치하지 않았다. Windows 앱과 설치 프로그램의 제품 버전 `1.0.0-preview.13`, 회사 `Horizon Entertainment`를 확인했다.

macOS 0.3.9 (18)는 GitHub 실행 `39554150051`에서 Universal 빌드·코드 서명·번들 검증을 통과했다. 받은 Actions 아카이브의 API 체크섬을 확인한 뒤 내부 ZIP을 바이트 그대로 배포했다. Google Desktop 등록 리소스는 0.3.8과 SHA-256이 같으며 사용자 토큰·개발자 원본 JSON은 포함하지 않았다. 실제 Mac UI 조작 검증은 별도다.

## 게시 후 확인

- 소스·설치본·업데이트 목록 게시: `2371c35827ad342ce7bac62de3850fe73f9724e8`.
- **Publish update catalog** 실행 `39555394478` 성공. GitHub에 새 설치 파일과 체크섬을 올리면 자동으로 배포 정보를 갱신한다.
- 앱과 동일한 `AppUpdateClient`로 공개 목록을 읽고 Windows preview.12 → preview.13, macOS 0.3.8 → 0.3.9를 탐지했다. 현재 버전에는 같은 버전을 다시 제공하지 않음을 확인했다.
- 해당 클라이언트로 Windows EXE와 macOS ZIP을 실제 다운로드하고 게시 크기·SHA-256과 일치함을 확인했다. 다운로드한 EXE를 설치 실행하지 않았다.
- 홈페이지 커밋 `1926495d6419bb6f662ee434e652986ed21da9db`, SafeSync 전용 배포 `39555882436` 성공. 개별 소개·설치 링크·업데이트 개인정보 안내 HTTP 200 확인.
- `/apps/` 목록은 SafeSync 비노출을 유지한다. 관련 없는 ClipSync 변경은 보존했다.

이번 버전은 처음 한 번 직접 설치해야 한다. 이후부터 환경설정에서 자동 확인·다운로드 또는 수동 확인을 이용한다. 무인 강제 설치, 서명된 업데이트 체계, 실제 계정 전체 백업 검증을 완료했다는 의미는 아니다.
