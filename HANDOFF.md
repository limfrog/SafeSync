# 지속 적용할 배포 지시 — 2026-10-21

사용자는 앞으로 작업이 끝나고 검증을 마치면 **GitHub와 홈페이지에 별도 확인 없이 업로드**하도록 지시했다. 소스·검증된 설치본·체크섬·업데이트 목록과 개별 SafeSync 페이지를 함께 갱신하고 실제 다운로드와 웹 반영을 확인한다. 사용자 설정·계정 토큰·개인 백업·진단 표본은 공개하지 않는다. 이 지시는 실행 중 앱 자동 설치나 실제 백업 변경을 허가하지 않는다. 홈페이지 `/apps/`의 SafeSync 비노출은 유지하며 별도 노출 지시 전까지 소개·카드·링크를 다시 추가하지 않는다.

이후 SafeSync 기능 변경은 **Windows와 macOS를 항상 하나의 배포 묶음으로 검토한다.** 공통 동작은 두 OS에 모두 반영하고 각각의 자동 검사·빌드·번들 검증을 마친 뒤 소스, 설치 파일, 체크섬, 업데이트 목록, 홈페이지와 릴리스 노트를 함께 갱신한다. OS 전용 변경이라면 다른 OS에 필요 없음을 검토·기록한다. 한쪽의 빌드나 공통 회귀 검사가 실패하면 두 OS 묶음의 공개를 완료로 표시하지 않는다.

# Windows preview.19 · macOS 0.3.15(24) — 2026-10-24

macOS 연결 검증 원본을 앱 자체 데이터 폴더에 만들던 오류를 수정했다. 자체 데이터 재백업 방지 정책 때문에 파일이 제외되어 `완료 수 불일치`가 발생했으며, 이제 고유한 OS 임시 폴더를 사용하고 종료 시 제거한다. Windows에도 Dropbox·Google Drive 연결 검증을 추가했고, 두 운영체제 모두 계정 창 안의 고정 영역에서 단계와 결과를 확인한다. 검증은 새 `SafeSync-test-*` 클라우드 폴더만 사용한다. 세부 범위는 `windows-v2/PREVIEW19-VALIDATION.md`, `macOS/0.3.15-VALIDATION.md`에 남긴다.

# Windows preview.18 · macOS 0.3.14(23) — 2026-10-24

Windows preview.18의 빠른 클라우드 재시작 비교를 macOS 단방향·양방향에 이식했다. 로컬 감시 미준비로 인한 전체 파일 목록 재조사와 클라우드 커서 초기화를 분리하고, 성공적으로 검증한 원본·원격 지문이 같은 파일의 내용 재독을 생략한다. 전체 검사·변경·실패·중복·수동 처리는 정밀 검증을 유지한다. GitHub macOS 15 실행 `40015224976`에서 통합 103개·XCTest 10개·Store 24개와 Universal/서명/번들 검사가 통과했다. ZIP SHA-256은 `96dde66487d9c45eca9320c2745b93f58bf12ebb323adb0f2494d2bd3f094318`. 세부 검사는 `macOS/0.3.14-VALIDATION.md`에 남겼다.

# Windows preview.18 — 2026-10-24

Windows 클라우드 일반 비교는 원본 크기/시각/파일 ID와 성공 검증 후 저장된 원격 항목 전체가 같으면 내용을 재독하지 않는다. 미완료/실패·변경 이벤트·중복·명시적 처리·전체 검사는 제외한다. NAS 목록 재열거와 내용 검증을 분리하며 전송/삭제/복구 보호는 유지한다. 옛 스냅샷의 첫 비교는 검증 정보를 쌓기 위해 오래 걸릴 수 있다. 크기·시각까지 유지한 오프라인 편집은 빠른 비교에서 놓칠 수 있어 전체 검사로 정밀 확인해야 한다. macOS 0.3.14에도 같은 정책을 이식했다.

제품/검사 소스 `610df791fb3d4d449d78f9bde855e768e40415e3`, GitHub 격리 실행 `39979396814`. 최종 결과와 해시는 `windows-v2/PREVIEW18-PACKAGE-RESULT.md`를 확인한다. 실행 중 앱과 실제 백업은 자동 변경하지 않으며 `/apps/` 비노출은 유지한다.

# Windows preview.17 · macOS 0.3.13(22) — 2026-10-22

- 사용자 요청: Mac의 같은 문제를 먼저 검증한 뒤 보완하고, 두 OS 환경설정의 중복 업데이트 진입 버튼을 없앤 후 GitHub·홈페이지에 게시한다. 업데이트 확인 화면의 실제 다운로드/검증·사용자 설치 단계와 자동 확인/다운로드 설정은 유지한다.
- Mac 수정 전 독립 재현 `39725281365`(소스 `9d8c3a0`): 두 모의 제공자×두 모드에서 일회 503이 일반 오류로 남고 다음 실행에서 복구됨을 확인했다. 확인 메시지/알림·문제 해결 구분 부재와 실행 중 비교 차단은 Store/UI 소스에서 확인했다.
- Mac 최종 제품 소스 `7e98b45f9087d4ca235fd7ee5187d293a5e1ef55`, 실행 `39728552265`: 기존 통합 100개와 추가 네트워크/예약 검사, XCTest 10개, 실제 Store 코드로 모의 클라우드 24개 시나리오 통과. 네트워크 진단 전용·마지막 재시도·지속 실패 지연, 실행 중 즉시 예약·마지막 선택·선택 취소·파일/위치 재검증·사본 보존·중단 후 수동 재비교를 반영했다. FSEvents 알림이 대기 간격/횟수를 초기화하던 조건도 수정했다. 예약은 세션 한정이며 실제 쓰기 권한을 느슨하게 하지 않는다.
- Windows 제품 소스 `b26c2f65244cd8707b2dce60c7c4f50ff6d4e40c`, 실행 `39727038801`: 두 OS 각각 재시작 95개·핵심 1,303개, 번들/설치 화면 각각 618개·설치 34개·파일 해시 507개 및 EXE 자체 검증 통과. 후속 Mac 변경은 Windows 소스에 영향을 주지 않음을 대조한다. Windows 엔진은 preview.16과 동일하다.
- Windows EXE SHA-256 `a8d1915d6a20bf3080a3e731fb04edc5120a792bf0e6fe8c71473790c3770236`(77,451,776 bytes), ZIP `3dab7c3b22ce7843e3bf046e9a90cfb91636d75fc205fcefaf3277496bc803ab`(77,249,337 bytes). Mac ZIP `dfe547b67a9d3eca20de86b6054347b04cd91c46cc5b0bd3d6dde2cf49141b45`(4,200,678 bytes).
- Mac Universal/실행 권한 755/기존 앱 ID·Google 등록 리소스/ad-hoc 엄격 서명·ZIP 검사를 유지한다. 실제 UI 마우스 조작·실계정/NAS/Intel·장기 운전·공증 등은 별도 범위다. 사용자 실행 앱을 자동 교체하거나 실제 백업·계정을 변경하지 않는다. `/apps/` 비노출을 유지한다. 상세는 `windows-v2/PREVIEW17-PACKAGE-RESULT.md`, `macOS/STATUS.md`를 확인한다.

# Windows preview.16 실행 중 선택·네트워크 자동 재시도 — 2026-10-22

- 처리 버튼을 누르면 현재 실행의 완료 후 실행할 파일별 선택을 즉시 예약한다. 별도 예약 확인 버튼 없이 실행 전 다른 선택으로 바꾸면 마지막 선택만 실행한다. 선택 취소·탭 재생성·이미 처리 중인 묶음 잠금·위치/파일 정보 재검증을 유지한다. 미실행 예약은 세션 한정이며 종료·작업 자체 실패·업데이트·연결 변경 시 취소한다.
- 일시적인 네트워크 오류는 오류 목록의 자동 재시도로만 남기며 수동 덮어쓰기 목록·확인 메시지·오류 알림음에서 제외한다. 현재 동기화 뒤 한 번, 지속 실패 시 간격을 늘려 최대 5분 단위로 재시도한다. 실제 취소·작업 종료는 재시도하지 않으며 인증·권한·공간·체크섬 오류와 실제 충돌을 자동 처리하지 않는다.
- 최종 소스 `31dd2f3216a0084884f67886d0b09802853e55ac`, GitHub `39668010647`: Windows 2022/2025 각각 재시작 95개·핵심 1,303개, Windows 2022의 번들/설치 라이트·다크 화면 각각 617개, 설치 34개·파일 506개 해시 및 EXE 자체 검증 통과. 이전 중간 설치본을 게시하지 않는다.
- EXE 77,450,240 bytes / SHA-256 `8460da41771ebea9117fa17547f26dea5f6a1108fc69b718d4531a66425e6122`; ZIP 77,247,710 bytes / `b5b67a51cf5df2fb331ff6bd39167a74d7331644c3d1951feb39d86908d91aa6`. 상세는 `windows-v2/PREVIEW16-PACKAGE-RESULT.md`와 `PREVIEW16-VALIDATION.md`를 확인한다.
- 실제 사용자 앱·작업·계정·백업은 변경하지 않는다. 검증은 GitHub 격리 환경 및 모의 클라우드로 한정하며 실서비스/NAS 장애·장기 운전을 검증했다고 과장하지 않는다. macOS 0.3.12(21)는 유지한다. 소스·설치본·업데이트·개별 홈페이지를 게시하되 `/apps/`의 비노출을 유지한다.

# macOS 0.3.12(21) Universal 재빌드 — 2026-10-22

- Windows preview.15 게시 이후 최신 저장소에서 macOS 재빌드를 요청받았다. macOS 엔진/UI는 0.3.11을 유지하고 버전·빌드 번호만 0.3.12(21)로 올렸다. Windows NTFS/USN 수정이 맥에도 적용됐거나 맥 양방향 비교가 증분화됐다고 안내하지 않는다.
- GitHub 실행 `39640708397`, 빌드 소스 `60e1cc2`: 통합 시나리오 100개·XCTest 10개, x86_64/arm64 Universal·ad-hoc 엄격 서명·번들·ZIP 검사 통과. 첫 실행의 lipo 검사 인자 오류는 수정 후 전체 재실행했다.
- ZIP 4,127,624 bytes / SHA-256 `0bb8a888479c93f072eafdb70ce4232ed6a2624611b84e0561ed0198aeca4735`. 기존 앱 ID·설정·Keychain과 Google 등록 리소스를 유지한다. 실제 UI·실서비스 전송·Intel 실행·Apple 공증은 별도다. 상세는 `macOS/STATUS.md`, 이전 검사 원문은 `macOS/TEST-RESULTS.txt`에 보존한다.
- Windows 설치본/업데이트는 preview.15를 유지한다. macOS ZIP·체크섬·업데이트 목록과 개별 홈페이지를 갱신하되 `/apps/` 비노출을 유지하며 사용자 실행 앱을 자동 교체하지 않는다.

# Windows preview.15 재시작 색인·폴더 충돌 수정 — 2026-10-22

- Windows 변경 저널 볼륨을 쓰기 권한 없이 GENERIC_READ로 열고, 열 수 없으면 이전 메타데이터 접근 호환 경로 및 안전한 전체 비교를 유지한다. 관리자 실행을 강제하거나 저널을 생성·삭제하지 않는다.
- 실제 폴더를 파일 부재/삭제 처리로 넘기지 않는다. 기존 잘못된 폴더 파일 행은 실제 원본·백업 종류를 확인한 뒤 정리하고 하위 스냅샷과 사본을 보존한다. 변경 경로가 예전 파일 행이더라도 현재 폴더이면 하위 변경 파일을 찾는다. 종류 충돌·원본 부재·루트 교체 보호는 유지한다.
- 제품 수정 `98380ac`, GitHub `39634648520`: 두 OS의 재현 95개·핵심 1,030개, Windows 2022의 포함 런타임·설치 화면 585개, 설치 34개 및 설치 파일 505개 해시가 통과했다. 최종 배포 문서 포함 설치본은 `PREVIEW15-PACKAGE-RESULT.md`를 확인한다.
- 변경 없는 두 번째 NTFS 재시작의 전체/내용 비교·복사·충돌·대기는 0. 최초 복사 직후 첫 재시작은 자체 복사 변경을 확인할 수 있으며 SMB 감시 공백에서는 여전히 전체 비교한다. 실제 NAS/클라우드·Windows 10/11 일반 권한의 USN 성능·재부팅·장기 운전은 별도다.
- macOS는 0.3.11을 유지한다. 사용자 실행 앱을 종료·설치하거나 실제 작업/스냅샷을 변경하지 않는다. GitHub와 개별 홈페이지 다운로드를 갱신하고 `/apps/` 비노출을 유지한다. 수정 전 실패는 `windows-v2/RESTART-REPRODUCTION-20261022.md`, 수정 결과는 `windows-v2/PREVIEW15-VALIDATION.md`에 남긴다.

# Windows preview.14 문제 해결 수정 — 2026-10-21

현재 macOS도 **0.3.11 (20)**로 같은 문제를 보완했다. `ComparisonReview`로 현재 실행 세대·연결 정보에 권한을 묶고 이전 이력도 현재 파일을 다시 비교한 뒤 적용한다. `ProblemWorkspace`의 탭 이탈/재진입 시 로딩 상태를 정리하며 시작 문구를 간소화했다. 소스 `b68e2eb`, GitHub 빌드 `39616726940`에서 통합 100개·XCTest 10개와 Universal/서명 검증을 통과했다. ZIP 4,127,623 bytes / SHA-256 `44753d73519986b54bd8d763d86b2043c432772fbb8b29e0b8d8ee84d3f13049`. Google 등록 리소스와 기존 앱/설정/Keychain 식별자를 유지한다. 실제 Mac UI 조작과 실서비스 전송 검증은 이번에 수행하지 않았으며 macOS 종료 취소 경로는 Windows 파일 경계 종료와 구분한다. 상세는 `macOS/STATUS.md`를 확인한다.

- 이전 실행 이력은 그대로 쓰기 권한이 되지 않으며 ‘현재 파일 다시 비교’로 현재 실행 세대에 묶인 비교 정보를 얻어 처리한다. 새 실행·위치·계정·폴더·방향 변경 시 권한을 다시 차단한다. 같은 작업 실행 중에는 현재 파일을 마치고 대기하는 경로를 제공한다.
- 버전 하단과 시작 기록의 과거 전환 안내를 제거했다. 데이터 폴더·호환 처리·기존 활동기록은 보존한다.
- 핵심 1,004개, 라이트/다크 화면 585개, 설치 도구 34개, 최종 설치 파일 504개 해시 및 설치 EXE 자체 검증 통과. 실제 사용자 앱은 교체하지 않았다. 세부는 `windows-v2/PREVIEW14-VALIDATION.md`와 `PREVIEW14-PACKAGE-RESULT.md`를 확인한다.
- EXE 77,428,224 bytes / SHA-256 `b4c8aa751b7dab5c1c449f1df69bdb016203aea0ccbb5c826210e54b19cce85c`, ZIP 77,225,877 bytes / `3910066ae2e741cf3cfc9211ee31b6133ee229d1e7bba669538344af705d3210`.

# macOS 0.3.10 (19) 보호 처리 이식 — 2026-10-21

- Windows preview.13은 변경하지 않고 macOS에 내용 비교·루트 연결 식별·확실한 부재 확인·클라우드 삭제 직전 재확인·구버전 기록 최초 재검증을 반영했다. 경과 시간만으로 전체 검사하지 않는다.
- 기존 앱 ID `io.limfrog.SafeSync.macOS`, Application Support/SafeSync 데이터 위치, Keychain 식별자 및 Google Desktop 등록 리소스를 유지한다. 구버전에서 원본이 없는 기록은 자동 삭제하지 않고 검토 대상으로 보존한다. 루트 교체가 의도된 경우 작업 위치를 다시 선택해 새 비교 기록으로 시작한다.
- 빌드 소스 `3173cd0f0bf4216af847152ccc9964a14dad6189`, GitHub 실행 `39594764865`. 통합 시나리오 86개와 XCTest 10개 통과. FSEvents 시작 직후 준비 상태를 과신하던 문제를 실제 macOS 검사에서 발견해 보수적 초기 전체 검사로 보완했다.
- Universal ZIP 4,103,743 bytes / SHA-256 `aa09346d6523f6f933436934741d49bc6a534f1b9567aae325949c8e0aed9f06`. x86_64/arm64·서명·번들·리소스 일치를 확인했다. ad-hoc 서명이며 Developer ID/Apple 공증은 아직 없다.
- 실제 사용자 앱·작업·계정·백업은 수정하지 않았다. 실제 클라우드/NAS/Intel 기기·Mac UI 재검증은 남는다. 홈페이지 개별 SafeSync 페이지와 방침만 갱신하며 `/apps/` 비노출을 유지한다.
- 상세: [macOS 사용 안내](macOS/README-ko.md), [검증 현황](macOS/STATUS.md), [실제 검사 출력](macOS/TEST-RESULTS.txt).

# 앱 업데이트 확인·검증 다운로드 — 2026-10-21

- Windows **1.0.0-preview.13**, macOS **0.3.9 (18)**: 자동 확인/다운로드와 환경설정의 수동 확인. 설치는 사용자 승인 이후에만 한다. 이전 버전은 이번 배포본을 직접 설치해야 한다.
- Windows 고정 GitHub 목록과 엄격한 URL·버전·크기·체크섬 검증, 전송 중 임시 파일 분리. 설치 대기에서는 현재 파일을 마치고 미완료 스냅샷을 유지한다. 설정·계정 저장 형식 호환 유지.
- Windows 전체 **997개**(업데이트 전용 39개 포함), 화면 **563개**, 설치 도구 **34개**, 최종 설치 파일 **503개** 해시 및 설치 EXE 자체 검증 통과. 실제 사용자 앱을 설치·종료하지 않음.
- macOS 빌드 `39554150051`, 소스 `b6e0e30`: Universal 빌드·서명·번들 검증. Google Desktop 등록 리소스 유지. ZIP 다운로드 후 사용자 수동 교체이며 실제 Mac UI 조작 검증은 별도.
- `updates/latest.json`은 게시한 설치 EXE/macOS ZIP, `dist/SHA256SUMS.txt` 및 `scripts/publish-updates.mjs`로 생성한다. **Publish update catalog**가 체크섬 변경 때 갱신한다. 파일과 목록을 같은 릴리스 커밋에 게시하고 원격 다운로드도 검증한다.
- 상세: [업데이트 안내](windows-v2/UPDATES.md), [검사 범위](windows-v2/PREVIEW13-VALIDATION.md). 아직 코드 서명/Apple 공증 전이며 체크섬은 저장소 탈취에 대한 독립적 인증이 아니다.
- 홈페이지 개별 페이지·방침만 갱신한다. `/apps/` 목록의 SafeSync 비노출 지시는 유지한다. 사용자 설정·토큰·로그·진단 산출물은 공개하지 않는다.

# 개발자 및 문의 정보 통일 — 2026-10-21

개발자·운영자·설치 게시자는 **Horizon Entertainment**, 기술 지원·개인정보 문의는 **apps@horizonent.co.kr**로 통일한다. Windows 앱 정보·회사/저작권·설치 등록, macOS About·저작권, 이전 PowerShell 참고 소스, 공개 페이지·개인정보처리방침에 반영했다. 별도 SafeSync 이용약관 파일은 현재 없다. 계정 로그인 ID나 GitHub 소유자 이름을 바꾸는 작업은 아니다.

- Windows **1.0.0-preview.12**: 앱/설치/제거 파일의 CompanyName 일치, 501개 설치 페이로드 해시 및 설치파일 자체 검증 통과. 기존 백업 엔진은 변경하지 않았다.
- macOS **0.3.8 (17)**: GitHub macOS 실행 `39542592505`, 소스 `9334c0a`의 Universal 빌드·서명·번들 검증 통과. Google Desktop 등록 리소스는 0.3.7 배포본과 바이트 일치한다. 토큰·원본 개발자 JSON을 추가하지 않았다.
- 바이너리와 웹 문의처를 수정한 새 배포본을 설치해야 앱 정보가 바뀐다. 기존 버전 배포 파일과 과거 커밋은 이력으로 보존한다.
- 사용자 지시에 따라 홈페이지 `/apps/`의 SafeSync 비노출은 계속 유지한다. 이 연락처 변경은 목록 공개 허가가 아니다.

# Windows 프리뷰 11 게시 및 홈페이지 노출 지시 — 2026-10-20

단방향 백업의 내용 동일 판정과 원본 연결 이상 시 삭제 반영을 수정한 `1.0.0-preview.11` 소스·설치 EXE·ZIP·검사 기록을 게시한다. 핵심 958개, 중단·복구 941개, 설치 도구 34개, 설치 파일 해시 500개 검증이 통과했다. [수정 범위](windows-v2/PREVIEW11-VALIDATION.md)와 [최종 설치본](windows-v2/PREVIEW11-PACKAGE-RESULT.md)을 참고한다. macOS 0.3.7 변경사항은 그대로 보존한다.

**지속 적용할 사용자 지시:** 별도 공개 지시 전까지 홈페이지 `/apps/`에 SafeSync 소개·링크·다운로드 카드·목록 구조화 데이터를 다시 추가하지 않는다. `/apps/safesync/` 개별 페이지와 개인정보처리방침은 유지하고 버전·다운로드만 갱신한다. 새 버전 배포 요청은 Apps 목록 재노출 허가가 아니다. 홈페이지 저장소의 README 및 목록 필터에 이 방침을 남겼다.

실행 중인 앱을 자동 설치 업데이트하지 않는다. 실제 계정·작업·스냅샷·로그·진단 산출물은 공개하지 않는다.

# macOS 0.3.7 공개 테스트 업데이트 — 2026-10-20

- 배포본: `dist/SafeSync-macOS-0.3.7-universal.zip`, macOS 14+, arm64/x86_64, 0.3.7 (16).
- 0.3.0 이후 일반 사용자용 클라우드 연결, 창 닫기/Dock 복원, 컬러·다크 아웃라인 메뉴 막대 애니메이션, 메시지 창을 반영.
- Dropbox의 `.DS_Store` 게시가 `409 / to/disallowed_name`으로 거절되는 문제를 재현하고 예약 OS 파일 제외·기존 복구 기록 보관·안전한 오류 분류를 추가.
- 자동 시나리오 67개 통과. 실제 Dropbox의 제한된 시험 폴더 업로드/ID 이동/금지 이름 오류를 확인했으며 전체 실제 클라우드 동기화 통과를 주장하지 않음.
- 사용자 토큰·개발자 전용 OAuth JSON·로컬 심사 자료는 소스에 포함하지 않음. Desktop 앱 등록 리소스는 배포 앱에 포함하며 사용자가 직접 키를 입력하지 않음. 빌드 안내는 `macOS/CLOUD-RELEASE.md` 참고.
- Windows 소스와 배포본은 변경하지 않음. 상세 기능과 한계는 `macOS/README-ko.md`, `macOS/STATUS.md` 참고.

아래는 이전 버전 이력입니다.

# macOS 0.3.0 반영 — 2026-10-20

사용자 요청: Windows preview.10의 탭·버튼·동기화 목록·충돌 기능과 양방향 자동 동기화를 모두 macOS에 반영. Windows 소스는 수정하지 않았다.

- `SyncCoordinator.swift`: 공통 비교 기준과 루트 식별, 양쪽 전체 목록 선행 확인, 최초 합치기/변경 전파/충돌/휴지통, 비교 선택의 전체 선행·직전 검증. 양방향은 전체 목록·해시 재검증 방식이며 Windows USN 최적화와 동일하지 않다.
- `FileComparison.swift`: 파일/루트/해시/ID 스냅샷과 Drive 중복 부모 탐색·사본 보존 이름 변경. 동일한 중복은 삭제 기준을 만들지 않는다.
- `BackupEngine`/`CloudBackupEngine`: 역방향 안전 교체·원본 휴지통, 폴더 복구, 기존 복구 기록/잠금 재사용. 실서비스 다운로드는 메모리 전체 적재 대신 URLSession 임시 파일로 받는다.
- `Store`/`SyncSession`/`WorkspaceViews`: 세 탭, 세션 이력 읽기 전용, 파일 비교·처리 선택, 고정 적용 버튼, 원본 휴지통·검색, 파일 경계 일시정지와 작업 종료 분리. 위치/모드 수정 시 새 ID/일시정지로 저장.
- 63개 검사와 Universal 빌드. 네이티브 QA에서 역방향 실제 적용·원본 휴지통 복구를 확인했다. 실제 클라우드/Intel/NAS/잠자기/공증은 미검증. 설정 창 단계의 네이티브 도구 종료 때문에 설정/새 계정 화면은 미검증.
- QA 데이터 경로 재지정은 DEBUG 빌드의 `/private/tmp/` 환경 변수에서만 허용한다. 배포 빌드는 이 환경 변수를 무시한다. 사용자 계정·작업·토큰·진단 파일을 저장소에 넣지 않는다.

# SafeSync 개발 인계

## 현재 Windows 배포 소스 — 1.0.0-preview.10 (2026-10-19)

사용자 요청으로 검증된 preview.10 소스·설치본·검사 문서를 공개한다. 실행 중 앱·계정·작업·스냅샷은 자동으로 변경하지 않는다. macOS 소스·배포본도 유지한다.

- `Views/Main.xaml`: 중복 휴지통·동기화 상태 도구줄 버튼 제거. 환경설정은 탭 페이지 바깥 공통 제목줄 오른쪽이다. 탭 헤더 오른쪽 48픽셀을 예약하고 `PART_SelectedContentHost`를 유지한다. 작업 관리 그룹은 왼쪽이다.
- `DesktopController.cs`: 제거한 버튼의 이벤트·상태 참조를 정리했다. 탭과 보기 메뉴 동작은 유지한다.
- `WorkspaceToolbarSmoke.cs`와 `Dialogs.cs`: 세 탭·두 테마·두 창 크기, 설정 실제 열기/닫기와 탭 유지, 정렬·비겹침·안내문 회귀 검사다.
- 핵심 860개·화면 548개·설치 34개·파일 499개 해시 일치. 최종 결과와 제한은 [PREVIEW10-VALIDATION.md](windows-v2/PREVIEW10-VALIDATION.md)를 참고한다. 엔진·OAuth·설정 형식 변경은 없다. 인증 토큰과 실제 작업 자료는 공개하지 않는다.

아래는 이전 배포 시점의 기록이다.

## 이전 Windows 배포 소스 — 1.0.0-preview.9 (2026-10-19)

검증된 preview.9 소스·설치본·검사 문서를 사용자 요청으로 공개한다. 실행 중인 앱과 실제 계정·작업·스냅샷은 자동으로 변경하지 않는다. 아래 공개 프리뷰 항목은 당시 인계 기록이다.

- UI: `Workspace.cs`가 기존 화면 정의의 내용만 메인창에 장착한다. 백업 작업 / 동기화 상태 / 휴지통 관리 세 탭이며 동기화·휴지통용 정의는 실제 별도 창으로 Show하지 않는다. 설정/계정/확인은 기존 대화상자다. WPF 이름 범위와 종료 취소 핸들러를 유지하므로 이 정의들을 별도 Show로 되돌리지 않는다. `MainLayoutSplitter`는 Rows/PreviousAndNext이며 활동기록 높이를 저장한다.
- 문제 해결: `FileComparisonDialog.cs` 및 하단 UserControl. 동일 중복 파일은 `RemoteDuplicates.IdenticalAsync`에서 모든 물리 사본의 체크섬을 검사한다. `GoogleDriveDuplicates.cs`의 ID 기반 탐색/보존, `FileComparisons.PrepareDuplicatesAsync`의 확인 재검증을 사용한다. 단순 Dictionary 덮어쓰기 선택은 중복 경로 처리 권한이 아니다. 폴더 보존은 해당 폴더의 내부 파일 전체를 포함한다.
- 양방향의 동일 중복 사본에는 삭제 권한 기준을 부여하지 않는다. 비교 후 변경된 파일·계정·루트·사본 집합은 거부한다. 보존된 사본은 `.SafeSync-conflict-...` 이름의 일반 항목이며 다음 양방향 실행 시 원본에도 복사될 수 있다.
- 실계정의 해당 작업은 일반 오류가 아닌 57개 반복 충돌이었다. 카탈로그 중복 경로 12개와 관련 상위 폴더가 포함됐다. 실계정 읽기 전용으로 실제 충돌 파일 3개의 사본 각 2개가 모두 원본과 내용이 같음을 확인했다. 실제 백업을 강제 실행하거나 사본을 정리하지 않았다. 사용자 파일명과 실제 경로는 공개하지 않는다.
- 검사·산출물: `windows-v2/PREVIEW9-VALIDATION.md`, `windows-v2/README-ko.md`, `windows-v2/TEST-RESULTS.md`를 우선 참고한다. 개인정보·계정 토큰·진단 표본 경로가 든 테스트 산출물은 공개하지 않는다.

## 현재 공개 프리뷰 — 2026-10-19

현재 Windows 코드는 `windows-v2/`의 C#/.NET WPF 앱이다. 내부 개발판 2.0.0-preview 번호를 1.0.0-preview.1로 재정리했다. 데이터 폴더 `SafeSync2-Preview`, 설치 경로 `Programs/SafeSync2`와 제어 채널은 기존 프리뷰 호환을 위해 유지한다. 이전 PowerShell 버전의 설정을 자동으로 덮어쓰지 않는다.

- 진입점: `windows-v2/src/SafeSync.App/Program.cs`, `DesktopController.cs`, `Dialogs.cs`, `Views/`
- 엔진: `SafeSync.Core/BackupEngine.cs`, `TwoWayEngine.cs`, `VerifiedFiles.cs`, `Persistence.cs`, `OfflineJournal.cs`
- 클라우드: `SafeSync.Core/Cloud/`, Dropbox 기본 공개 App Key는 Directory.Build.props의 비밀이 아닌 클라이언트 ID
- 빌드/설치: `windows-v2/scripts/Build.ps1`, `Build-Installer.ps1`, `packaging/`
- 검사: `windows-v2/tests/SafeSync.Tests/`, 핵심 448개·UI 316개·설치 33개 통과, Google 양방향 35개·Dropbox 32개·NAS 22단계 통과
- 동작/주의사항: [양방향 및 Dropbox](windows-v2/TWOWAY-AND-DROPBOX.md), [현재 검증](windows-v2/RELEASE-VALIDATION.md), [Dropbox 공개 심사 인계](windows-v2/DROPBOX-PRODUCTION.md)

현재 Windows EXE/ZIP만 dist에서 제공한다. 구 Windows 배포본 12개는 현재 브랜치에서 제거하며 맥 소스/배포본 0.2.4와 0.2.5는 그대로 보존한다. Git 과거 이력은 지우지 않는다. 인증 토큰, 비밀번호, 사용자 설정, 실제 스냅샷과 테스트 자료는 공개하지 않는다. 아래 내용은 이전 개발 이력이다.

## Windows 2.0 C# 전환 — 2026-10-18

`windows-v2/`에 별도의 C#/.NET WPF 전환 검증본을 구현했습니다. 기존 PowerShell 소스와 설치본은 변경하지 않았습니다. preview.2에는 Google Drive·Dropbox OAuth/PKCE·분할 전송·서비스 체크섬·저널 복구·클라우드 휴지통과, 기존 계정/스냅샷/델타 체크포인트의 복사 승계를 추가했습니다. 실제 계정 시험·변경 커서·USN·대규모 성능·정식 설치는 아직 미완료입니다. 코드 지도, 검사 범위와 다음 단계는 [전환 현황](windows-v2/MIGRATION.md), [검증본 안내](windows-v2/README-ko.md), [검사 기록](windows-v2/TEST-RESULTS.md)을 먼저 읽으세요. 정식 배포본 다운로드는 아직 1.9.15를 가리키며 검증본은 GitHub에 자동 업로드하지 않았습니다.

## macOS 진행 현황 — 2026-10-17

macOS 0.2.5 구현은 `macOS/`에 있으며 배포본은 `dist/SafeSync-macOS-0.2.5-universal.zip`입니다. 아래 Windows 인계 내용은 초기 기준 자료입니다. 현재 맥의 사용·빌드·검증 범위는 [macOS 안내](macOS/README-ko.md)와 [검증 현황](macOS/STATUS.md)을 우선 참고하세요. Windows 실행 코드와 배포본은 그대로 보존합니다.

## 기준과 범위

이 저장소의 Windows 앱은 `outputs/SafeSync/SafeSync.ps1`의 `AppVersion = '1.9.15'`를 기준으로 합니다. 소스는 Windows PowerShell 5.1, WPF/XAML 및 .NET Framework 기반이며, `work/packaging/`의 C# 런처·설치 도구로 배포합니다. 이 코드는 macOS에서 그대로 실행되지 않습니다.

`dist/`에는 같은 버전의 설치 EXE와 무설치 ZIP을 보관합니다. Windows에서의 상세 동작은 `outputs/SafeSync/README-ko.md`를 참조하세요. GitHub Pages의 `index.html`과 `privacy.html`은 앱 빌드와 무관한 공개 안내 페이지입니다.

## 핵심 소스 지도

| 위치 | 역할 |
| --- | --- |
| `outputs/SafeSync/SafeSync.ps1` | 작업 설정, 스케줄러, 변경 감지, 스냅샷, 백업 판단, WPF 메인/진행/충돌/휴지통 UI |
| `outputs/SafeSync/SafeSync.Cloud.ps1` | Dropbox·Google Drive OAuth/API, 변경 커서, 업로드·검증·교체 |
| `outputs/SafeSync/SafeSync.Integrity.ps1` | 안전한 파일 복사와 검증, 복구 관련 로직 |
| `outputs/SafeSync/SafeSync.TrashWorker.ps1` | 휴지통 조회·복구·삭제의 백그라운드 작업 |
| `work/packaging/Launcher.cs` | Windows 앱/알림 영역 실행 런처 |
| `work/packaging/InstallerCore.cs`, `InstallerUI.cs`, `Setup.cs`, `Uninstall.cs` | 설치 및 제거 |
| `work/packaging/build.ps1`, `New-TrayIcons.ps1` | 빌드 및 알림 영역 아이콘 생성 |
| `work/safesync-*-tests.ps1` | 부분 기능 회귀 검사 |

## 보존해야 할 동작

- 로컬·외장·네트워크 드라이브와 Dropbox·Google Drive API를 백업 위치로 선택합니다.
- 파일 변경 감지 또는 예약 시간으로 자동 실행하며, 일시정지·재개와 앱 종료 후 변경 감지를 지원합니다.
- 파일의 경로·생성/수정 시간·크기를 비교하고, 충돌은 다른 파일의 백업을 막지 않은 채 사용자에게 별도 처리 선택지를 제공합니다.
- 덮어쓰기는 임시 사본, 크기·체크섬 검증, 안전한 교체와 복구 기록을 거칩니다.
- 삭제·교체된 백업 파일은 SafeSync 휴지통에 보관하고, 보관 기간과 복구·완전 삭제를 관리합니다.
- 진행 창은 독립적이고, 최소화·알림 영역 실행, 사용 중 파일의 재시도, 라이트/다크 모드와 알림음 설정을 제공합니다.

## 사용자 데이터와 보안

Windows 사용자별 설정·인증 정보·스냅샷은 `%LOCALAPPDATA%\SafeSync`에 보관됩니다. 여기에는 OAuth 토큰과 클라우드 연결 정보가 있으므로 **GitHub에 올리면 안 됩니다**. `manifests/`의 스냅샷도 실제 백업 대상 경로를 포함할 수 있습니다. 실제 원본/백업 파일, 로그, 인증 정보, `secrets.key`는 이 저장소에 포함하지 않았습니다.

macOS로 작업을 옮길 때는 저장소를 복제한 뒤 **새로운 macOS 앱 프로젝트**를 만드는 것이 적절합니다. Windows의 DPAPI 암호화 데이터는 맥에서 직접 해독할 수 없으므로 클라우드 계정은 macOS 앱에서 다시 인증해야 합니다. 작업과 스냅샷의 자동 이전은 별도 마이그레이션 설계·검증이 필요하며, 파일을 무작정 복사해서 사용하면 안 됩니다.

## macOS 이식 시 우선 결정할 사항

1. SwiftUI와 필요한 부분의 AppKit으로 데스크톱 UI·메뉴 막대를 구현합니다. Windows WPF 레이아웃의 화면 흐름은 참고할 수 있지만 픽셀 단위 동일성보다 macOS 사용성을 검증합니다.
2. Windows FileSystemWatcher/USN Journal에 대응하는 FSEvents와 재시작 후 변경 추적 방식을 설계합니다. 네트워크 볼륨에서는 이벤트 신뢰성이 다를 수 있으므로 안전한 전체 검사 대체 경로를 둡니다.
3. 임시 파일 작성·체크섬 검증·원자적 교체·휴지통 보관과 실패 복구를 macOS 파일시스템 특성에 맞춰 재구현합니다.
4. Dropbox/Google Drive API의 공통 백업 규칙은 재사용하되 OAuth 리디렉션, 토큰 저장은 macOS Keychain에 맞게 다시 구현합니다.
5. 자동 시작, 파일/네트워크 권한, 앱 서명·공증, 실제 NAS 및 클라우드 계정 테스트를 별도로 확인합니다.

## 시작 순서

1. 맥북에서 이 저장소를 복제하고 이 문서와 `README-ko.md`를 읽습니다.
2. Windows 원본과 macOS 목표 동작의 차이를 표로 정리하고, 로컬 폴더 백업·검증·휴지통부터 작은 테스트로 구현합니다.
3. 변경 감지와 재시작 복구, 클라우드 API, 독립 진행/충돌 UI를 순차적으로 추가합니다.
4. 삭제·덮어쓰기·충돌·네트워크 단절·중간 종료 테스트를 통과한 뒤 서명/공증 배포를 준비합니다.

Windows 1.9.14의 모든 기능이 macOS에서 검증된 것은 아닙니다. 이 저장소의 테스트 스크립트는 Windows 회귀 검사이며, 맥용 앱의 테스트를 대신하지 않습니다.

Windows 1.9.14 메인창은 `macOS/Sources/SafeSyncApp/SafeSyncApp.swift`의 MainView(4398b716 기준) 구성을 반영합니다. `work/safesync-main-layout-tests.ps1`은 빈 목록, 선택·일시정지 동작, 작업 관리 메뉴 전달, 라이트·다크 화면과 좁은 창의 하단 표시를 검증합니다.

Windows 1.9.14는 메인창의 메뉴·컨텍스트 메뉴를 테마별 사용자 지정 템플릿으로 표시하고 휴지통 관리 바로가기를 제공합니다. 좁은 창에서는 실제 클라이언트 영역을 기준으로 활동 기록 높이를 제한합니다.
