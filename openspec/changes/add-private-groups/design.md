## Context

- 승인된 계획(2026-11-14, `shimmying-seeking-tiger`)이 범위와 규칙의 원본이다. 기능 요구는
  `docs/roadmap.md`, 서버 운영 방식은 `docs/group-server.md`(이 변경과 함께 고침)를 따른다.
- 원칙(2026-11-03): 개인 기록은 기기 + 사용자 CloudKit private DB, 공유·SNS는 자체 서버. 그룹에 올린 카드와
  그룹 활동만 서버에 간다. 일기 원문은 가지 않는다.
- 지금 코드에 그룹 관련 코드는 없다(`server/`, `PilgrimAPI`, `JournalGroups`, 앱 네트워킹,
  UserNotifications, StoreKit, associated domains, `aps-environment` 모두 없음).
- 이어서 쓸 것:
  - CKShare 가족 공유(#33, #38): `FamilySharing.swift`의 app/scene delegate와 `PendingShareInvitations`,
    `SharedSpacesViews.swift`의 사이드바 섹션, `JournalSessionController.makeAppModel(for:)`의 컨트롤러 주입.
  - 기도제목 나누기(#41): `JournalShareDrafts`의 `PrayerRequestDraft`(`text`, `language`, `topic`, `who`),
    `PrayerRequestShareSheet`.
  - 닫힌 PR #27(`origin/claude/unruffled-mcclintock-e5bb85`)의 StoreKit 코드(`FeatureAccess.swift`,
    `PremiumViews.swift`, `PilgrimJournal.storekit`, `PremiumEntitlementTests.swift`).
  - 맥미니 관리자 콘솔 `web/admin`(Node + Hono, `127.0.0.1:8420`)이 이미 `pilgrim.delight-house.org/`와
    `/admin`을 쓴다.
- Apple 로그인은 identityToken을 저장하지 않고, 다시 로그인하는 사용자에게는 새 토큰이 나오지 않는다. 그래서
  그룹을 시작할 때 nonce를 붙인 Apple 인증을 새로 받는다.
- 번들 ID는 Debug `com.dhouse.PilgrimJournal.debug`, Release `com.dhouse.PilgrimJournal` 두 개다.

## Goals / Non-Goals

**Goals:**
- 로드맵의 그룹 기능 전체를 한 번에: 그룹·초대·관리자 투표·글 세 종류·기한 삭제·토론 연장·사진·댓글·
  이모지와 스티커 반응·신고·차단·숨김·새 글 푸시·Daily Report·스크랩·구독(꺼 둔 채로).
- 앱과 서버가 같은 Swift 계약 패키지(`PilgrimAPI`)를 쓴다. 규칙(기한, 투표, 사진 제한)은 순수 함수로 한 곳에 둔다.
- 이후 병렬 작업(S1~S8, A1~A8, W1)이 이 문서만 보고 DTO·마이그레이션·화면을 만들 수 있게 이름과 타입을 정한다.
- CloudKit 스키마, 백업 형식, 기존 기록장 동작을 바꾸지 않는다.
- 서버가 꺼져도 기록장은 그대로 동작하고 작성 중인 글을 잃지 않는다.

**Non-Goals:**
- 공개 그룹, 검색 노출, 그룹 간 이동, 웹 클라이언트. `/i/:code` 페이지에는 그룹 정보를 싣지 않는다.
- 종단 간 암호화(전송 TLS + 맥미니 FileVault, `docs/group-server.md` 결정 6).
- 부적절 단어 자동 필터(신고·차단·숨김·약관으로 대응).
- 서버 쪽 사진 썸네일·재인코딩, HEIC(JPEG만 받는다).
- 댓글에 대한 반응, 글 수정(올린 뒤에는 내리고 다시 올린다).
- 실시간 연결(WebSocket). 피드는 화면에 있을 때 15초 polling.
- 여러 서버 인스턴스. API 한 개와 worker 한 개를 전제로 한다(rate limit은 프로세스 메모리).

## 구성

```
iPhone/Mac 앱 ──HTTPS──▶ Cloudflare ──Tunnel──▶ 맥미니 (delight)
                                                 ├─ cloudflared
                                                 │    ├─ ^/(api/|i/|\.well-known/) → http://localhost:3100
                                                 │    └─ 나머지                    → http://localhost:8420 (web/admin)
                                                 ├─ docker compose -p pilgrim-prod
                                                 │    ├─ api      127.0.0.1:3100  (serve)
                                                 │    ├─ worker                   (worker, 같은 이미지)
                                                 │    └─ postgres                 (내부망만)
                                                 ├─ docker compose -p pilgrim-admin
                                                 │    └─ admin    127.0.0.1:8420  ──▶ http://pilgrim-api:3100/internal/admin/v1
                                                 │                                  (공유 Docker 네트워크 pilgrim-edge)
                                                 └─ 볼륨: postgres, media / restic → Cloudflare R2 (launchd)
```

- `/internal/admin/v1`은 터널 규칙에 없으므로 인터넷에서 오면 콘솔(8420)로 가고, 콘솔은 그 경로를 처리하지
  않는다(404). 서버는 추가로 `X-Admin-Token`을 요구하고 `Cf-Ray` 헤더가 붙은 요청을 거부한다.
- `/admin`, `/`는 지금처럼 콘솔이다. `/api/health`는 `^/api/`에 걸려 서버로 간다.

## Decisions

### 1. 패키지 구성

```
server/
├─ PilgrimAPI/                 Foundation만. 앱과 서버가 함께 의존
│  ├─ Package.swift            swift-tools 6.2, platforms iOS 17 / macOS 14 (Linux는 platforms 무관)
│  ├─ Sources/PilgrimAPI/
│  │  ├─ Coding/               PilgrimJSON(encoder/decoder), LocalDate, LocalTime
│  │  ├─ Common/               APIErrorCode, APIErrorBody, Page<T>, ClientHeader, APILimits, IDs
│  │  ├─ Auth/  Account/  Groups/  Invites/  Votes/  Posts/  Comments/  Reactions/
│  │  ├─ Stickers/  Media/  Safety/  DailyReport/  Subscriptions/  Push/  Admin/
│  │  └─ Policy/               PostExpiryPolicy, AdminVoteRules, PhotoLimits, InviteCode
│  └─ Tests/PilgrimAPITests/   DTO 왕복, 규칙 함수
├─ Package.swift               Vapor 앱. .package(path: "PilgrimAPI")
├─ Sources/App/
│  ├─ Auth/ Account/ Groups/ Invites/ Votes/ Web/ Posts/ Moderation/
│  ├─ Media/ Stickers/ DailyReport/ Subscriptions/ Push/ Worker/
│  ├─ Common/                  ContentVisibility, PushOutbox, MediaStore, ClientGate, Idempotency, RateLimiter
│  ├─ Models/                  Fluent 모델
│  └─ Migrations/
├─ Sources/Run/main.swift      `serve` | `worker` | `migrate`
└─ Tests/AppTests/             Postgres 테스트 하네스(XCTVapor 또는 Swift Testing)
```

- 루트 `Package.swift`는 `.package(path: "server/PilgrimAPI")`로 쓰고, `JournalGroups`가
  `.product(name: "PilgrimAPI", package: "PilgrimAPI")`에 의존한다. 앱 쪽에는 Vapor 의존성이 들어오지 않는다.
- Xcode가 로컬 패키지의 `PilgrimAPI`를 앱 타깃에 직접 링크하지 못하면 `JournalGroups`가
  `@_exported import PilgrimAPI`로 다시 내보낸다(T0.2에서 확인).
- 앱 라이브러리 `Sources/JournalGroups/`: `GroupAPI` 프로토콜과 `URLSessionGroupAPI`, `PreviewGroupAPI`,
  `HTTPTransport` 경계, `GroupSessionStore`(Keychain), 토큰 갱신 단일 실행, `GroupStore`, `ImageCompressor`
  (ImageIO), multipart 업로드, 초대 URL 파서, 라이브러리 String Catalog.
- 앱 UI `Sources/PilgrimJournal/Groups/`. 스크랩 변환 순수 함수는 `JournalDomain`(A6).
- DTO 이름은 이 문서의 API 절과 같게 한다. JSON 키는 Swift 프로퍼티 이름 그대로(camelCase).

### 2. 공통 HTTP 규약

- 기본 주소 `https://pilgrim.delight-house.org/api/v1`. 개발은 `http://localhost:3100/api/v1`
  (빌드 설정 `PILGRIM_GROUP_SERVER_URL`).
- 인증: `Authorization: Bearer <accessToken>`. 표시가 없는 엔드포인트는 모두 인증이 필요하다.
- **`X-Pilgrim-Client`** 헤더: `<platform>/<marketingVersion> (<build>) <bundleId>`, 예
  `ios/1.3.0 (31) com.dhouse.PilgrimJournal`. `/api/v1/*` 전부에서 필수다. 없거나 형식이 틀리거나
  버전이 `MIN_CLIENT_VERSION`보다 낮으면 426 `CLIENT_UPGRADE_REQUIRED`. bundleId가 두 ID 밖이면 400.
  웹훅(`/api/appstore/notifications`), 서명 미디어 URL, `/api/health`, AASA, `/i/*`는 검사하지 않는다.
- JSON: UTF-8, `PilgrimJSON.encoder`/`decoder`. 날짜·시각은 ISO 8601 UTC(`2026-11-14T13:05:00.123Z`, 쓸 때
  밀리초 포함, 읽을 때 소수 초 있든 없든). 달력 날짜는 `LocalDate`(`"2026-11-20"`), 시각은 `LocalTime`
  (`"22:00"`). ID는 UUID 소문자 문자열. optional 값은 키를 빼거나 `null` 둘 다 받는다.
- 오류 응답 본문(모든 4xx·5xx):
  ```json
  { "error": { "code": "INVITE_FULL", "message": "invite has no remaining uses",
               "field": null, "limit": null, "retryAfter": null } }
  ```
  `APIErrorBody { error: APIError }`, `APIError { code: APIErrorCode, message: String, field: String?,
  limit: Int?, retryAfter: Int? }`. `message`는 개발자용 영어이고 화면에 보이지 않는다. 앱은 `code`로 문구를
  고른다(현지화는 앱 책임).
- **멱등성:** 리소스를 만드는 쓰기(`groups`, `invites`, `posts`, `posts/:id/extend`, `comments`, `stickers`,
  `uploads`, `reports`)는 본문(업로드는 multipart 필드)에 `clientId: UUID`를 받는다. 테이블마다
  `UNIQUE(<작성자>, client_id)`가 있고, 같은 `clientId`가 다시 오면 새로 만들지 않고 **처음 만든 리소스를
  200으로** 돌려준다(처음은 201). 내용이 달라도 처음 것을 돌려준다. 반응·차단·숨김·기기 등록은 자연 키
  `PUT`/`DELETE`라 원래 멱등이다.
- **페이징:** `?cursor=<opaque>&limit=<n>`, 응답 `{ items: [...], nextCursor: String? }`
  (`Page<T>`). 커서는 `(createdAt, id)`를 base64url로 감싼 값이고 앱은 해석하지 않는다. limit 기본 20,
  최대 50.
- **rate limit:** 사용자별(인증 전 엔드포인트는 IP `Cf-Connecting-IP`별) token bucket, 프로세스 메모리.
  넘으면 429 `RATE_LIMITED` + `Retry-After` 초. 값은 "제한" 절.
- 존재를 숨긴다: 멤버가 아닌 그룹·그 그룹의 글·댓글·스티커·미디어, 기한이 지난 글, 차단 관계로 보이지 않는
  글은 모두 404 `NOT_FOUND`로 같게 답한다.

### 3. 인증과 가입

1. 앱이 32바이트 무작위 `rawNonce`를 만들고 `ASAuthorizationAppleIDRequest.nonce = SHA256(rawNonce)`
   (소문자 hex)로 Apple 인증을 받는다. scope는 요청하지 않는다.
2. `credential.user`가 기록장 세션의 Apple 사용자와 다르면 서버에 보내지 않고 거부한다
   ("기록장에 로그인한 Apple 계정으로 인증해 주세요").
3. `POST /auth/apple { identityToken, authorizationCode, rawNonce, bundleId, installationId }`.
4. 서버는 Apple JWKS(`https://appleid.apple.com/auth/keys`, 1시간 캐시, `kid`가 없으면 즉시 다시 받음)로
   RS256 서명, `iss == https://appleid.apple.com`, `aud == bundleId`이고 bundleId가 두 ID 중 하나,
   `exp`, `nonce == SHA256(rawNonce)`를 검사한다.
5. `authorizationCode`를 `https://appleid.apple.com/auth/token`에서 교환한다(`client_id = bundleId`,
   client secret은 Sign in with Apple 키 `.p8`로 서명한 ES256 JWT, 5분 유효). 받은 Apple refresh token은
   `APPLE_TOKEN_ENC_KEY`(AES-256-GCM)로 암호화해 `apple_tokens(user_id, client_id)`에 덮어쓴다. **교환이
   실패하면 로그인도 실패한다**(502 `APPLE_CODE_EXCHANGE_FAILED`) — 계정 삭제 때 폐기할 토큰을 반드시
   갖기 위해서다.
6. `users.apple_sub`로 사용자를 찾거나 만든다(`display_name`은 아직 null). 세션을 발급한다.
7. 응답 `AuthSessionResponse.user.profileComplete == false`면 앱이 가입 화면(약관 동의, 이름 1~30자,
   프로필 사진 선택)을 보여 주고 `PATCH /me`로 저장한다. `SUBSCRIPTION_REQUIRED`가 켜져 있고 구독이 없으면
   가입 화면 다음에 구독 화면이 이어진다.

**세션 토큰**

- access: HS256 JWT(`JWT_SECRET`), 15분. claims `sub`(사용자 UUID), `sid`(refresh family UUID), `iat`,
  `exp`, `iss = "pilgrim"`, `aud = "pilgrim-app"`. 만료면 401 `TOKEN_EXPIRED`, 그 밖의 문제는 401
  `UNAUTHENTICATED`.
- refresh: 32바이트 무작위 값의 base64url. DB에는 SHA-256만 둔다. 90일. 쓸 때마다 같은 family 안에서 새
  토큰으로 바꾸고 옛 토큰에 `used_at`, `replaced_by_id`를 적는다(새 토큰도 90일).
- **재사용 감지:** 이미 쓴 토큰이 다시 오면 그 family 전체를 폐기하고 401 `REFRESH_TOKEN_REUSED`.
  예외: 같은 `installationId`에서 30초 안에 오고, 그 토큰을 대신한 새 토큰이 아직 한 번도 안 쓰였으면
  (응답을 못 받은 재시도) 그 새 토큰을 폐기하고 다시 회전한다.
- 모르는·만료된·폐기된 토큰은 401 `REFRESH_TOKEN_INVALID`.
- 앱: Keychain `kSecClassGenericPassword`, service `com.dhouse.PilgrimJournal.group-session`, account
  `<기록장 Apple 사용자 해시>`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. 값은
  `{ accessToken, accessTokenExpiresAt, refreshToken, refreshTokenExpiresAt, userId }` JSON.
  `installationId`(UUID)는 같은 service의 account `installation-id`에 둔다.
- 앱의 토큰 갱신은 단일 실행이다. 동시에 401을 받은 요청들은 갱신 하나를 기다렸다가 한 번씩 다시 보낸다.
  `REFRESH_TOKEN_REUSED`/`REFRESH_TOKEN_INVALID`면 그룹 세션만 지우고 "그룹에 다시 로그인" 상태가 된다
  (기록장 세션은 건드리지 않는다).

**개발 로그인:** `POST /auth/dev { devUser, bundleId, installationId }`. `DEV_LOGIN_ENABLED=true`일 때만
라우트를 등록한다. `APP_ENV=production`과 함께 켜져 있으면 서버가 시작을 거부한다. `apple_sub`는
`dev:<devUser>`. 앱은 Debug 빌드에서 환경 변수 `PILGRIM_DEV_APPLE_USER`가 있으면 Apple 인증 대신 이것을 쓴다.

### 4. 기한 규칙 (`PilgrimAPI.PostExpiryPolicy`)

| 카드 | `expiresAt` |
| --- | --- |
| 기도제목, 데드라인 D 있음 | 올린 사람 시간대에서 D 다음 날 0시 + 3일 = `startOfDay(D, tz) + 4일` |
| 기도제목, 데드라인 없음 | `createdAt + visibleDays일`, `visibleDays ∈ {3, 7, 14, 30}`, 기본 7 |
| 독후감 | `createdAt + 7일`. 토론 연장마다 현재 `expiresAt + 7일` (누구나, 횟수·쿨다운 없음) |
| 간증 | `createdAt + 7일` |

- 데드라인은 올린 사람 시간대(`timeZone`, IANA 이름) 기준 오늘 이상, 오늘 + 365일 이하. 데드라인과
  `visibleDays`를 함께 보내면 422 `VALIDATION_FAILED`(`field: "visibleDays"`). 데드라인은 기도제목만 받는다.
- 시간대는 글에 저장한다(`posts.time_zone`). 기간 계산은 서버가 하고 응답의 `expiresAt`을 앱이 그대로 쓴다.
- 작성자는 언제든 먼저 내린다(`DELETE /posts/:id`, 실제 삭제).
- 모든 조회는 `expires_at > now()`로 거르고, worker가 60초마다 실제로 지운다(댓글·반응·연장 기록·사진 포함).
- 축소 모드: `TIME_SCALE_DAY_SECONDS`(기본 86400)를 "하루"로 쓴다. 정책 함수는 `dayLength`를 받는다.
  축소 모드의 데드라인 기한은 `createdAt + (오늘부터 D까지 달력 일수 + 4) × dayLength`.
- 함수 모양:
  ```swift
  public struct PostExpiryPolicy: Sendable {
      public init(dayLength: TimeInterval = 86_400)
      public func expiresAt(kind: PostKind, createdAt: Date, deadline: LocalDate?,
                            visibleDays: Int?, timeZone: TimeZone) throws -> Date   // PostExpiryError
      public func extended(_ expiresAt: Date) -> Date                                // + 7 × dayLength
      public func validateDeadline(_ d: LocalDate, now: Date, timeZone: TimeZone) throws
      public static let allowedVisibleDays: [Int] = [3, 7, 14, 30]
      public static let defaultVisibleDays = 7
  }
  ```

### 5. 관리자 위임 투표 (`PilgrimAPI.AdminVoteRules`)

- **시작:** 관리자가 나가거나(`leave`) 계정을 삭제하면 시작한다. `groups.admin_id = null`,
  `status = 'voting'`, `admin_votes`에 1라운드(3일) 행. 후보이자 투표권자는 **그 시점의 남은 멤버 전원**.
  - 남은 멤버가 0명이면 그룹을 바로 지운다.
  - 남은 멤버가 1명이면 투표 없이 그 사람이 관리자가 된다.
- **투표 중:** 관리자가 없다. 초대 만들기·취소, 초대 수락, 강퇴, 다른 사람 글·댓글 삭제, 그룹 이름 변경,
  그룹 삭제, 관리자 넘기기는 모두 409 `ADMIN_VOTE_IN_PROGRESS`. 글·댓글·반응·스티커·스크랩은 그대로 된다.
  투표는 마감 전까지 바꿀 수 있고 자기 자신에게도 투표할 수 있다. 득표 수는 마감 전에 보이지 않고
  투표 참여 수만 보인다.
- **마감(1라운드):** 투표가 하나도 없으면 → `status = 'pendingDeletion'`, `delete_at = now + 7일`,
  `deletion_reason = 'noVotes'`, 멤버 전원에게 알림. 최다 득표가 한 명이면 → 관리자. 동률이면 → 동률인
  사람만 후보로 2라운드(1일).
- **마감(2라운드):** 최다 득표가 한 명이면 관리자. 또 동률이거나 아무도 투표하지 않았으면 2라운드 후보 중
  무작위.
- 투표 중 나간 멤버는 후보와 투표권에서 빠지고 그 사람의 표는 버린다. 마감 때 후보가 모두 나갔으면 남은
  멤버로 1라운드를 다시 시작하고, 멤버가 없으면 그룹을 지운다.
- **유예 삭제:** `pendingDeletion` 동안 읽기와 스크랩만 된다. 새 글·댓글·반응·스티커·초대는 409
  `GROUP_PENDING_DELETION`. 나가기는 된다. `delete_at`이 지나면 worker가 그룹을 지운다(모든 하위 데이터와
  사진 파일).
- **직접 넘기기:** 관리자는 `POST /groups/:id/admin/transfer { userId }`로 멤버에게 넘긴다(투표 없음).
  그 뒤 나가면 일반 멤버로 나간다.
- 함수 모양:
  ```swift
  public enum AdminVoteRules {
      public enum Outcome: Equatable, Sendable {
          case elect(UUID, decidedBy: Decision)      // .majority | .random
          case runoff(candidates: [UUID])
          case scheduleDeletion
          case restart(candidates: [UUID])            // 후보가 모두 나감
          case deleteGroup                            // 멤버 없음
      }
      public static func close(round: Int, candidates: [UUID], ballots: [UUID: UUID],
                               remainingMembers: Set<UUID>,
                               using rng: inout some RandomNumberGenerator) -> Outcome
      public static func roundLength(_ round: Int, dayLength: TimeInterval) -> TimeInterval  // 3일 / 1일
      public static func deletionGrace(dayLength: TimeInterval) -> TimeInterval               // 7일
  }
  ```

### 6. 초대

- 링크 `https://pilgrim.delight-house.org/i/<code>`, QR도 같은 URL. 코드는 Crockford base32
  (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`) 12자, 60비트. 받을 때는 대소문자·`-`·공백을 무시하고 `I/L → 1`,
  `O → 0`으로 바꾼다(`PilgrimAPI.InviteCode`).
- 관리자만 만든다. `maxUses` 1~100(필수), 만료는 만든 때 + 3일(고정). 그룹당 살아 있는 초대 20개까지.
- 수락은 한 트랜잭션: 이미 멤버면 아무것도 세지 않고 그룹을 돌려준다(200). 아니면 강퇴 기록 확인
  (`group_bans` → 403 `REMOVED_FROM_GROUP`) → 그룹 상태 확인(`voting` → 409 `ADMIN_VOTE_IN_PROGRESS`,
  `pendingDeletion` → 409 `GROUP_PENDING_DELETION`) → 조건부 UPDATE:
  ```sql
  UPDATE invites SET use_count = use_count + 1
   WHERE code = $1 AND revoked_at IS NULL AND expires_at > now() AND use_count < max_uses
   RETURNING id, group_id;
  ```
  0행이면 이유를 다시 읽어 410 `INVITE_EXPIRED` / 410 `INVITE_REVOKED` / 409 `INVITE_FULL` /
  404 `NOT_FOUND`. 그다음 `memberships` INSERT. 동시에 눌러도 `max_uses`를 넘지 않는다.
- AASA(`/.well-known/apple-app-site-association`, `application/json`, 리디렉트 없음):
  ```json
  { "applinks": { "details": [ {
      "appIDs": ["<TEAM_ID>.com.dhouse.PilgrimJournal", "<TEAM_ID>.com.dhouse.PilgrimJournal.debug"],
      "components": [ { "/": "/i/*", "comment": "group invites" } ] } ] } }
  ```
- `/i/:code`: 정적 HTML(한국어·영어). 그룹 이름·인원·초대한 사람 등 **그룹 정보를 싣지 않는다.**
  "Pilgrim 앱에서 열기", App Store 링크, 직접 입력용 초대 코드. 코드가 틀려도 같은 페이지(유효 여부를
  드러내지 않음). `X-Robots-Tag: noindex`, `Cache-Control: no-store`.
- 앱: Universal Link와 QR 스캔을 `PendingGroupInvite` 큐(`PendingShareInvitations`를 본뜸)로 받는다.
  로그인·가입이 끝나지 않았으면 끝난 뒤 이어서 연다. macOS와 테스트용으로 "초대 코드로 참여" 직접 입력을 둔다.
- 강퇴는 차단을 겸한다: 강퇴된 사람은 관리자가 `DELETE /groups/:id/bans/:userId`로 풀기 전까지 어떤 초대로도
  다시 들어오지 못한다. 강퇴된 사람이 올린 글·댓글은 남는다(로드맵).

### 7. 사진과 미디어

- 앱(`ImageCompressor`, ImageIO): 긴 변 1600px 이하로 줄임(작으면 그대로), JPEG 품질 0.7에서 시작해 500KB를
  넘으면 0.1씩 낮춰 0.3까지, 그래도 넘으면 긴 변을 0.8배로 줄여 반복. EXIF·GPS·TIFF·IPTC·XMP를 쓰지 않고
  방향은 픽셀에 반영한다. 글·댓글당 최대 4장. 프로필 사진도 같은 기준. 스티커는 정사각형으로 자른 뒤
  256×256, 100KB 이하.
- 업로드: `POST /uploads`(multipart `purpose`, `clientId`, `file`) → `MediaRef`. 올린 미디어는
  "붙지 않은" 상태이고, 글·댓글·스티커·프로필에 붙을 때 `attached_at`이 정해진다. 24시간 동안 붙지 않으면
  worker가 지운다. 미디어는 올린 사람만 붙일 수 있고 한 곳에만 붙는다(409 `MEDIA_NOT_ATTACHABLE`).
- 서버 검사(`PhotoLimits`): `Content-Type`과 실제 시그니처가 JPEG(`FF D8 FF`), SOF에서 읽은 크기가
  목적별 한도 안(post·comment·profile: 긴 변 ≤ 1600, ≤ 500KB / sticker: 정확히 256×256, ≤ 100KB),
  디코딩 없이 JPEG 세그먼트를 다시 써서 APP1~APP15·COM 세그먼트를 지운다(APP0 JFIF와 ICC 색 프로필
  APP2는 남긴다). 틀리면 422 `MEDIA_INVALID`, 크기 초과는 413 `MEDIA_TOO_LARGE`.
- 저장: `MEDIA_ROOT`(Docker 볼륨 `media`) 아래 `<id 앞 2자>/<id>.jpg`. DB에는 상대 경로·크기·폭·높이·
  SHA-256.
- 내려받기: 응답의 모든 `MediaRef`에 서명 URL이 들어 있다.
  `https://pilgrim.delight-house.org/api/media-files/<id>?exp=<unix>&sig=<base64url HMAC-SHA256(MEDIA_URL_SECRET, "<id>.<exp>")>`,
  10분 유효. 만료된 URL은 403. `GET /api/v1/media/:id`가 새 URL을 준다(멤버 확인). 파일 응답은
  `Cache-Control: private, max-age=600`. 앱은 미디어 `id`로 캐시한다(파일은 바뀌지 않는다).
- **파일 삭제:** `media` 행이 어떤 이유로든(글 만료, 직접 삭제, 계정 삭제, 그룹 삭제의 cascade) 지워지면
  Postgres 트리거가 `media_file_deletions`에 경로를 넣고 worker가 파일을 지운다. DB cascade와 파일 정리가
  어긋나지 않게 하기 위해서다.

### 8. 그룹 스티커

- 멤버가 사진을 정사각형으로 잘라 만든다(`purpose = sticker` 업로드 → `POST /groups/:id/stickers`).
  이름은 선택(20자). 그룹당 최대 30개(409 `STICKER_LIMIT_REACHED`).
- 그 그룹 안에서만 반응과 댓글에 쓴다. 다른 그룹의 스티커 ID로 반응하면 404.
- 만든 사람과 관리자가 지운다(투표 중에는 만든 사람만). 지우면 그 스티커로 한 반응은 함께 지워지고, 그
  스티커를 쓴 댓글은 남되 `sticker`가 비어 "지워진 스티커"로 보인다. 그룹이 지워지면 스티커도 지워진다.
  만든 사람이 계정을 삭제하면 그 사람의 스티커도 지운다. 만든 사람이 그룹을 나가기만 하면 남는다.

### 9. 차단·숨김·신고와 보이는 범위 (`ContentVisibility`)

- **숨김:** 글 단위(`hides.post_id`)와 사람 단위(`hides.target_user_id`, **모든 그룹에 적용**). 내 화면에서만
  적용된다. 서버에 저장해 내 기기끼리 맞춘다. 숨긴 글과 숨긴 사람의 글·댓글·반응은 피드, 상세, 안 읽은 수,
  새 글 푸시, Daily Report에서 빠진다. 설정의 "숨긴 항목"에서 되돌린다.
- **차단:** 양방향. A가 B를 차단하면 A와 B 둘 다 서로의 글·댓글·반응을 보지 못하고(반응 수에서도 빠짐) 서로에게
  푸시가 가지 않는다. 같은 그룹 멤버로는 남는다. 상대에게 차단 사실을 알리지 않는다. 차단한 쪽만 풀 수 있다.
- **신고:** 대상 글·댓글·스티커·사용자. 서버가 신고 시점의 스냅샷(`snapshot` jsonb: 작성자 ID·이름, 제목,
  본문, 항목, 책 정보, 미디어 ID 목록)을 저장한다. 사진 파일은 따로 복사하지 않는다(원본이 남아 있는 동안
  콘솔에서 볼 수 있다). 신고 행은 90일 뒤 지운다. 신고한 뒤 앱은 "이 글 숨기기"·"이 사람 차단"을 바로 권한다.
- 보이는 글의 조건(모든 조회가 같은 SQL 조각을 쓴다):
  ```
  posts.expires_at > now()
  AND 요청자가 posts.group_id의 멤버
  AND NOT EXISTS hides(user=요청자, post=posts.id)
  AND NOT EXISTS hides(user=요청자, target_user=posts.author_id)
  AND NOT EXISTS blocks((요청자 → 작성자) OR (작성자 → 요청자))
  ```
  댓글·반응도 같은 차단·사람 숨김 조건으로 거른다. 그룹 상태 `active`·`voting`·`pendingDeletion` 모두 읽기 가능.

### 10. 알림

- 권한은 처음 그룹을 만들거나 들어갈 때 묻는다(`UNUserNotificationCenter`, alert·sound·badge).
  허용하면 `registerForRemoteNotifications` → `PUT /me/devices/:installationId`.
- **새 글:** 글 저장 트랜잭션에서 받는 사람마다 `push_outbox` 한 행을 넣는다. 받는 사람에서 빼는 사람:
  작성자, 그 그룹 새 글 알림을 끈 멤버, 작성자와 차단 관계인 사람, 작성자를 사람 단위로 숨긴 사람.
  worker가 5초마다 보낸다. 투표 시작·재투표·결과·삭제 예정 알림도 같은 outbox를 쓴다.
- **잠금화면에 기도 내용을 싣지 않는다.** 그룹 이름과 작성자 이름만 `loc-args`로 보내고 문구는 앱의 String
  Catalog에서 만든다. 푸시 키는 Korean-key 규칙의 예외로 ASCII 상수(`PilgrimAPI.PushLocKey`)이고, Phase 2
  현지화 작업이 `ko`·`en` 값을 채운다.

  | `kind` | `title-loc-key` / `loc-key` | `loc-args` |
  | --- | --- | --- |
  | `newPost` | `GROUP_PUSH_TITLE` / `GROUP_NEW_POST_PRAYER`, `GROUP_NEW_POST_BOOK_REPORT`, `GROUP_NEW_POST_TESTIMONY` | [그룹 이름] / [작성자 이름] |
  | `dailyReport` | `DAILY_REPORT_TITLE` / `DAILY_REPORT_BODY` | [] / [소식 개수] |
  | `voteStarted` | `GROUP_PUSH_TITLE` / `ADMIN_VOTE_STARTED` | [그룹 이름] / [] |
  | `voteRunoff` | `GROUP_PUSH_TITLE` / `ADMIN_VOTE_RUNOFF` | [그룹 이름] / [] |
  | `voteDecided` | `GROUP_PUSH_TITLE` / `ADMIN_VOTE_DECIDED` | [그룹 이름] / [새 관리자 이름] |
  | `groupDeletionScheduled` | `GROUP_PUSH_TITLE` / `GROUP_DELETION_SCHEDULED` | [그룹 이름] / [] |

  페이로드:
  ```json
  { "aps": { "alert": { "title-loc-key": "GROUP_PUSH_TITLE", "title-loc-args": ["수요 기도모임"],
                        "loc-key": "GROUP_NEW_POST_PRAYER", "loc-args": ["민지"] },
             "sound": "default", "thread-id": "group-<groupId>" },
    "pilgrim": { "v": 1, "kind": "newPost", "groupId": "<uuid>", "postId": "<uuid>" } }
  ```
  `PushPayload`(Codable)로 정의한다. `apns-topic`은 기기 행의 `bundle_id`, `apns-push-type: alert`,
  환경은 기기 행의 `apns_environment`(Debug·TestFlight 구분).
- APNs 응답 410 또는 `BadDeviceToken`/`Unregistered`/`DeviceTokenNotForTopic`이면 그 기기 토큰을 지운다.
  5xx·네트워크 오류는 30초·2분·10분 뒤 다시 보내고 그 뒤 실패로 남긴다.
- 알림을 누르면 앱이 `pilgrim.kind`에 따라 그 글 상세, Daily Report 화면, 그룹 화면을 연다. 이미 사라진 글이면
  "이 글은 더 이상 볼 수 없어요"를 보인다.
- 앱 아이콘 배지는 쓰지 않는다(0으로 둔다). 안 읽은 수는 사이드바에 보인다.

### 11. Daily Report

- 사용자 시간대(`users.time_zone`) 기준 `daily_report_minute`(기본 1320 = 22:00)에 한 번. 범위는 **그 시각까지
  24시간**(`windowEnd = 오늘 리포트 시각`, `windowStart = windowEnd - 24시간`).
- 내용(그룹별, 숨김·차단 필터 적용, 그 그룹 Daily Report를 끈 멤버는 그 그룹 제외):
  - `newPosts`: 범위 안에 올라온 남의 글
  - `commentsOnMyPosts`: 내 글에 달린 남의 댓글(글별 개수)
  - `reactionsOnMyPosts`: 내 글에 남이 단 반응(글별 개수)
  - `extendedPosts`: 범위 안에 토론이 연장된 글 중 내가 쓰거나 댓글 단 글
  - `expiringSoon`: 지금부터 24시간 안에 사라지는 글 중 내가 숨기지 않은 글
- 합계(`totalCount`)가 0이면 보내지 않는다(`daily_report_log.status = 'skipped'`).
- `daily_report_log UNIQUE(user_id, report_date)`로 하루 한 번만 보낸다. 시각을 바꾸면 그날 아직 안 보냈을 때만
  새 시각에 보낸다. `users.daily_report_enabled = false`면 보내지 않는다.
- `GET /me/daily-report?date=YYYY-MM-DD`가 같은 내용을 앱 화면용으로 준다. `date`를 빼면 가장 최근에 끝난 범위
  (오늘 리포트 시각이 지났으면 오늘, 아니면 어제). 보내지 않은 날도 계산해 준다.
- 서머타임 등으로 그 시각이 없는 날은 그 다음 존재하는 시각에 보낸다.

### 12. 구독

- 상품 `com.dhouse.PilgrimJournal.groups.monthly`(자동 갱신, 월간, $1.99 / ₩2,000 가격 단계). 구독 그룹 하나.
- 구매 때 `appAccountToken = 서버 사용자 ID`(`GET /me`의 `id`)를 넣는다.
- 앱이 `Transaction.jwsRepresentation`을 `POST /subscriptions/verify { signedTransaction, bundleId }`로
  보낸다. 서버는 `app-store-server-library-swift`의 `SignedDataVerifier`(Apple 루트 인증서, 두 bundleId,
  Production·Sandbox)로 검증하고 `original_transaction_id`로 upsert한다. `appAccountToken`이 다른 사용자거나
  그 거래가 이미 다른 사용자에 묶여 있으면 409 `SUBSCRIPTION_OWNED_BY_OTHER_USER`. 검증 실패는 422
  `SUBSCRIPTION_INVALID`. 앱은 실행 때와 `Transaction.updates`마다 보낸다.
- App Store Server Notifications V2: `POST /api/appstore/notifications { signedPayload }`. `notificationUUID`로
  중복을 거르고(`appstore_notifications`), `SUBSCRIBED`·`DID_RENEW`·`DID_CHANGE_RENEWAL_STATUS`·
  `DID_FAIL_TO_RENEW`(`GRACE_PERIOD` 하위 유형이면 `gracePeriod`, 아니면 `billingRetry`)·
  `GRACE_PERIOD_EXPIRED`·`EXPIRED`·`REFUND`·`REVOKE`를 반영한다. `TEST`는 기록만. 검증 실패면 400, 처리했으면 200.
- 권한(`EntitlementPolicy`): `status ∈ {active, gracePeriod}`이고 `expires_at > now`면 구독 중.
- 서버 설정 **`SUBSCRIPTION_REQUIRED`(출시 때 `false`)**:
  - `false`: 모두 구독 중으로 본다. `GET /me/entitlement`의 `subscriptionRequired = false`. 앱은 구독 화면을
    건너뛴다. 만료 처리는 아무것도 하지 않는다.
  - `true`: 그룹 API(`groups/**`, `posts/**`, `comments/**`, `stickers/**`, `invites` 만들기·수락, 사진
    업로드 중 `profile` 외)가 구독 중이 아닌 사용자에게 402 `SUBSCRIPTION_REQUIRED`. `GET /invites/:code`는
    되고 `requiresSubscription = true`를 돌려준다(앱이 구독 화면을 보인다). 인증, `/me`, 기기, 차단·숨김 목록,
    구독 검증, 계정 삭제는 언제나 된다.
  - 만료 처리(`true`일 때만): 구독 행의 상태가 `expired`·`revoked`가 되고 `removal_processed_at`이 비어 있으면
    worker가 그 사람을 모든 그룹에서 빼고(관리자면 투표 시작) 그 사람이 올린 글·댓글·반응·스티커·사진을 지운다.
    스크랩은 각자의 기록장에 있으므로 남는다. 다시 구독하면 초대로 다시 들어온다.
  - 웹훅을 놓쳤을 때를 대비해 worker가 1시간마다 `expires_at`이 지났는데 24시간 넘게 갱신되지 않은 구독을
    App Store Server API(`getAllSubscriptionStatuses`)로 다시 확인한다(In-App Purchase 키 필요).

### 13. 계정 삭제

- 앱 `AccountDeletionService`에 `RemoteAccountDataErasing` 단계를 **모든 범위에서 가장 먼저** 둔다. 그룹 세션이
  없으면 건너뛴다. 실패하면 로컬·iCloud 삭제 전에 멈추고 다시 시도하게 한다.
- `DELETE /me` 한 트랜잭션:
  1. 내가 관리자인 그룹마다 투표 시작(5절의 규칙: 남은 멤버 0명이면 그룹 삭제, 1명이면 바로 관리자).
  2. `apple_tokens`를 `apple_token_revocations`로 옮긴다(worker가 Apple `/auth/revoke`를 재시도).
  3. `users` 행 삭제 → cascade로 멤버십, 글(→ 댓글·반응·연장·사진), 댓글, 반응, 스티커, 미디어(→ 파일 삭제
     큐), 기기, refresh token, 구독 행, 숨김, 차단, 투표, outbox, 리포트 기록이 지워진다. 남이 한 신고의
     `reporter_id`·`target_user_id`는 null이 되고 스냅샷은 90일 보관 뒤 지워진다.
- 응답 200 `AccountDeletionResponse { deletedAt, groupsHandedToVote: [UUID], groupsDeleted: [UUID] }`.
- 멱등: 서명이 맞는 access token인데 사용자가 이미 없으면 200 `{ alreadyDeleted: true }`. refresh가
  `REFRESH_TOKEN_INVALID`라 access를 얻지 못하면 앱은 Apple 재인증 → `auth/apple`(빈 사용자가 새로 생김) →
  `DELETE /me`로 끝낸다.
- 확인 화면에 "내가 관리하는 그룹 N개는 멤버 투표로 다음 관리자를 정해요"와 "구독은 App Store 설정에서 직접
  해지해야 해요"(구독 중일 때)를 보인다. 서버 삭제가 끝나면 앱이 그룹 Keychain 항목을 지운다.

### 14. 운영자 도구

- 서버 `/internal/admin/v1/*`: 터널로 노출하지 않는다. `X-Admin-Token`(`ADMIN_API_TOKEN`, 32바이트 이상,
  상수 시간 비교)이 없거나 틀리면 401. `Cf-Ray` 또는 `Cf-Connecting-IP` 헤더가 있으면 403(터널을 거친
  요청). `X-Pilgrim-Client` 검사 없음. 조치마다 `X-Admin-Actor`(콘솔 관리자 이름)를 받아 `moderation_log`에
  남긴다.
- 콘솔 `web/admin`에 "신고" 페이지(W1): 열린 신고 목록·상세(스냅샷, 원본이 남아 있으면 원본과 사진), 글·
  댓글·스티커 삭제, 사용자 정지·해제, 처리 완료(기각·조치). 콘솔은 공유 Docker 네트워크로
  `http://pilgrim-api:3100`을 부른다.
- 새 신고는 `REPORT_WEBHOOK_URL`(선택)에 `{ "text": "새 신고 <reason> (<targetType>)" }`만 보낸다. 본문은 싣지 않는다.
- 정지된 사용자는 `GET /me`, `DELETE /me`, `auth/*`, 기기 삭제 외 모든 요청에서 403 `ACCOUNT_SUSPENDED`.
  `suspended_until`이 지나면 풀린다. 정지는 그 사람의 글을 지우지 않는다(운영자가 따로 지운다).

### 15. 스크랩과 CloudKit 스키마 (T0.1 확인 결과)

**결론: canonical 모델·속성 변경이 필요 없다. CloudKit 스키마 배포도 필요 없다.**

확인한 것:

- `PilgrimJournalSchemaV1.canonicalModels`(`Sources/JournalData/JournalSchema.swift`)는
  `JournalEntryEntity`, `EntryRevisionEntity`, `AttachmentEntity`, `ClassificationRuleEntity`,
  `RestoreEpochEntity`다. 스크랩은 이 중 앞의 셋만, 이미 Production에서 값이 채워진 필드로 쓴다.
- 유형은 기록에 `JournalEntryEntity.kindRaw: String`으로 저장된다. `JournalKind`는 1.1.0부터 열린 문자열
  ID라(`custom-<UUID>` 사용자 유형이 이미 이 필드로 동기화된다) 새 ID `"scrap"`은 같은 필드의 새 값일 뿐이다.
- 유형 이름·색·아이콘(`KindCatalog`)은 SwiftData가 아니라 `KindCatalogStore`가 UserDefaults와
  `NSUbiquitousKeyValueStore`(키 `journal-kind-catalog`)에 둔다. CloudKit 스키마와 무관하다.
- 노트북은 별도 모델이 아니라 `tags` 안의 인코딩된 태그(`NotebookTagCodec`, `__pilgrim_notebook__:<base64>`,
  `JournalEntryEntity.tagsData`)다. 노트북 목록·삭제한 노트북 목록은 키-값 저장소(`journal-notebooks`,
  `journal-deleted-notebooks`)다.
- 사진은 `AttachmentEntity`(`binary`는 external storage), 본문에서는 `![](attachment:<uuid>)` 줄로 참조한다.
- 유형별 상세(`EntryDetails`)는 `detailsData` JSON 블롭이다. 스크랩은 여기에 새 키를 넣지 않는다 — 옛 버전이
  기록을 고쳐 저장하면 모르는 키가 사라지기 때문이다.

택한 방식:

1. **유형:** `BuiltInKind`에 `case scrap`(raw `"scrap"`, 이름 "스크랩", 영어 표시 "Scraps")을 **맨 뒤**
   (`unclassified` 다음)에 더한다. `KindCatalog.defaultDefinition`이 `allCases` 순서로 색·아이콘·순서를 정하므로
   중간에 넣으면 미분류의 기본 색·아이콘이 바뀐다. 색은 `KindColorToken.allCases[6] = .teal`, 아이콘은
   `KindIconCatalog.builtInSymbols`에 7번째로 `"bookmark"`를 더한다.
   - `canCreateManually = false`: 새 기록·분류 규칙·일괄 정리의 대상 목록에 나오지 않는다. 스크랩 기록을 다른
     유형으로 옮기는 것은 된다.
   - `canBeDeleted = true`(메모와 같음). 지우면 기존 규칙대로 기록을 옮긴다. 다시 스크랩하면 `restore`로 되살린다.
   - **처음 스크랩할 때 나타난다:** 카탈로그에 저장된 정의가 없으면 `allDefinitions`·`activeKinds`·
     `creatableKinds`·`deletedBuiltIns`에 넣지 않는다. 첫 스크랩이 정의를 저장한다(`materialize`, 시각·기기
     기록). 그룹을 쓰지 않는 사용자의 사이드바는 바뀌지 않는다.
   - 저장할 때 활성 유형 중 "스크랩"과 같은 이름(대소문자·발음 구별 무시)이 이미 있으면 이름을 "그룹 스크랩"으로
     저장한다.
   - `EntryDetails.validated(for:)`는 `.scrap`을 `.memo`처럼 처리한다(상세 없음). `KindDisplayName`에 표시 이름을
     더한다.
2. **노트북:** `"스크랩 · <그룹 이름>"`(가운뎃점 U+00B7, 앞뒤 공백 하나). 그룹 이름은 스크랩하는 순간의 이름을
   쓴다. 나중에 그룹 이름이 바뀌면 그 뒤 스크랩은 새 이름 노트북으로 가고 예전 스크랩은 그대로 둔다. 이름이 같은
   두 그룹은 노트북을 함께 쓴다(그룹 ID는 본문 머리에 있다). 노트북은 반드시 `AppModel`의 노트북 만들기 경로로
   만든다 — `refreshNotebookCatalog(from:)`는 삭제한 노트북 목록에 있는 이름을 다시 보이지 않으므로, 예전에 지운
   이름이면 삭제 목록에서 빼야 한다.
3. **본문:** 머리 부분에 출처를 넣는다. 머리 문구는 스크랩하는 순간의 앱 언어로 쓰고(저장된 사용자 데이터라
   이후 번역하지 않는다), 마지막 표식 줄은 언어와 무관한 고정 형식이다.
   ```markdown
   > 스크랩 · 수요 기도모임
   > 민지 · 기도제목 · 2026년 11월 14일에 올림 · 데드라인 2026년 11월 20일
   > pilgrim-scrap: group=<groupId 소문자 UUID> post=<postId 소문자 UUID>

   - 어머니 검사 결과가 좋게 나오도록 기도해 주세요 (엄마/건강)
   - 이번 주 면접을 차분히 볼 수 있도록 기도해 주세요

   ![](attachment:<첨부 UUID>)

   ---

   **댓글**

   > 준호 · 11월 14일: 함께 기도할게요 🙏
   > 수아 · 11월 15일: (스티커)
   ```
   - 제목(`title`): 글 제목, 없으면 독후감은 책 제목, 기도제목은 "<작성자>의 기도제목", 간증은 "<작성자>의 간증".
   - 독후감은 머리 다음 줄에 `**<책 제목>** · <저자>`.
   - `occurredAt`: 글을 올린 시각(`createdAt`), `originalTimeZone`: 글의 시간대.
   - 사진은 첨부로 저장하고 본문에 이미지 줄로 넣는다(글 사진만. 댓글 사진은 댓글 인용 아래에 이미지 줄로,
     스티커는 "(스티커)" 글자로).
   - 숨긴·차단한 사람의 댓글은 넣지 않는다. 댓글이 없으면 댓글 부분을 넣지 않는다.
   - `sourceUUID`·`sourceMetadata`는 쓰지 않는다. `sourceUUID`는 Day One 중복 판정 키라
     (`StableIdentifier.fromDayOne`, `JournalError.duplicateSource`) 다른 용도로 섞지 않는다.
   - 이미 스크랩한 글: 스크랩 유형 기록 중 본문에 같은 `post=<id>` 표식이 있으면 "이미 스크랩했어요. 한 번 더
     저장할까요?"를 묻는다(막지는 않는다).
4. **저장 범위:** 언제나 내 기록장(현재 저장 범위의 canonical store)에 저장한다. 가족 공유 공간을 보고 있어도
   공유 공간에 넣지 않는다. 스크랩 노트북을 나중에 가족과 공유하려 하면 기존 규칙대로 사진이 든 기록은 공유할 수
   없다.
5. **서버:** 스크랩은 서버에 아무것도 보내지 않는다(조회만). 원본이 사라져도 스크랩은 남는다.

옛 버전과의 호환:

- 1.1.0~1.2.x: `"scrap"`을 모르는 ID로 본다. 첫 스크랩이 카탈로그에 정의를 저장하므로 옛 버전도 키-값 저장소로
  그 정의를 받아 "스크랩"이라는 이름의 사용자 유형처럼 보인다(색 teal, 아이콘은 옛 버전 목록에 `bookmark`가 없어
  `tag`). 옛 버전에서 이름을 바꾸거나 지울 수 있고, 그 결과는 카탈로그 병합 규칙대로 새 버전에도 반영된다.
  옛 버전의 `KindReconciler`는 모르는 ID의 기록을 옮기지 않는다. 기록 저장도 된다(열린 ID).
- 1.0.1: 사용자 유형과 같은 기존 한계 — 스크랩 기록을 고쳐 저장하지 못한다(`docs/pre-release-checklist.md`의
  1.1.0 항목과 같은 안내).
- 백업(`JournalBackup`)은 유형을 문자열로 담으므로 형식이 바뀌지 않는다.

그래도 스키마를 바꾸게 되면(예: 출처를 구조화된 필드로 두기로 바뀌면): `canonicalModels`에 optional 속성을 더한 뒤
`docs/known-issues.md` "CloudKit 스키마 드리프트" 절차대로 Debug 빌드를 `PILGRIM_DEPLOY_CLOUDKIT_SCHEMA=1`로 실행해
Development에 만들고, CloudKit Console에서 Production으로 배포하고, 릴리스 전 Deploy 창이 변경 0건인지 확인한다.
이 변경에서는 하지 않는다.

## API (`/api/v1`)

표기: `요청 → 응답`. 필드 뒤 `?`는 optional. 공통 타입은 아래 "공통 DTO". 응답 코드는 따로 적지 않으면 200
(만들면 201, 본문 없으면 204).

### 공통 DTO

```swift
enum PostKind: String { case prayer, bookReport, testimony }
enum GroupStatus: String { case active, voting, pendingDeletion }
enum MediaPurpose: String { case post, comment, profile, sticker }
enum ReportTargetType: String { case post, comment, sticker, user }
enum ReportReason: String { case spam, harassment, inappropriate, selfHarm, other }
enum SubscriptionStatus: String { case active, gracePeriod, billingRetry, expired, revoked, none }

struct MediaRef { id: UUID; width: Int; height: Int; byteCount: Int; url: URL; urlExpiresAt: Date }
struct UserSummary { id: UUID; displayName: String; profilePhoto: MediaRef? }
struct Page<T> { items: [T]; nextCursor: String? }
struct PrayerItem { text: String; topic: String?; who: String? }      // topic: PrayerRequestTopic raw 값
struct BookInfo { title: String; author: String? }
enum ReactionKey { case emoji(String), sticker(UUID) }
  // JSON {"type":"emoji","emoji":"🙏"} | {"type":"sticker","stickerId":"<uuid>"}
struct ReactionSummary { key: ReactionKey; count: Int; reactedByMe: Bool }
```

### 인증

| 메서드·경로 | 인증 | 요청 → 응답 |
| --- | --- | --- |
| `POST /auth/apple` | 없음 | `AppleSignInRequest { identityToken, authorizationCode, rawNonce, bundleId, installationId: UUID }` → `AuthSessionResponse` |
| `POST /auth/refresh` | 없음 | `RefreshRequest { refreshToken, installationId }` → `AuthSessionResponse` |
| `POST /auth/logout` | 필요 | `LogoutRequest { refreshToken, installationId }` → 204 (family 폐기, 그 기기 행 삭제) |
| `POST /auth/dev` | 없음, 개발만 | `DevSignInRequest { devUser, bundleId, installationId }` → `AuthSessionResponse` |

`AuthSessionResponse { accessToken, accessTokenExpiresAt: Date, refreshToken, refreshTokenExpiresAt: Date, user: MeResponse }`

### 내 정보·기기·리포트·차단·숨김

| 메서드·경로 | 요청 → 응답 |
| --- | --- |
| `GET /me` | → `MeResponse` |
| `PATCH /me` | `UpdateMeRequest { displayName?, profilePhotoId?: UUID, removeProfilePhoto?: Bool, timeZone?, dailyReportEnabled?: Bool, dailyReportTime?: LocalTime }` → `MeResponse` |
| `DELETE /me` | → `AccountDeletionResponse { deletedAt: Date?, alreadyDeleted: Bool, groupsHandedToVote: [UUID], groupsDeleted: [UUID] }` |
| `PUT /me/devices/:installationId` | `DeviceRegistrationRequest { apnsToken: String? (hex), apnsEnvironment: "sandbox"\|"production", bundleId, platform: "ios"\|"macos", locale, timeZone, appVersion }` → 204 |
| `DELETE /me/devices/:installationId` | → 204 |
| `GET /me/daily-report?date=` | → `DailyReportResponse` |
| `GET /me/entitlement` | → `EntitlementResponse` |
| `GET /me/blocks` | → `[UserSummary]` |
| `PUT /me/blocks/:userId` / `DELETE` | → 204 |
| `GET /me/hides` | → `HidesResponse { posts: [HiddenPost { postId, groupId, groupName, title?, hiddenAt }], users: [HiddenUser { user: UserSummary, hiddenAt }] }` |
| `PUT /me/hides/posts/:postId` / `DELETE` | → 204 |
| `PUT /me/hides/users/:userId` / `DELETE` | → 204 |

```swift
struct MeResponse { id: UUID; displayName: String?; profilePhoto: MediaRef?; profileComplete: Bool
                    timeZone: String; dailyReportEnabled: Bool; dailyReportTime: LocalTime
                    suspendedUntil: Date?; createdAt: Date; entitlement: EntitlementResponse }
struct EntitlementResponse { subscriptionRequired: Bool; active: Bool; status: SubscriptionStatus
                             productId: String?; expiresAt: Date? }
struct DailyReportResponse { date: LocalDate; windowStart: Date; windowEnd: Date; totalCount: Int
                             groups: [DailyReportGroup] }
struct DailyReportGroup { groupId: UUID; groupName: String; newPosts: [DailyReportPost]
                          commentsOnMyPosts: [DailyReportPost]; reactionsOnMyPosts: [DailyReportPost]
                          extendedPosts: [DailyReportPost]; expiringSoon: [DailyReportPost] }
struct DailyReportPost { postId: UUID; kind: PostKind; title: String; author: UserSummary
                         count: Int; expiresAt: Date }   // title: 제목 → 책 제목 → 첫 항목 40자
```

### 구독

| 메서드·경로 | 요청 → 응답 |
| --- | --- |
| `POST /subscriptions/verify` | `VerifySubscriptionRequest { signedTransaction, bundleId }` → `EntitlementResponse` |
| `POST /api/appstore/notifications` (v1 밖, 인증·클라이언트 헤더 없음) | `{ signedPayload }` → 200 |

### 사진

| 메서드·경로 | 요청 → 응답 |
| --- | --- |
| `POST /uploads` | multipart: `purpose`, `clientId`, `groupId`(profile 외 필수, 멤버 확인), `file`(`image/jpeg`) → 201 `UploadResponse { media: MediaRef }` |
| `GET /media/:id` | → `MediaURLResponse { url, expiresAt }` |
| `GET /api/media-files/:id?exp&sig` (v1 밖, 서명으로 인증) | → `image/jpeg` |

### 그룹·멤버·투표

| 메서드·경로 | 권한 | 요청 → 응답 |
| --- | --- | --- |
| `GET /groups` | 나 | → `[GroupSummary]` |
| `POST /groups` | 누구나 | `CreateGroupRequest { clientId, name }` → 201 `GroupDetail` |
| `GET /groups/:id` | 멤버 | → `GroupDetail` |
| `PATCH /groups/:id` | 관리자 | `UpdateGroupRequest { name }` → `GroupDetail` |
| `DELETE /groups/:id` | 관리자 | → 204 (`pendingDeletion`, 7일 유예, `adminDeleted`) |
| `POST /groups/:id/leave` | 멤버 | → 204 |
| `GET /groups/:id/members?cursor&limit` | 멤버 | → `Page<MemberResponse>` |
| `DELETE /groups/:id/members/:userId` | 관리자 | → 204 (강퇴 = 강퇴 기록) |
| `GET /groups/:id/bans` | 관리자 | → `[BanResponse { user: UserSummary, bannedAt }]` |
| `DELETE /groups/:id/bans/:userId` | 관리자 | → 204 |
| `POST /groups/:id/admin/transfer` | 관리자 | `TransferAdminRequest { userId }` → `GroupDetail` |
| `POST /groups/:id/seen` | 멤버 | `{}` → 204 (`last_seen_at = now`) |
| `PUT /groups/:id/notifications` | 멤버 | `GroupNotificationSettings { newPostPushEnabled, dailyReportEnabled }` → 204 |
| `GET /groups/:id/vote` | 멤버 | → `VoteResponse` (열린 투표 없으면 404) |
| `POST /groups/:id/vote/ballot` | 후보 목록 안의 멤버 | `CastBallotRequest { candidateUserId }` → `VoteResponse` |

```swift
struct GroupSummary { id: UUID; name: String; status: GroupStatus; memberCount: Int; isAdmin: Bool
                      admin: UserSummary?; unreadCount: Int; latestPostAt: Date?
                      notifications: GroupNotificationSettings; voteEndsAt: Date?; deleteAt: Date? }
struct GroupDetail { summary fields 전부 + createdAt: Date; createdBy: UserSummary?
                     deletionReason: String?  /* "noVotes" | "adminDeleted" */
                     stickerCount: Int; activeInviteCount: Int? /* 관리자에게만 */ }
struct MemberResponse { user: UserSummary; isAdmin: Bool; joinedAt: Date }
struct VoteResponse { round: Int; startedAt: Date; endsAt: Date; candidates: [UserSummary]
                      myBallot: UUID?; ballotCount: Int; eligibleCount: Int }
```

### 초대

| 메서드·경로 | 권한 | 요청 → 응답 |
| --- | --- | --- |
| `POST /groups/:id/invites` | 관리자 | `CreateInviteRequest { clientId, maxUses }` → 201 `InviteResponse` |
| `GET /groups/:id/invites` | 관리자 | → `[InviteResponse]` (만료·취소 안 된 것) |
| `DELETE /groups/:id/invites/:code` | 관리자 | → 204 |
| `GET /invites/:code` | 로그인 | → `InvitePreviewResponse` |
| `POST /invites/:code/accept` | 로그인·가입 완료 | `{}` → `GroupDetail` |

```swift
struct InviteResponse { code: String; url: URL; maxUses: Int; useCount: Int; expiresAt: Date
                        createdAt: Date; createdBy: UserSummary? }
struct InvitePreviewResponse { code: String; groupId: UUID; groupName: String; memberCount: Int
                               invitedBy: UserSummary?; expiresAt: Date; alreadyMember: Bool
                               requiresSubscription: Bool }
```

### 글·댓글·반응

| 메서드·경로 | 권한 | 요청 → 응답 |
| --- | --- | --- |
| `GET /groups/:id/posts?cursor&limit` | 멤버 | → `Page<PostResponse>` (새 글 먼저) |
| `POST /groups/:id/posts` | 멤버 | `CreatePostRequest` → 201 `PostResponse` |
| `GET /posts/:id` | 멤버 | → `PostResponse` |
| `DELETE /posts/:id` | 작성자, 관리자 | → 204 |
| `POST /posts/:id/extend` | 멤버, 독후감만 | `ExtendPostRequest { clientId }` → `PostResponse` |
| `GET /posts/:id/comments?cursor&limit` | 멤버 | → `Page<CommentResponse>` (오래된 것 먼저) |
| `POST /posts/:id/comments` | 멤버 | `CreateCommentRequest { clientId, body, mediaIds: [UUID], stickerId: UUID? }` → 201 `CommentResponse` |
| `DELETE /comments/:id` | 작성자, 관리자 | → 204 |
| `PUT /posts/:id/reactions` | 멤버 | `ReactionRequest { key: ReactionKey }` → `[ReactionSummary]` |
| `DELETE /posts/:id/reactions?emoji=` 또는 `?stickerId=` | 멤버 | → `[ReactionSummary]` |

```swift
struct CreatePostRequest { clientId: UUID; kind: PostKind; title: String?; body: String?
                           items: [PrayerItem]?      // 기도제목: 1~10개 필수, 그 밖: 보내면 422
                           book: BookInfo?           // 독후감: 필수
                           deadline: LocalDate?; visibleDays: Int?   // 기도제목만
                           timeZone: String; language: String?       // "ko" | "en"
                           mediaIds: [UUID] }        // 0~4, purpose=post
  // body: 독후감·간증 필수(1~2,000자), 기도제목은 선택(≤ 2,000자)
struct PostResponse { id: UUID; groupId: UUID; kind: PostKind; author: UserSummary; isMine: Bool
                      title: String?; body: String?; items: [PrayerItem]?; book: BookInfo?
                      deadline: LocalDate?; visibleDays: Int?; timeZone: String; language: String?
                      createdAt: Date; expiresAt: Date; extensionCount: Int; media: [MediaRef]
                      commentCount: Int; reactions: [ReactionSummary]; isUnread: Bool }
struct CommentResponse { id: UUID; postId: UUID; author: UserSummary; isMine: Bool; body: String
                         media: [MediaRef]; sticker: StickerResponse?; stickerRemoved: Bool
                         createdAt: Date }
  // 댓글: body ≤ 500자, body·media·sticker 중 하나는 있어야 함
```

### 스티커

| 메서드·경로 | 권한 | 요청 → 응답 |
| --- | --- | --- |
| `GET /groups/:id/stickers` | 멤버 | → `[StickerResponse]` |
| `POST /groups/:id/stickers` | 멤버 | `CreateStickerRequest { clientId, mediaId, name? }` → 201 `StickerResponse` |
| `DELETE /stickers/:id` | 만든 사람, 관리자 | → 204 |

`StickerResponse { id: UUID; groupId: UUID; name: String?; media: MediaRef; createdBy: UserSummary?; createdAt: Date; isMine: Bool }`

### 신고

| 메서드·경로 | 요청 → 응답 |
| --- | --- |
| `POST /reports` | `CreateReportRequest { clientId, targetType, targetId: UUID, groupId: UUID, reason, note? }` → 201 `ReportReceipt { id, createdAt }` |

### 공개 (v1 밖)

| 경로 | 내용 |
| --- | --- |
| `GET /api/health` | `HealthResponse { status: "ok"\|"degraded", database: Bool, worker: WorkerHealth { lastBeatAt: Date?, healthy: Bool }, version: String }`. DB가 안 되면 503 |
| `GET /.well-known/apple-app-site-association` | 6절 |
| `GET /i/:code` | 6절 |

### 운영자 (`/internal/admin/v1`, 14절)

| 메서드·경로 | 요청 → 응답 |
| --- | --- |
| `GET /reports?status=open\|dismissed\|actioned&cursor&limit` | → `Page<AdminReport>` |
| `GET /reports/:id` | → `AdminReportDetail { report: AdminReport, liveTarget: AdminTarget? }` |
| `POST /reports/:id/resolve` | `{ resolution: "dismissed"\|"actioned", note? }` → `AdminReport` |
| `DELETE /posts/:id?reportId=` | → 204 |
| `DELETE /comments/:id?reportId=` | → 204 |
| `DELETE /stickers/:id?reportId=` | → 204 |
| `POST /users/:id/suspend` | `{ reason, until: Date? }` → 204 |
| `POST /users/:id/unsuspend` | → 204 |
| `GET /media/:id` | → `image/jpeg` (원본이 있을 때) |
| `GET /status` | → `{ workers: [WorkerHealth+name], counts: { users, groups, posts, openReports, pendingPush } }` |

```swift
struct AdminReport { id: UUID; createdAt: Date; status: String; reason: ReportReason; note: String?
                     targetType: ReportTargetType; targetId: UUID; groupId: UUID?; groupName: String?
                     reporter: AdminUserRef?; targetUser: AdminUserRef?; snapshot: ReportSnapshot
                     resolvedAt: Date?; resolvedBy: String? }
struct AdminUserRef { id: UUID; displayName: String?; suspendedUntil: Date? }
struct ReportSnapshot { authorId: UUID?; authorName: String?; title: String?; body: String?
                        items: [PrayerItem]?; book: BookInfo?; mediaIds: [UUID]; capturedAt: Date }
struct AdminTarget { exists: Bool; post: PostResponse?; comment: CommentResponse?; sticker: StickerResponse? }
```

## 오류 코드 (`PilgrimAPI.APIErrorCode`, raw 값 = JSON)

| case | raw | HTTP | 언제 |
| --- | --- | --- | --- |
| `invalidRequest` | `INVALID_REQUEST` | 400 | JSON·경로 형식 오류, 알 수 없는 bundleId |
| `validationFailed` | `VALIDATION_FAILED` | 422 | 필드 값 규칙 위반(`field`) |
| `limitExceeded` | `LIMIT_EXCEEDED` | 422 | 길이·개수 초과(`field`, `limit`) |
| `unauthenticated` | `UNAUTHENTICATED` | 401 | access token 없음·틀림 |
| `tokenExpired` | `TOKEN_EXPIRED` | 401 | access 만료 → 갱신 |
| `refreshTokenInvalid` | `REFRESH_TOKEN_INVALID` | 401 | 모르는·만료·폐기 refresh |
| `refreshTokenReused` | `REFRESH_TOKEN_REUSED` | 401 | 재사용 감지, family 폐기 |
| `appleTokenInvalid` | `APPLE_TOKEN_INVALID` | 401 | 서명·iss·aud·exp 실패 |
| `appleNonceMismatch` | `APPLE_NONCE_MISMATCH` | 401 | nonce 불일치 |
| `appleCodeExchangeFailed` | `APPLE_CODE_EXCHANGE_FAILED` | 502 | Apple 토큰 교환 실패 |
| `signupRequired` | `SIGNUP_REQUIRED` | 403 | 이름 없이 그룹 API |
| `accountSuspended` | `ACCOUNT_SUSPENDED` | 403 | 정지 |
| `forbidden` | `FORBIDDEN` | 403 | 권한 없음(관리자·작성자 아님) |
| `removedFromGroup` | `REMOVED_FROM_GROUP` | 403 | 강퇴된 그룹에 다시 들어오기 |
| `subscriptionRequired` | `SUBSCRIPTION_REQUIRED` | 402 | 플래그 켜짐 + 구독 없음 |
| `subscriptionInvalid` | `SUBSCRIPTION_INVALID` | 422 | JWS 검증 실패 |
| `subscriptionOwnedByOtherUser` | `SUBSCRIPTION_OWNED_BY_OTHER_USER` | 409 | 다른 계정의 거래 |
| `notFound` | `NOT_FOUND` | 404 | 없음·비멤버·만료·차단 |
| `adminVoteInProgress` | `ADMIN_VOTE_IN_PROGRESS` | 409 | 투표 중 관리자 기능·초대 수락 |
| `groupPendingDeletion` | `GROUP_PENDING_DELETION` | 409 | 삭제 예정 그룹에 쓰기 |
| `voteNotOpen` | `VOTE_NOT_OPEN` | 409 | 열린 투표 없음에 투표 |
| `invalidCandidate` | `INVALID_CANDIDATE` | 422 | 후보 밖 |
| `inviteExpired` | `INVITE_EXPIRED` | 410 | 3일 지남 |
| `inviteRevoked` | `INVITE_REVOKED` | 410 | 취소됨 |
| `inviteFull` | `INVITE_FULL` | 409 | 인원 다 참 |
| `inviteLimitReached` | `INVITE_LIMIT_REACHED` | 409 | 그룹당 살아 있는 초대 20개 |
| `groupLimitReached` | `GROUP_LIMIT_REACHED` | 409 | 만들 수 있는·속할 수 있는 그룹 수 |
| `extendNotAllowed` | `EXTEND_NOT_ALLOWED` | 422 | 독후감이 아닌 글 연장 |
| `stickerLimitReached` | `STICKER_LIMIT_REACHED` | 409 | 그룹당 30개 |
| `mediaInvalid` | `MEDIA_INVALID` | 422 | 형식·크기 규칙 위반 |
| `mediaTooLarge` | `MEDIA_TOO_LARGE` | 413 | 용량 초과 |
| `mediaNotAttachable` | `MEDIA_NOT_ATTACHABLE` | 409 | 남의 미디어, 이미 붙음, 목적 다름 |
| `cannotTargetSelf` | `CANNOT_TARGET_SELF` | 422 | 자기 차단·숨김·신고·강퇴·넘기기 |
| `rateLimited` | `RATE_LIMITED` | 429 | `retryAfter` |
| `clientUpgradeRequired` | `CLIENT_UPGRADE_REQUIRED` | 426 | 앱 버전 차단 |
| `internal` | `INTERNAL` | 500 | 그 밖 |
| `serviceUnavailable` | `SERVICE_UNAVAILABLE` | 503 | DB 등 의존 실패 |

앱은 모르는 `code`를 `unknown`으로 받는다(`APIErrorCode(rawValue:) ?? .unknown`, 디코딩 실패 아님).

## Postgres 스키마

- 모든 테이블은 Fluent `@ID`(uuid, 앱에서 생성) 기본 키 `id`를 갖고 자연 키는 UNIQUE로 둔다. 시각은
  `timestamptz`, 생성·수정 시각은 Fluent `@Timestamp`(`created_at`, `updated_at`). 열거값은 `text` +
  CHECK. 문자열 길이는 앱·서버 검증이 맡고 DB는 CHECK를 최소로 둔다.
- `users ↔ media`는 서로 참조하므로 `users`, `media`를 만든 뒤 `users.profile_media_id` FK를 따로 추가한다.

### 계정

**users**

| 열 | 타입 | 비고 |
| --- | --- | --- |
| `id` | uuid PK | |
| `apple_sub` | text NOT NULL UNIQUE | 개발 로그인은 `dev:<name>` |
| `display_name` | text NULL | null = 가입 전 |
| `profile_media_id` | uuid NULL FK media(id) ON DELETE SET NULL | |
| `time_zone` | text NOT NULL DEFAULT 'Asia/Seoul' | IANA |
| `locale` | text NULL | |
| `daily_report_enabled` | bool NOT NULL DEFAULT true | |
| `daily_report_minute` | smallint NOT NULL DEFAULT 1320 CHECK 0..1439 | API는 `LocalTime` |
| `suspended_at` | timestamptz NULL | |
| `suspended_until` | timestamptz NULL | null + suspended_at = 무기한 |
| `suspension_reason` | text NULL | |
| `created_at`, `updated_at` | timestamptz NOT NULL | |

**apple_tokens**: `id`, `user_id` uuid NOT NULL FK users ON DELETE CASCADE, `client_id` text NOT NULL(번들 ID),
`refresh_token_ciphertext` bytea NOT NULL(nonce ‖ ciphertext ‖ tag), `created_at`, `updated_at`.
UNIQUE(`user_id`, `client_id`).

**apple_token_revocations**: `id`, `client_id` text NOT NULL, `refresh_token_ciphertext` bytea NOT NULL,
`attempts` int NOT NULL DEFAULT 0, `next_attempt_at` timestamptz NOT NULL, `last_error` text NULL,
`completed_at` timestamptz NULL, `created_at`. FK 없음(사용자는 이미 없다). INDEX(`next_attempt_at`) WHERE
`completed_at IS NULL`.

**refresh_tokens**: `id`, `user_id` FK users CASCADE, `family_id` uuid NOT NULL, `token_hash` bytea NOT NULL
UNIQUE, `installation_id` uuid NOT NULL, `issued_at`, `expires_at` timestamptz NOT NULL, `used_at` NULL,
`replaced_by_id` uuid NULL, `revoked_at` NULL. INDEX(`user_id`), INDEX(`family_id`), INDEX(`expires_at`).

**devices**: `id`, `user_id` FK users CASCADE, `installation_id` uuid NOT NULL UNIQUE, `apns_token` text NULL,
`apns_environment` text NOT NULL CHECK ('sandbox','production'), `bundle_id` text NOT NULL, `platform` text NOT
NULL CHECK ('ios','macos'), `locale` text NULL, `time_zone` text NULL, `app_version` text NULL, `created_at`,
`updated_at`. INDEX(`user_id`), INDEX(`apns_token`). 같은 `apns_token`이 다른 행에 있으면 등록 때 그 행의
토큰을 비운다.

**subscriptions**: `id`, `user_id` uuid NULL FK users CASCADE, `original_transaction_id` text NOT NULL UNIQUE,
`product_id` text NOT NULL, `status` text NOT NULL CHECK ('active','gracePeriod','billingRetry','expired',
'revoked'), `expires_at` timestamptz NULL, `environment` text NOT NULL CHECK ('Production','Sandbox'),
`bundle_id` text NOT NULL, `app_account_token` uuid NULL, `last_transaction_id` text NULL, `storefront` text
NULL, `removal_processed_at` timestamptz NULL, `last_checked_at` timestamptz NULL, `created_at`, `updated_at`.
INDEX(`user_id`), INDEX(`status`, `expires_at`).

**appstore_notifications**: `id` uuid PK(= `notificationUUID`), `notification_type` text NOT NULL, `subtype`
text NULL, `original_transaction_id` text NULL, `signed_date` timestamptz NULL, `received_at` timestamptz NOT
NULL. 90일 보관.

### 그룹

**groups**: `id`, `name` text NOT NULL, `created_by_id` uuid NULL FK users ON DELETE SET NULL, `admin_id` uuid
NULL FK users ON DELETE SET NULL, `status` text NOT NULL DEFAULT 'active' CHECK ('active','voting',
'pendingDeletion'), `delete_at` timestamptz NULL, `deletion_reason` text NULL CHECK ('noVotes','adminDeleted'),
`client_id` uuid NULL, `created_at`, `updated_at`. UNIQUE(`created_by_id`, `client_id`). INDEX(`status`,
`delete_at`).

**memberships**: `id`, `group_id` FK groups CASCADE, `user_id` FK users CASCADE, `joined_at` timestamptz NOT NULL,
`last_seen_at` timestamptz NULL, `new_post_push_enabled` bool NOT NULL DEFAULT true, `daily_report_enabled` bool
NOT NULL DEFAULT true, `invite_id` uuid NULL FK invites ON DELETE SET NULL. UNIQUE(`group_id`, `user_id`),
INDEX(`user_id`). 관리자 여부는 `groups.admin_id`로만 판단한다(역할 열 없음).

**group_bans**: `id`, `group_id` FK groups CASCADE, `user_id` FK users CASCADE, `banned_by_id` uuid NULL FK users
SET NULL, `created_at`. UNIQUE(`group_id`, `user_id`).

**invites**: `id`, `group_id` FK groups CASCADE, `code` text NOT NULL UNIQUE(정규화한 12자), `created_by_id` uuid
NULL FK users SET NULL, `max_uses` int NOT NULL CHECK 1..100, `use_count` int NOT NULL DEFAULT 0 CHECK
`use_count <= max_uses`, `expires_at` timestamptz NOT NULL, `revoked_at` timestamptz NULL, `client_id` uuid
NULL, `created_at`. UNIQUE(`created_by_id`, `client_id`), INDEX(`group_id`), INDEX(`expires_at`).

**admin_votes**: `id`, `group_id` FK groups CASCADE, `round` smallint NOT NULL CHECK (1,2), `candidate_ids`
uuid[] NOT NULL, `eligible_ids` uuid[] NOT NULL, `started_at`, `ends_at` timestamptz NOT NULL, `status` text NOT
NULL CHECK ('open','closed'), `outcome` text NULL CHECK ('elected','runoff','random','noVotes','restarted',
'groupDeleted'), `elected_user_id` uuid NULL FK users SET NULL, `closed_at` NULL. UNIQUE(`group_id`) WHERE
`status = 'open'`, INDEX(`status`, `ends_at`).

**ballots**: `id`, `vote_id` FK admin_votes CASCADE, `voter_id` FK users CASCADE, `candidate_id` uuid NOT NULL FK
users CASCADE, `created_at`, `updated_at`. UNIQUE(`vote_id`, `voter_id`).

### 콘텐츠

**posts**

| 열 | 타입 | 비고 |
| --- | --- | --- |
| `id` | uuid PK | |
| `group_id` | uuid NOT NULL FK groups ON DELETE CASCADE | |
| `author_id` | uuid NOT NULL FK users ON DELETE CASCADE | 강퇴는 행을 지우지 않으므로 글이 남는다 |
| `kind` | text NOT NULL CHECK ('prayer','bookReport','testimony') | |
| `title` | text NULL | |
| `body` | text NULL | |
| `items` | jsonb NULL | `[{"text","topic","who"}]` |
| `book_title`, `book_author` | text NULL | |
| `deadline` | text NULL CHECK `~ '^\d{4}-\d{2}-\d{2}$'` | `LocalDate` 그대로 |
| `visible_days` | smallint NULL CHECK (3,7,14,30) | |
| `time_zone` | text NOT NULL | |
| `language` | text NULL | |
| `expires_at` | timestamptz NOT NULL | |
| `extension_count` | int NOT NULL DEFAULT 0 | |
| `client_id` | uuid NOT NULL | |
| `created_at` | timestamptz NOT NULL | |

UNIQUE(`author_id`, `client_id`), INDEX(`group_id`, `created_at` DESC, `id` DESC), INDEX(`expires_at`),
INDEX(`author_id`).

**post_extensions**: `id`, `post_id` FK posts CASCADE, `user_id` FK users CASCADE, `client_id` uuid NOT NULL,
`previous_expires_at`, `new_expires_at` timestamptz NOT NULL, `created_at`. UNIQUE(`user_id`, `client_id`),
INDEX(`post_id`).

**stickers**: `id`, `group_id` FK groups CASCADE, `created_by_id` uuid NOT NULL FK users CASCADE, `media_id` uuid
NOT NULL UNIQUE FK media ON DELETE CASCADE, `name` text NULL, `client_id` uuid NOT NULL, `created_at`.
UNIQUE(`created_by_id`, `client_id`), INDEX(`group_id`).

**comments**: `id`, `post_id` FK posts CASCADE, `author_id` FK users CASCADE, `body` text NOT NULL DEFAULT '',
`sticker_id` uuid NULL FK stickers ON DELETE SET NULL, `had_sticker` bool NOT NULL DEFAULT false(지워진 스티커
표시용), `client_id` uuid NOT NULL, `created_at`. UNIQUE(`author_id`, `client_id`), INDEX(`post_id`,
`created_at`, `id`).

**reactions**: `id`, `post_id` FK posts CASCADE, `user_id` FK users CASCADE, `emoji` text NULL, `sticker_id` uuid
NULL FK stickers ON DELETE CASCADE, `created_at`. CHECK(`(emoji IS NULL) <> (sticker_id IS NULL)`).
UNIQUE(`post_id`, `user_id`, `emoji`) WHERE `emoji IS NOT NULL`, UNIQUE(`post_id`, `user_id`, `sticker_id`)
WHERE `sticker_id IS NOT NULL`, INDEX(`post_id`).

**media**

| 열 | 타입 | 비고 |
| --- | --- | --- |
| `id` | uuid PK | |
| `uploader_id` | uuid NOT NULL FK users ON DELETE CASCADE | |
| `purpose` | text NOT NULL CHECK ('post','comment','profile','sticker') | |
| `group_id` | uuid NULL FK groups ON DELETE CASCADE | profile은 null |
| `post_id` | uuid NULL FK posts ON DELETE CASCADE | |
| `comment_id` | uuid NULL FK comments ON DELETE CASCADE | |
| `sort_order` | smallint NOT NULL DEFAULT 0 | 글·댓글 안 순서 |
| `file_path` | text NOT NULL | `MEDIA_ROOT` 기준 상대 경로 |
| `content_type` | text NOT NULL DEFAULT 'image/jpeg' | |
| `byte_count`, `width`, `height` | int NOT NULL | |
| `sha256` | bytea NOT NULL | |
| `client_id` | uuid NOT NULL | |
| `attached_at` | timestamptz NULL | null = 아직 안 붙음 |
| `created_at` | timestamptz NOT NULL | |

UNIQUE(`uploader_id`, `client_id`), INDEX(`post_id`), INDEX(`comment_id`), INDEX(`created_at`) WHERE
`attached_at IS NULL`. 스티커는 `stickers.media_id`가, 프로필은 `users.profile_media_id`가 가리킨다.

**media_file_deletions**: `id`, `file_path` text NOT NULL, `attempts` int NOT NULL DEFAULT 0, `created_at`.
트리거 `media_after_delete`(AFTER DELETE ON media FOR EACH ROW)가 `OLD.file_path`를 넣는다(마이그레이션에서
SQLKit 원문 SQL).

### 안전

**hides**: `id`, `user_id` FK users CASCADE, `post_id` uuid NULL FK posts CASCADE, `target_user_id` uuid NULL FK
users CASCADE, `created_at`. CHECK(`(post_id IS NULL) <> (target_user_id IS NULL)`). UNIQUE(`user_id`,
`post_id`) WHERE `post_id IS NOT NULL`, UNIQUE(`user_id`, `target_user_id`) WHERE `target_user_id IS NOT NULL`.

**blocks**: `id`, `blocker_id` FK users CASCADE, `blocked_id` FK users CASCADE, `created_at`.
UNIQUE(`blocker_id`, `blocked_id`), INDEX(`blocked_id`). CHECK(`blocker_id <> blocked_id`).

**reports**: `id`, `reporter_id` uuid NULL FK users SET NULL, `group_id` uuid NULL FK groups SET NULL,
`target_type` text NOT NULL CHECK ('post','comment','sticker','user'), `target_id` uuid NOT NULL(FK 없음),
`target_user_id` uuid NULL FK users SET NULL, `reason` text NOT NULL, `note` text NULL, `snapshot` jsonb NOT
NULL, `status` text NOT NULL DEFAULT 'open' CHECK ('open','dismissed','actioned'), `resolved_at` NULL,
`resolved_by` text NULL, `client_id` uuid NOT NULL, `created_at`. UNIQUE(`reporter_id`, `client_id`),
INDEX(`status`, `created_at`), INDEX(`created_at`).

**moderation_log**: `id`, `actor` text NOT NULL, `action` text NOT NULL CHECK ('deletePost','deleteComment',
'deleteSticker','suspendUser','unsuspendUser','resolveReport'), `target_type` text NOT NULL, `target_id` uuid NOT
NULL, `report_id` uuid NULL(FK 없음), `note` text NULL, `created_at`. 내용은 담지 않는다. 지우지 않는다.

### 작업

**push_outbox**: `id`, `recipient_user_id` FK users CASCADE, `kind` text NOT NULL, `payload` jsonb NOT NULL
(`PushPayload`), `collapse_id` text NULL, `attempts` int NOT NULL DEFAULT 0, `next_attempt_at` timestamptz NOT
NULL, `sent_at` NULL, `failed_at` NULL, `last_error` text NULL, `created_at`. INDEX(`next_attempt_at`) WHERE
`sent_at IS NULL AND failed_at IS NULL`.

**daily_report_log**: `id`, `user_id` FK users CASCADE, `report_date` text NOT NULL(`LocalDate`), `window_start`,
`window_end` timestamptz NOT NULL, `status` text NOT NULL CHECK ('sent','skipped'), `item_count` int NOT NULL,
`created_at`. UNIQUE(`user_id`, `report_date`).

**worker_heartbeat**: `id`, `loop` text NOT NULL UNIQUE, `last_beat_at` timestamptz NOT NULL, `last_error` text
NULL, `last_error_at` NULL.

## worker

`Run worker`: 한 프로세스가 아래 루프를 각자의 `Task`로 돌린다. 루프마다 한 번에 처리할 묶음 크기를 두고, 한 묶음은
한 트랜잭션이다. 루프 시작 때 `pg_try_advisory_lock(<루프 번호>)`을 잡아 worker가 둘 떠도 같은 일을 두 번 하지
않는다. 각 반복 뒤 `worker_heartbeat`를 갱신한다. `TIME_SCALE_DAY_SECONDS`는 기한·투표·유예·초대 계산에 쓰고 루프
간격에는 쓰지 않는다.

| 루프 | 간격 | 하는 일 |
| --- | --- | --- |
| `pushOutbox` | 5초 | 보낼 행 100개 → 받는 사람의 기기마다 APNs(`APNSSending` 프로토콜, 테스트는 가짜). 잘못된 토큰 정리, 재시도(30초·2분·10분 뒤, 그 뒤 `failed_at`) |
| `expiry` | 60초 | `expires_at <= now()`인 글 500개씩 삭제(cascade로 댓글·반응·연장·사진 행, 트리거로 파일 큐) |
| `mediaFiles` | 60초 | `media_file_deletions` 파일 삭제(없으면 성공), 24시간 넘게 안 붙은 미디어 삭제 |
| `votes` | 60초 | `ends_at <= now()`인 열린 투표를 `AdminVoteRules.close`로 마감, 결과 알림. `pendingDeletion`이고 `delete_at <= now()`인 그룹 삭제 |
| `dailyReport` | 60초 | 지금 리포트 시각이 지났고 오늘 `daily_report_log`가 없는 사용자 → 집계, 0이면 `skipped`, 아니면 outbox |
| `appleRevocation` | 5분 | `apple_token_revocations`를 Apple `/auth/revoke`로. 실패하면 지수 백오프(최대 10회, 그 뒤 `last_error`로 남김) |
| `subscriptions` | 10분 | `SUBSCRIPTION_REQUIRED=true`일 때만: 만료 처리(12절). 1시간마다 오래된 구독 재확인 |
| `invites` | 1시간 | `expires_at`이 7일 넘게 지난 초대 행 삭제 |
| `retention` | 1시간 | 신고 90일, `push_outbox` 보낸 지 7일·실패 30일, `daily_report_log` 30일, `appstore_notifications` 90일, 만료·폐기된 refresh token 7일 지난 것 삭제 |

`/api/health`의 `worker.healthy`는 모든 루프의 `last_beat_at`이 2분 안일 때 참이다.

## 제한 (`PilgrimAPI.APILimits`)

| 항목 | 값 |
| --- | --- |
| 표시 이름 | 1~30자 |
| 그룹 이름 | 1~40자, 줄바꿈 없음 |
| 글 제목 | ≤ 80자 |
| 글 본문 | ≤ 2,000자 |
| 기도제목 항목 | 1~10개, 항목당 ≤ 200자, `who` ≤ 30자 |
| 책 제목 / 저자 | ≤ 100자 / ≤ 60자 |
| 댓글 | ≤ 500자 |
| 사진 | 글·댓글당 ≤ 4장, 장당 ≤ 500KB, 긴 변 ≤ 1600px |
| 스티커 | 256×256, ≤ 100KB, 이름 ≤ 20자, 그룹당 ≤ 30개 |
| 초대 | `maxUses` 1~100, 그룹당 살아 있는 초대 ≤ 20개, 3일 |
| 그룹 수 | 만든 그룹(살아 있는 것) ≤ 20, 속한 그룹 ≤ 100 |
| 반응 | 한 사람이 한 글에 서로 다른 반응 ≤ 10개, 이모지는 grapheme 1개·≤ 32바이트 |
| 신고 메모 | ≤ 500자 |
| 데드라인 | 오늘 ~ 오늘 + 365일 |
| `visibleDays` | 3, 7, 14, 30 |

글자 수는 Swift `String.count`(grapheme) 기준이다. rate limit(사용자별, 환경 변수로 조정): 글 30/시간, 댓글
120/시간, 업로드 60/시간, 반응 300/시간, 신고 20/일, 초대 만들기 30/일, 그 밖 요청 600/10분. 인증 전
엔드포인트는 IP별 30/10분.

## 환경 변수 (`server/.env.*.example`, I1)

`APP_ENV`(development|production), `DATABASE_URL`, `PUBLIC_BASE_URL`, `JWT_SECRET`, `APPLE_TEAM_ID`,
`APPLE_SIWA_KEY_ID`, `APPLE_SIWA_PRIVATE_KEY`(.p8), `APPLE_TOKEN_ENC_KEY`, `APNS_KEY_ID`,
`APNS_PRIVATE_KEY`(.p8), `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY`(.p8), `MEDIA_ROOT`,
`MEDIA_URL_SECRET`, `ADMIN_API_TOKEN`, `REPORT_WEBHOOK_URL`(선택), `SUBSCRIPTION_REQUIRED`(기본 false),
`MIN_CLIENT_VERSION`, `DEV_LOGIN_ENABLED`(기본 false), `TIME_SCALE_DAY_SECONDS`(기본 86400),
`RATE_LIMIT_*`. 번들 ID 두 개는 상수(`PilgrimAPI.BundleIDs.all`)다.

## Risks / Trade-offs

- **집 맥미니 한 대** → 정전·업데이트 동안 그룹이 멈춘다(받아들임, `docs/group-server.md`). 앱은 "그룹 서버에
  연결할 수 없어요"를 보이고 작성 중인 글을 지킨다. 기록장은 영향 없음.
- **프로세스 메모리 rate limit** → API를 다시 시작하면 초기화된다. 인스턴스 하나라 충분하다. Cloudflare 규칙이 앞에서
  한 번 더 막는다.
- **서버가 JPEG을 디코딩하지 않는다** → 픽셀 검사가 없다. 시그니처·SOF·세그먼트 구조 검사와 크기 제한으로
  충분하다고 본다. 앱이 이미 다시 인코딩한다.
- **신고 스냅샷을 계정 삭제 뒤에도 90일 둔다** → 신고된 사람이 계정을 지워 증거를 없애는 것을 막는다. 대신
  `privacy.md`에 적는다(D1).
- **투표 득표 비공개** → 결과에 대한 의심이 생길 수 있다. 마감 뒤에도 득표는 보이지 않고 결과와 결정 방식(득표·
  무작위)만 보인다.
- **스크랩 유형이 옛 버전에서 사용자 유형처럼 보인다** → 15절. 이름이 저장되므로 "이름 없는 유형"으로 보이지는 않는다.
- **푸시 키가 ASCII 상수** → Korean-key 규칙의 예외. 서버와 앱 카탈로그 키가 바뀌지 않아야 하므로 상수로 고정한다.
- **refresh 재사용 30초 유예** → 탈취한 토큰을 같은 `installationId`로 30초 안에 쓰면 감지가 늦는다. 응답을 못 받은
  재시도로 로그아웃되는 것을 막는 편이 낫다고 본다.

## Migration Plan

1. T0.1(이 문서) 승인 → T0.2 계약·배선, T0.3 앱 뼈대·T0.4 서버 뼈대(병렬).
2. Phase 1 두 묶음(tasks.md). 모든 PR은 `feat/groups`로.
3. Phase 2: 현지화, `PreviewGroupAPI` → 실제 클라이언트, 전체 검증, 맥미니 배포와 터널 ingress, 실기기 확인.
4. main에는 서버·CI 먼저, 앱은 Release에서 `GroupsFeature.isEnabled = false`인 채로 조각내어 합친다. entitlement
   (`aps-environment`, `applinks`)는 1.2.0 출시 뒤에 main에 넣는다.
5. 되돌리기: 앱은 플래그를 끄면 그룹이 보이지 않는다. 서버는 독립 compose 프로젝트라 멈추거나 지워도 기록장과 콘솔에
   영향이 없다. 스크랩 기록은 일반 기록이라 남는다.

## Open Questions

- `SUBSCRIPTION_REQUIRED`를 나중에 `true`로 바꿀 때, 한 번도 구독하지 않은 기존 멤버를 어떻게 할지(지금 설계는
  402로 막기만 하고 그룹에서 빼지 않는다. 만료 처리는 구독 행이 있는 사람에게만 동작한다). 바꾸기 전에 정한다.
- 이용약관·연락처 페이지 주소(App Review 1.2, 지원 사이트 저장소). 가입 화면이 링크한다.
- 콘솔 관리자 계정이 둘 이상이 될 때 `X-Admin-Actor`를 콘솔 세션 사용자 이름으로 쓰는 것으로 충분한지.

## 계획에서 정하지 않아 이 문서에서 정한 것

1. 강퇴는 강퇴 기록(`group_bans`)을 남기고, 관리자가 풀기 전까지 어떤 초대로도 다시 들어오지 못한다.
2. 관리자의 그룹 삭제도 바로 지우지 않고 7일 유예(`pendingDeletion`, `adminDeleted`)를 둔다. 그동안 스크랩할 수
   있다. 취소는 없다.
3. 관리자가 나갈 때 남은 멤버가 1명이면 투표 없이 그 사람이 관리자, 0명이면 그룹을 바로 지운다.
4. 투표는 비밀(참여 수만 공개), 마감 전까지 바꿀 수 있고, 자기 자신에게도 투표할 수 있다. 2라운드에 아무도 투표하지
   않으면 2라운드 후보 중 무작위. 후보가 모두 나가면 1라운드를 다시 시작한다.
5. 반응은 글에만 단다(댓글 반응 없음). 한 사람이 한 글에 다른 반응 10개까지.
6. 스티커를 지우면 그 스티커를 쓴 댓글은 남고 "지워진 스티커"로 보인다. 계정을 지우면 그 사람이 만든 스티커도 지운다.
7. 사람 단위 숨김은 모든 그룹에 적용된다.
8. 서버는 썸네일을 만들지 않고 JPEG만 받는다. 메타데이터는 디코딩 없이 세그먼트를 다시 써서 지운다.
9. 서명 미디어 URL은 `/api/media-files/:id`(HMAC, 10분)이고 응답의 `MediaRef`에 바로 들어 있다.
10. 계획의 표에 없던 테이블: `group_bans`, `apple_token_revocations`, `appstore_notifications`,
    `media_file_deletions`(DB cascade와 파일 삭제를 맞추는 트리거).
11. refresh 재사용 감지에 같은 기기 30초 유예를 둔다.
12. Apple 인증 코드 교환이 실패하면 로그인도 실패한다(폐기할 토큰을 반드시 갖기 위해).
13. 데드라인은 `YYYY-MM-DD` 문자열로 저장하고, 데드라인과 `visibleDays`를 함께 보내면 거부한다.
14. 푸시 문구 키는 ASCII 상수(`PilgrimAPI.PushLocKey`)로 Korean-key 규칙의 예외다. 앱 아이콘 배지는 쓰지 않는다.
15. `X-Pilgrim-Client`가 없으면 426(`/api/v1` 전부).
16. Daily Report 범위는 리포트 시각까지 24시간, 그룹별로 Daily Report를 끌 수 있다(새 글 푸시와 따로).
17. 구독 구매에 `appAccountToken = 서버 사용자 ID`를 넣고, 다른 계정에 묶인 거래는 409로 거부한다.
18. 그룹 수 제한(만든 그룹 20, 속한 그룹 100)과 그룹당 살아 있는 초대 20개.
19. `DELETE /me`는 사용자가 이미 없으면 200 `alreadyDeleted`로 답한다(멱등).
20. 신고 스냅샷은 신고 대상이 계정을 지워도 90일 보관한다. `moderation_log`는 내용 없이 계속 둔다.
21. 스크랩: `occurredAt`은 글을 올린 시각, 유형은 첫 스크랩 때 나타나고 직접 만들 수 없으며 지울 수 있다. 이름이
    겹치면 "그룹 스크랩". 노트북 이름은 스크랩 순간의 그룹 이름. 이미 스크랩한 글은 묻고 다시 저장한다.
22. 그룹 글은 고칠 수 없다(내리고 다시 올린다).
23. 신고 사유 목록: spam, harassment, inappropriate, selfHarm, other.
