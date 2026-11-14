각 작업은 자기 worktree와 브랜치(`groups/<task-id>`)에서 하고 PR은 `feat/groups`로 연다. 공유 파일
(`Package.swift`, `project.pbxproj`, `scripts/check.sh`, CI, `web/admin/snapshot/**`, String Catalog)은 Phase 0과
Phase 2에서만 고친다. Phase 1 작업끼리는 맡는 파일이 겹치지 않는다. 계약은 `design.md`가 원본이다 — 바꿔야 하면
먼저 design.md를 고치는 PR을 낸다.

## 0. Phase 0: 계약 (순서대로)

### T0.1 스펙 — `openspec/changes/add-private-groups/**`, `docs/group-server.md`

- [x] 0.1.1 proposal, design(API·스키마·오류 코드·worker·제한), tasks, `specs/private-groups`, `specs/group-server`
- [x] 0.1.2 스크랩의 CloudKit 스키마 영향 확인(design.md 15절: 변경 없음)
- [x] 0.1.3 `docs/group-server.md`를 계획의 바뀐 점(경로 기준 터널, 콘솔 신고 페이지 + 내부 라우트, polling worker,
      전체 범위)에 맞춤
- [ ] 0.1.4 주인 승인

### T0.2 계약·배선 — `server/PilgrimAPI/**`, 루트 `Package.swift`, `project.pbxproj`, `scripts/check.sh`, `.github/workflows/check.yml`, `web/admin/snapshot/**`, `web/admin/src/content/modules.ts`(콘솔 모듈 목록), `Sources/JournalGroups/GroupAPI.swift`, `Sources/JournalGroups/PreviewGroupAPI.swift`

- [x] 0.2.1 `server/PilgrimAPI` 패키지(Foundation만, swift-tools 6.2, iOS 17 / macOS 14 / Linux)
- [x] 0.2.2 design.md "API"의 모든 DTO, `APIErrorCode`(모르는 값 → `unknown`), `APIErrorBody`, `Page<T>`,
      `ReactionKey` 사용자 정의 Codable, `LocalDate`·`LocalTime`, `PilgrimJSON`, `ClientHeader`, `APILimits`,
      `BundleIDs`, `PushPayload`·`PushLocKey`, 운영자 DTO
- [x] 0.2.3 `PostExpiryPolicy`, `AdminVoteRules`, `PhotoLimits`, `InviteCode` 순수 함수
- [x] 0.2.4 테스트: DTO JSON 왕복(고정 JSON 픽스처와 비교), 기한 표의 모든 행(시간대·서머타임·축소 모드), 투표 결과
      전 경우(무투표·단독·동률·재투표 동률·재투표 무투표·후보 이탈·멤버 0), 사진 한도, 초대 코드 정규화
- [x] 0.2.5 루트 `Package.swift`에 `.package(path: "server/PilgrimAPI")`, `JournalGroups` 타깃(빈 구현 +
      `GroupAPI` 프로토콜 + `PreviewGroupAPI`), `Tests/JournalGroupsTests` 자리
- [x] 0.2.6 `project.pbxproj`에 로컬 패키지와 `JournalGroups` 링크. iOS·macOS unsigned xcodebuild 통과(못 링크하면
      `JournalGroups`가 `@_exported import PilgrimAPI`) — 링크됨, 앱에서 `import PilgrimAPI` 직접 가능, re-export 안 함
- [x] 0.2.7 `scripts/check.sh`가 `server/` swift format lint와 `swift test --package-path server/PilgrimAPI`를 돌림.
      CI에 `server` job(Linux, Postgres 17 서비스, `swift test --package-path server`) 추가 — T0.2는 자리만
      (macos-26에서 `swift test --package-path server/PilgrimAPI`). Linux·Postgres·`server` 패키지는 T0.4가 넓힌다
- [x] 0.2.8 `web/admin/snapshot/**`와 콘솔 모듈 목록 갱신(`swift run AdminSnapshot`)

### T0.3 앱 뼈대 — `AppModel.swift`, `AppModel+Selection.swift`, `ContentView.swift`, `JournalSidebar.swift`, `JournalSessionController.swift`, `PilgrimJournalApp.swift`, `FamilySharing.swift`(delegate 부분), `Sources/PilgrimJournal/Groups/` stub

- [x] 0.3.1 `GroupsFeature.isEnabled`(Debug 켜짐, Release 꺼짐, 환경 변수로 덮어쓰기)
- [x] 0.3.2 `AppModel.selectedGroupID`, 사이드바 "그룹" 섹션 자리, 피드·상세 stub 화면
- [x] 0.3.3 `JournalSessionController.makeAppModel(for:)`에서 `GroupsController` 주입(`PreviewGroupAPI`)
- [x] 0.3.4 app/scene delegate: 푸시 토큰 수신, 알림 탭 처리, `/i/*` Universal Link를 `PendingGroupInvite`로 넘기는 자리
- [x] 0.3.5 플래그를 끈 상태로 기존 테스트 전부 통과, iOS·macOS xcodebuild 통과

### T0.4 서버 뼈대 (T0.3과 병렬) — `server/**`(PilgrimAPI 제외)

- [x] 0.4.1 `server/Package.swift`(Vapor 4.122, Fluent 4.13, FluentPostgresDriver 2.14, swift-crypto),
      `PilgrimServerCore`(앱 로직, `@testable import`)·`PilgrimServer`(진입점)·`PilgrimServerTests` 타깃,
      `PilgrimServer serve|worker|migrate`. 아래 작업의 `server/Sources/App/<모듈>/**`는
      `server/Sources/PilgrimServerCore/<모듈>/**`이고, 모듈마다 `<모듈>Module.register(_:)`가 이미 있다.
      JWT·APNS·app-store-server-library는 쓰는 작업(S1·S5·S8)이 `server/Package.swift`에 한 줄씩 더한다
- [x] 0.4.2 design.md "Postgres 스키마"의 Fluent 모델과 마이그레이션 전부(트리거 `media_after_delete`, 부분 UNIQUE,
      CHECK 포함)
- [x] 0.4.3 공통 헬퍼: `ContentVisibility`(만료·멤버·차단·숨김 필터), `PushOutbox.enqueue`, `MediaStore`(경로,
      서명 URL), `ClientGate`(426), `Idempotency`, `RateLimiter`, `APIError` → 응답 변환, 인증 미들웨어 자리,
      worker 루프 실행기(advisory lock·heartbeat·간격 — S5의 1.5.1을 미리 함)
- [x] 0.4.4 Postgres 테스트 하네스(프로세스당 한 번 스키마 재생성 + 테스트마다 TRUNCATE, `TEST_DATABASE_URL`
      없으면 건너뜀), `/api/health`
- [x] 0.4.5 Dockerfile(arm64, 빌드·실행 단계 분리), dev compose, `TIME_SCALE_DAY_SECONDS`, `make -C server dev`/`test`
      (T0.4 때 로컬 Docker가 응답하지 않아 compose·Postgres 테스트는 CI `server` job에서 처음 돈다)

## 1. Phase 1, 1차 묶음

### S1 인증·계정 — `server/Sources/App/Auth/**`, `server/Sources/App/Account/**`

- [ ] 1.1.1 Apple identityToken 검증(가짜 JWKS로 테스트: iss·aud 두 번들·exp·nonce·kid 갱신)
- [ ] 1.1.2 code 교환(가짜 Apple 토큰 엔드포인트), 실패 시 502, Apple refresh token AES-GCM 저장
- [ ] 1.1.3 access JWT, refresh 회전, 재사용 감지(family 폐기), 같은 기기 30초 유예, 로그아웃
- [ ] 1.1.4 개발 로그인과 운영 설정 시작 거부
- [ ] 1.1.5 `GET/PATCH /me`(이름·프로필 사진·시간대·리포트 시각), 가입 전 403, 정지 403
- [ ] 1.1.6 기기 등록·삭제(토큰 이동 정리), 차단·숨김 목록 조회 라우트는 S4
- [ ] 1.1.7 `DELETE /me`: 투표 시작·그룹 삭제·폐기 대기열·cascade·`alreadyDeleted` 테스트

### S2 그룹·초대·투표 — `server/Sources/App/Groups/**`, `Invites/**`, `Votes/**`, `Web/**`

- [ ] 1.2.1 그룹 CRUD, 7일 유예 삭제, 나가기(관리자 → 투표, 1명 → 바로 관리자, 0명 → 삭제), 강퇴·강퇴 해제, 넘기기,
      `seen`, 그룹별 알림 설정, 멤버 페이지, 그룹 수 제한
- [ ] 1.2.2 투표 시작·조회·투표(바꾸기), 투표 중 관리자 권한 409
- [ ] 1.2.3 초대 만들기·목록·취소, 미리보기, 수락(조건부 UPDATE). 동시 수락 인원 초과 없음 테스트, 강퇴·투표 중·
      삭제 예정 거부
- [ ] 1.2.4 AASA(두 앱 ID), `/i/:code` 정적 페이지(그룹 정보 없음)
- [ ] 1.2.5 비멤버 404 테스트(모든 그룹 하위 라우트)

### S3 글·댓글·반응 — `server/Sources/App/Posts/**`

- [ ] 1.3.1 글 만들기(종류별 검증, `PostExpiryPolicy`), 피드 커서 페이징, 상세, 삭제(작성자·관리자)
- [ ] 1.3.2 멱등 처리(`clientId`), 토론 연장(독후감만, 멱등)
- [ ] 1.3.3 댓글(텍스트·사진·스티커), 삭제, 반응(이모지·스티커, 자연 키 멱등, 10개 제한)
- [ ] 1.3.4 차단·숨김 필터, 안 읽은 수, `isUnread`
- [ ] 1.3.5 새 글 outbox 넣기(받는 사람 필터 테스트)

### S4 신고·차단·숨김 — `server/Sources/App/Moderation/**`

- [ ] 1.4.1 양방향 차단, 글·사람 숨김 PUT/DELETE/목록
- [ ] 1.4.2 신고와 스냅샷, webhook(본문 없음)
- [ ] 1.4.3 `/internal/admin/v1/*`: `X-Admin-Token`, `Cf-Ray`·`Cf-Connecting-IP` 거부, 신고 목록·상세·처리, 삭제,
      정지·해제, 미디어, 상태, `moderation_log`

### S5 worker — `server/Sources/App/Worker/**`, `server/Sources/App/Push/**`

- [ ] 1.5.1 루프 실행기(advisory lock, heartbeat, 간격)
- [ ] 1.5.2 기한 삭제, 사진 파일 큐, 붙지 않은 업로드 정리, 초대·보관 기간 정리
- [ ] 1.5.3 투표 마감·재투표·무작위·유예 삭제(`AdminVoteRules`), 결과 알림
- [ ] 1.5.4 outbox 발송(`APNSSending` 프로토콜과 가짜 sender), 두 번들 topic, 환경, 무효 토큰 정리, 재시도
- [ ] 1.5.5 Apple 토큰 폐기 재시도
- [ ] 1.5.6 축소 TTL로 전체 흐름 테스트

### A1 JournalGroups — `Sources/JournalGroups/**`(T0.2 파일 제외), `Tests/JournalGroupsTests/**`, `Sources/JournalGroups/Resources/Localizable.xcstrings`

- [ ] 1.6.1 `HTTPTransport` 경계, `URLSessionGroupAPI`(모든 엔드포인트), `X-Pilgrim-Client`
- [ ] 1.6.2 `GroupSessionStore`(Keychain ThisDeviceOnly), 401 시 갱신 단일 실행, 재사용·무효 시 그룹 세션만 정리
- [ ] 1.6.3 오프라인·서버 오류 분류(`GroupClientError`), 426 처리
- [ ] 1.6.4 초대 URL·코드 파서
- [ ] 1.6.5 `ImageCompressor`(1600px, JPEG 0.7→0.3, 500KB, 메타데이터 제거, 방향 반영, 스티커 256 정사각형 100KB)
- [ ] 1.6.6 multipart 업로드, 서명 URL 캐시(미디어 ID 키)

### A2 UI: 멤버십 — `Sources/PilgrimJournal/Groups/GroupsController.swift`, `GroupsSidebarSection.swift`, `Onboarding/**`, `GroupCreateSheet.swift`, `GroupInviteSheet.swift`(QR), `JoinGroupView.swift`, `GroupSettingsView.swift`, `GroupMembersSheet.swift`, `GroupVoteView.swift`, `GroupCredentialStore.swift`, `PendingGroupInvite.swift`, 해당 테스트

- [ ] 1.7.1 온보딩: 약관 동의, Apple 재인증(nonce, 사용자 불일치 거부), 이름·프로필 사진
- [ ] 1.7.2 그룹 만들기, 사이드바 섹션(안 읽은 수), 그룹 설정(이름, 알림, 나가기, 삭제)
- [ ] 1.7.3 초대 만들기(인원, 만료 표시, QR, 공유), 초대 코드 입력, Universal Link 큐, 미리보기·참여 오류 문구
- [ ] 1.7.4 멤버 시트(강퇴, 강퇴 해제, 넘기기)
- [ ] 1.7.5 투표 화면, 투표 중 배너와 관리자 기능 숨김, 삭제 예정 배너
- [ ] 1.7.6 `PreviewGroupAPI`로 컨트롤러 테스트

### A3 UI: 콘텐츠 — `Sources/PilgrimJournal/Groups/GroupFeedView.swift`, `GroupFeedModel.swift`, `GroupPostDetailView.swift`, `GroupPostComposerSheet.swift`, `GroupReportSheet.swift`, `BlockedUsersView.swift`, `HiddenItemsView.swift`, `GroupMediaViews.swift`, `GroupReactionPicker.swift`, 해당 테스트

- [ ] 1.8.1 피드(커서, 화면에 있을 때 15초 polling), 기한 배지, 종류별 카드
- [ ] 1.8.2 작성 화면(종류, 데드라인·공개 기간, 사진 4장), 실패해도 내용 유지, 같은 `clientId` 재시도
- [ ] 1.8.3 상세: 댓글(텍스트·사진·스티커), 이모지·스티커 반응, 토론 연장, 내리기
- [ ] 1.8.4 신고 시트, 차단, 글·사람 숨김, 차단·숨김 목록 화면
- [ ] 1.8.5 사라진 글·서버 연결 실패 상태

## 2. Phase 1, 2차 묶음

### S6 사진·스티커 서버 — `server/Sources/App/Media/**`, `server/Sources/App/Stickers/**`

- [ ] 2.1.1 업로드 검증(JPEG 시그니처, SOF 크기, 목적별 한도), 메타데이터 세그먼트 제거, 저장, 붙이기 규칙
- [ ] 2.1.2 서명 URL 발급·검증(`/api/media-files/:id`), `GET /media/:id`, 비멤버 404
- [ ] 2.1.3 스티커 만들기·목록·삭제, 30개 제한, 삭제 시 반응 정리·댓글 표시

### S7 Daily Report 서버 — `server/Sources/App/DailyReport/**`

- [ ] 2.2.1 시간대별 리포트 시각 대상 선정(서머타임), `daily_report_log` 중복 방지
- [ ] 2.2.2 집계(새 글, 내 글 댓글·반응, 연장, 곧 사라짐, 숨김·차단·그룹별 끄기), 빈 리포트 건너뜀
- [ ] 2.2.3 `GET /me/daily-report`, outbox 넣기

### S8 구독 서버 — `server/Sources/App/Subscriptions/**`

- [ ] 2.3.1 JWS 검증(두 번들, Production·Sandbox), upsert, 다른 사용자 거래 409
- [ ] 2.3.2 Notifications V2 웹훅, 중복 거르기, 상태 반영
- [ ] 2.3.3 `EntitlementPolicy`와 `SUBSCRIPTION_REQUIRED`, `GET /me/entitlement`, 미리보기 `requiresSubscription`
- [ ] 2.3.4 만료 처리(플래그 켜졌을 때만, 한 번만), 오래된 구독 재확인. Apple 테스트 서명 데이터로 테스트

### A4 올리기 연결 — `Sources/PilgrimJournal/Share/**`, `Sources/JournalShareDrafts/Deadline*.swift`, `Sources/ShareCardEval/EvalCalendar.swift`, `Entry/EntryDetailView.swift`, `Entry/MacEntryEditorView.swift`, `EntryRowViews.swift`

- [ ] 2.4.1 `DatePhraseResolver`를 `JournalShareDrafts`로 옮기고(`Calendar` 주입) `DeadlineSuggester` 추가
- [ ] 2.4.2 기도제목 시트에 "그룹에 올리기"(그룹 선택, 데드라인 제안, 공개 기간)
- [ ] 2.4.3 독후감·간증: 기록 내용·책 정보·사진을 채운 작성 화면으로 열기(진입점 3곳)

### A5 계정 삭제 — `Sources/JournalData/AccountDeletionService.swift`, `Sources/PilgrimJournal/AppleAuthenticationCoordinator.swift`, `Sources/PilgrimJournal/AccountDeletionViews.swift`, `Sources/PilgrimJournal/Groups/GroupAccountErasure.swift`

- [ ] 2.5.1 `RemoteAccountDataErasing` 프로토콜, 모든 범위에서 가장 먼저 실행, 실패 시 멈춤, 멱등
- [ ] 2.5.2 refresh 무효면 Apple 재인증 후 삭제, 그룹 Keychain 정리
- [ ] 2.5.3 확인 화면: 관리 그룹 투표 안내, 구독 해지 안내

### A6 스크랩 — `Sources/PilgrimJournal/AppModel+Scrap.swift`, `Sources/JournalDomain/Scrap*.swift`, `Sources/JournalDomain/JournalTypes.swift`(`BuiltInKind.scrap`), `Sources/JournalDomain/KindCatalog.swift`, `Sources/PilgrimJournal/KindDisplayName.swift`, 해당 테스트

- [ ] 2.6.1 `BuiltInKind.scrap`을 맨 뒤에 추가(teal, `bookmark`, 직접 만들기 불가, 삭제 가능), `EntryDetails`
      처리, 표시 이름
- [ ] 2.6.2 `KindCatalog`: 저장된 정의가 없으면 목록에서 숨김, `materialize`(이름 충돌 시 "그룹 스크랩"), 삭제 후 restore
- [ ] 2.6.3 `ScrapComposer`(순수 함수): 글·댓글·사진 → `JournalEntryDraft` + 첨부 목록, 머리·표식 형식, 제목 규칙
- [ ] 2.6.4 `AppModel+Scrap`: 사진 내려받기 → 첨부 저장, 노트북 만들기 경로(삭제 목록에서 빼기), 이미 스크랩 확인,
      언제나 내 기록장
- [ ] 2.6.5 테스트: 변환, 노트북 생성, 기존 사용자 카탈로그가 바뀌지 않음, 옛 카탈로그 JSON 디코딩, 기본 유형 색·아이콘
      순서 불변

### A7 알림·리포트 UI — `Sources/PilgrimJournal/Groups/DailyReportView.swift`, `Sources/PilgrimJournal/Groups/GroupNotifications.swift`, `SettingsView.swift`(새 `Section`만)

- [ ] 2.7.1 처음 그룹 만들기·참여 때 알림 권한, 기기 등록(환경·번들·시간대)
- [ ] 2.7.2 알림 탭 → 글·리포트·그룹(잠금 해제 뒤), 사라진 글 처리
- [ ] 2.7.3 Daily Report 화면, 설정의 그룹 섹션(리포트 켜기·시각, 차단·숨김 목록 링크)

### A8 구독 UI — `Sources/PilgrimJournal/Groups/Subscription/**`, `PilgrimJournal/PilgrimJournal.storekit`

- [ ] 2.8.1 PR #27 코드 이식(상품 ID 바꿈), 구독 화면, 구매(`appAccountToken`), 복원
- [ ] 2.8.2 JWS를 서버로(실행 때, `Transaction.updates`), entitlement가 꺼져 있으면 화면 건너뜀
- [ ] 2.8.3 StoreKit 테스트 설정 파일로 테스트

### I1 인프라 — `server/Makefile`, `server/docker-compose*.yml`, `server/scripts/**`, `server/.env.*.example`, `PilgrimJournal/PilgrimJournal/PilgrimJournal.entitlements`, `PilgrimJournal/PilgrimJournal/iOS-Info.plist`, `web/admin/docker-compose.yml`

- [ ] 2.9.1 놀담 방식 `make dev/prod/deploy`, `pilgrim-prod` compose, `127.0.0.1:3100`, 사진 볼륨
- [ ] 2.9.2 공유 Docker 네트워크 `pilgrim-edge`(api·admin)
- [ ] 2.9.3 restic → R2(DB 덤프 + 사진) launchd, 7일 보관, 복원 스크립트
- [ ] 2.9.4 `aps-environment`, `applinks:pilgrim.delight-house.org`(두 앱 ID), 백그라운드 모드 필요 여부 확인
- [ ] 2.9.5 `.env.dev.example`, `.env.prod.example`(design.md "환경 변수")

### W1 콘솔 신고 페이지 — `web/admin/src/**`, `web/admin/test/**`

- [ ] 2.10.1 내부 API 클라이언트(`ADMIN_API_TOKEN`, `X-Admin-Actor`)
- [ ] 2.10.2 신고 목록·상세(스냅샷, 원본, 사진), 삭제, 정지·해제, 처리 완료
- [ ] 2.10.3 `npm test`, typecheck 통과

### D1 문서 — `docs/**`, `CLAUDE.md`

- [ ] 2.11.1 `docs/privacy.md`: 서버 저장 항목, 사진, 구독, Cloudflare, 백업·보관 기간, 콘솔이 사용자 데이터를 다룸,
      신고 스냅샷 90일, 스크랩이 남의 글을 내 iCloud에 둠, Apple 토큰 폐기
- [ ] 2.11.2 `docs/roadmap.md`(사이드바 "그룹", 이번 범위 반영), `docs/pre-release-checklist.md`,
      `docs/device-verification.md`(새 세션), `docs/development.md`(서버 운영, 터널, Apple·APNs 키, StoreKit),
      `docs/implementation-todo.md`, `CLAUDE.md`(server·PilgrimAPI·JournalGroups)

## 3. Phase 2: 통합 (순서대로)

- [ ] 3.1 현지화: 앱 `Localizable.xcstrings`(푸시 `PushLocKey` 포함)와 `InfoPlist.xcstrings`(알림·사진·카메라 권한
      문구)에 새 키의 영어를 채운다
- [ ] 3.2 `JournalSessionController`에서 `PreviewGroupAPI`를 `URLSessionGroupAPI`로 바꾼다
- [ ] 3.3 전체 검증: `./scripts/check.sh`, `make -C server test`, iOS·macOS xcodebuild, iOS 시뮬레이터 테스트, CI, 계획의
      로컬 시나리오(가입·초대·글·스크랩·기한·안전·Daily Report·투표·구독·계정 삭제), `xcrun simctl push`
- [ ] 3.4 맥미니 배포, 터널 ingress(콘솔 규칙보다 앞), Cloudflare 봇 규칙 예외(`/api`, `/.well-known`), 실기기
      체크리스트(`docs/device-verification.md`)
- [ ] 3.5 main에 조각내어 합치기: 서버·CI 먼저, 앱은 Release `GroupsFeature.isEnabled = false`. entitlement는 1.2.0
      출시 뒤
