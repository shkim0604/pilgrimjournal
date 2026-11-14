# 그룹 서버 설계안 (맥미니 자체 호스팅)

2026-11-03 작성, 2026-11-14 이번 구현 범위에 맞춰 고침. 주인 요청: 그룹 기능 전용 서버를 집의 M1
맥미니에 두고 `pilgrim.delight-house.org/api`로 연다. DB와 함께 Docker로 돌린다.

**원칙(2026-11-03 확정): 개인 기록은 iCloud, 공유·SNS는 서버.** 기록장·스크랩은
지금처럼 기기 + 사용자 본인의 CloudKit private DB에 두고, 그룹에 올린 카드와 그룹
활동만 이 서버에 둔다. 이 결정으로 2026-10-21의 "그룹 저장소를 CloudKit으로"
방향(PR #22 `groups-cloudkit.md`)은 다시 **자체 서버**로 돌아온다. CloudKit 검토는
왜 서버가 필요한지에 대한 기록으로 남긴다. 기능 요구사항은 `docs/roadmap.md`를 따른다.

**구현 계약은 openspec 변경 `openspec/changes/add-private-groups/`가 원본이다.** API 엔드포인트와
요청·응답 필드, 오류 코드, Postgres 테이블·열·인덱스, worker 루프, 제한 값은 그 `design.md`에 있다.
이 문서는 운영 구조와 결정의 이유를 적는다. 둘이 어긋나면 `design.md`를 따르고 이 문서를 고친다.

## 이번 범위 (2026-11-14 주인 결정)

- 그룹 만들기, 초대 링크·QR(링크별 최대 인원, 3일 만료)
- 관리자 = 만든 사람. 관리자가 나가면 위임 투표(3일, 동률이면 1일 재투표, 또 동률이면 무작위,
  아무도 안 하면 1주 유예 뒤 그룹 삭제). 직접 넘기기도 된다
- 글: 기도제목·독후감·간증, 기한 자동 삭제, 독후감 토론 연장(+1주, 무제한), 사진(기기에서 압축)
- 댓글, 이모지 반응, **그룹 스티커**(멤버가 사진으로 만드는 그룹 전용 이모티콘)
- 신고·양방향 차단·숨김(글 단위·사람 단위, 서버에 저장해 내 기기끼리 맞춤)
- 새 글 즉시 푸시, 댓글 등은 밤 10시 **Daily Report**(시각 설정 가능)
- **스크랩**: 내 iCloud 기록장으로 복사(새 기본 유형 "스크랩", 그룹별 노트북). 서버에는 남기지 않는다
- **구독**: StoreKit 구독과 서버 검증까지 만들고, 출시 때는 서버 설정
  `SUBSCRIPTION_REQUIRED=false`로 **끈다**(무료로 연다)
- 가입: 그룹을 시작할 때 이름과 프로필 사진(선택)
- 앱 화면: 사이드바의 "그룹" 섹션(하단 탭 바 아님)

## 지금 맥미니에 있는 것 (2026-11-03 확인, 11-14 보충)

- SSH 이름 `delight`. Docker Desktop, Homebrew.
- **놀담 서버**가 이미 같은 방식으로 돌고 있다(`~/Developments/noldam/server`):
  Node 22 + TypeScript + Fastify + drizzle + Postgres 17(`postgres:17-alpine`),
  `docker compose -p noldam-prod`, API는 `127.0.0.1:3000`에만 열고 **Cloudflare
  Tunnel**이 공개 입구다. `https://api.delight-house.org/health`가 응답한다.
- 배포는 개발 맥에서 `make deploy`(rsync → 맥미니에서 `make prod` → `/health` 대기),
  백업은 launchd로 매일 04:00 `pg_dump`, 최근 7개 보관.
- 도메인 `delight-house.org`는 Cloudflare DNS.
- **관리자 콘솔**(`web/admin`, Node + Hono, `docker compose -p pilgrim-admin`, `127.0.0.1:8420`)이 이미
  `pilgrim.delight-house.org/`와 `/admin`을 쓴다. 그래서 그룹 서버는 호스트를 따로 받지 않고 같은
  호스트를 **경로로 나눠** 쓴다(아래).
- 확인 못 한 것: 맥미니의 `cloudflared` 설정이 로컬 `config.yml`인지 Cloudflare
  대시보드 관리형(`TUNNEL_TOKEN`)인지. 경로 규칙을 넣는 곳이 이에 따라 다르다(아래 "터널").

## 구성

```
iPhone/Mac 앱 ──HTTPS──▶ Cloudflare ──Tunnel──▶ 맥미니
                                                 ├─ cloudflared
                                                 │    ├─ ^/(api/|i/|\.well-known/) → 그룹 서버 :3100
                                                 │    └─ 나머지(/, /admin, …)       → 관리자 콘솔 :8420
                                                 ├─ docker compose -p pilgrim-prod
                                                 │    ├─ api      (127.0.0.1:3100, `Run serve`)
                                                 │    ├─ worker   (같은 이미지, `Run worker`)
                                                 │    └─ postgres (내부망만)
                                                 ├─ docker compose -p pilgrim-admin
                                                 │    └─ admin    (127.0.0.1:8420)
                                                 │         └─▶ http://pilgrim-api:3100/internal/admin/v1
                                                 │             (공유 Docker 네트워크 pilgrim-edge, 터널 밖)
                                                 └─ 사진 볼륨 / 백업(launchd, restic → R2)
API ──▶ Apple: Sign in with Apple(JWKS·code 교환·토큰 폐기), App Store Server API,
           App Store Server Notifications V2(웹훅 수신), APNs
```

### 터널: 경로로 나눈다 (2026-11-14 결정)

- `pilgrim.delight-house.org` 아래에서 경로 `^/(api/|i/|\.well-known/)`만 그룹 서버(`http://localhost:3100`,
  cloudflared가 컨테이너면 `http://pilgrim-api:3100`)로 보내고, 나머지는 지금처럼 콘솔로 보낸다. 이
  규칙을 **콘솔 규칙보다 앞에** 둔다.
  - 로컬 `~/.cloudflared/config.yml`이면 `ingress`에 `hostname` + `path: ^/(api/|i/|\.well-known/)` 항목을
    콘솔 항목 위에 넣는다.
  - 대시보드 관리형이면 Zero Trust → Tunnels → Public Hostname에 같은 호스트·같은 path 규칙을 추가하고
    순서를 콘솔 규칙 위로 올린다.
- 그룹 서버가 받는 경로:
  - `/api/v1/...` — 앱 API
  - `/api/health` — DB와 worker 상태
  - `/api/media-files/<id>?exp&sig` — 서명된 사진 내려받기
  - `/api/appstore/notifications` — App Store Server Notifications V2 웹훅
  - `/.well-known/apple-app-site-association` — 초대 Universal Link(두 앱 ID, `/i/*`)
  - `/i/<초대코드>` — 앱이 없는 사람용 안내 페이지. **그룹 이름·인원 같은 그룹 정보는 싣지 않는다.**
- 운영자 라우트 `/internal/admin/v1/*`는 이 경로 규칙에 없으므로 인터넷에서 오면 콘솔로 가고 콘솔은 처리하지
  않는다. 서버도 `X-Admin-Token`을 요구하고 `Cf-Ray`·`Cf-Connecting-IP`가 붙은 요청(터널을 거친 요청)을
  거부한다.
- Cloudflare 봇 차단 규칙이 `/api`와 `/.well-known`을 막지 않게 예외를 둔다(앱과 Apple의 AASA 요청).
- **놀담과 완전히 분리**: compose 프로젝트, Postgres 컨테이너, 볼륨, `.env.prod`,
  백업 폴더, launchd 작업 이름을 따로 둔다. 한쪽 배포·장애·복원이 다른 쪽에 번지지 않게.
- **코드 위치**: 이 저장소의 `server/`. 놀담 `server/`의 구조(Makefile, compose 3장,
  `make deploy`, `db-backup`)를 그대로 옮겨 시작한다.

## API 서버

**Swift + Vapor 4** (2026-11-03 결정). 앱과 같은 언어라 요청·응답 타입을 공유 패키지
하나로 앱과 서버가 함께 쓴다. 착수 때 각 라이브러리의 현재 버전을 확인한다.

| 용도 | 쓰는 것 |
| --- | --- |
| 웹 프레임워크 | `vapor/vapor` 4 |
| DB | `vapor/fluent` + `fluent-postgres-driver`, 마이그레이션은 Fluent migration(트리거 등은 SQLKit 원문) |
| Sign in with Apple 검증 | `vapor/jwt` (Apple identity token 검증 내장) |
| 구독 검증·웹훅 | `apple/app-store-server-library-swift` (Apple 공식) |
| 푸시 | `vapor/apns` (APNSwift 기반, 토큰 인증 `.p8`) |
| 예약 작업 | **단순 polling 루프**(별도 worker 프로세스, Postgres advisory lock). `vapor/queues`와 Redis는 쓰지 않는다 |
| 테스트 | `XCTVapor`/Swift Testing, DB는 테스트용 Postgres 컨테이너 |
| 공유 타입 | `server/PilgrimAPI` Swift 패키지(Foundation만: DTO, 오류 코드, 기한·투표·사진 규칙 순수 함수) — 앱의 루트 `Package.swift`가 `.package(path: "server/PilgrimAPI")`로, 서버가 `.package(path: "PilgrimAPI")`로 쓴다 |

Docker 이미지는 공식 `swift` 이미지로 빌드하고, 실행 단계는 작은 런타임 이미지로
나눈다(arm64, 맥미니 M1). 서버 패키지(`server/Package.swift`)는 앱의 루트 `Package.swift`와
**분리**한다 — Vapor 의존성이 앱 빌드에 섞이지 않게.

공통 규칙: 쓰기 요청은 `clientId`로 멱등 처리한다. 모든 `/api/v1` 요청은 `X-Pilgrim-Client` 헤더를 붙이고,
서버는 `MIN_CLIENT_VERSION`보다 낮은 앱을 426으로 막을 수 있다. 번들 ID는 Release
`com.dhouse.PilgrimJournal`과 Debug `com.dhouse.PilgrimJournal.debug` 둘 다 받는다(Apple 토큰 검증, AASA,
APNs topic, StoreKit 검증 모두).

### 인증

1. 앱이 "그룹 시작하기"에서 **nonce를 붙인 Apple 인증을 새로 받는다.** 기록장 로그인 때의 identityToken은
   저장하지 않고, 이미 로그인한 사용자에게는 새 토큰이 나오지 않기 때문이다. 인증한 Apple 사용자가 기록장
   세션 사용자와 다르면 앱이 거부한다.
2. 앱이 `identityToken`, `authorizationCode`, `rawNonce`, `bundleId`를 `POST /api/v1/auth/apple`로 보낸다.
3. 서버가 Apple 공개 키(JWKS)로 `identityToken`을 검증하고(iss, aud = 두 번들 중 하나, exp, nonce),
   `authorizationCode`를 Apple 토큰 엔드포인트에서 교환해 **refresh token을 암호화해 보관**한다
   — 계정 삭제 때 `/auth/revoke`로 Apple 연결을 서버가 직접 끊기 위해서다(5.1.1(v) 반려 이력). 교환이 실패하면
   로그인도 실패시킨다.
4. 서버는 자체 access JWT(15분)와 refresh token(90일, 쓸 때마다 회전, 해시 저장, 재사용 감지 시 그 세션 계열
   전체 폐기)을 발급한다. 앱은 `ThisDeviceOnly` Keychain에 둔다.
5. 가입: 이름(그룹 표시 이름)과 프로필 사진(선택). 구독이 켜진 서버라면 구독 화면으로 이어진다.
6. 기기 등록: APNs device token, 환경(sandbox/production), 번들 ID, 시간대(Daily Report용), 앱 언어.
7. 개발 로그인(`auth/dev`)은 개발 설정에서만 열리고, 운영 설정에서 켜져 있으면 서버가 시작을 거부한다.

### 구독 (만들되 출시 때 끈다)

- 결제는 기기에서 StoreKit 2, 월간 구독 `com.dhouse.PilgrimJournal.groups.monthly`($1.99 / ₩2,000 가격 단계).
  앱이 서명된 거래(JWS)를 `POST /api/v1/subscriptions/verify`로 보내면 서버가 Apple 루트 인증서로 검증한다
  (Apple 공식 `app-store-server-library-swift`).
- App Store Server Notifications V2를 `/api/appstore/notifications`로 받아 갱신·만료·환불을 반영한다.
- 서버 설정 **`SUBSCRIPTION_REQUIRED`** (출시 때 `false`):
  - `false`: 모두 쓸 수 있다. 앱은 구독 화면을 띄우지 않는다. 만료 처리도 하지 않는다.
  - `true`: 그룹 API를 매 요청 서버 DB 기준으로 구독자에게만 연다 — CloudKit 검토에서 "약화"였던 구독자
    전용 가입이 여기서 **유지**가 된다. 초대 링크를 연 비구독자에게는 구독 화면을 보인다. 구독이 만료되면
    로드맵 결정대로 그 사람을 그룹에서 빼고 그 사람이 올린 내용을 지운다(스크랩은 남는다). 이 처리는
    `true`일 때만 동작한다.

### 데이터 (Postgres)

열·타입·인덱스·cascade는 `design.md` "Postgres 스키마"에 있다. 묶음만 적는다.

| 묶음 | 테이블 |
| --- | --- |
| 계정 | `users`(Apple `sub`, 표시 이름, 프로필 사진, 시간대, Daily Report 시각, 정지), `apple_tokens`(암호화), `apple_token_revocations`(계정 삭제 뒤 폐기 재시도), `refresh_tokens`, `devices`, `subscriptions`, `appstore_notifications`(웹훅 중복 거르기) |
| 그룹 | `groups`(상태: 정상·투표 중·삭제 예정, `delete_at`, 관리자는 nullable), `memberships`(읽음 시각, 그룹별 알림), `group_bans`(강퇴), `invites`(코드, 최대 인원, 사용 수, 만료, 취소), `admin_votes`(라운드, 후보, 마감), `ballots` |
| 콘텐츠 | `posts`(종류, 제목, 본문, 기도 항목 jsonb, 책 정보, 데드라인, 시간대, `expires_at`), `post_extensions`, `comments`, `reactions`(이모지 또는 스티커), `stickers`, `media`(사진 메타데이터와 파일 경로), `media_file_deletions`(행이 지워질 때 트리거가 파일 삭제를 예약) |
| 안전 | `hides`(글·사람), `blocks`, `reports`(신고 시점 스냅샷, 90일), `moderation_log` |
| 작업 | `push_outbox`, `daily_report_log`, `worker_heartbeat` |

일기 원문은 서버로 오지 않는다. 오는 것은 주인이 승인한 카드와 그룹 활동뿐이다.
스크랩은 각자의 iCloud(기록장)로 복사하고 서버에는 남기지 않는다.

### 기한

| 카드 | 공개 기간 |
| --- | --- |
| 기도제목, 데드라인 있음 | 그날 끝(올린 사람 시간대) + 3일 |
| 기도제목, 데드라인 없음 | 기본 7일(3·7·14·30일 중 선택) |
| 독후감 | 7일. 토론 연장은 현재 기한에 7일을 더함(누구나, 무제한) |
| 간증 | 7일 |

작성자는 언제든 먼저 내린다. 모든 조회가 기한이 지난 글을 거르고, worker가 실제로 지운다.

### 사진

- 앱이 압축해서 올린다(긴 변 1600px, JPEG 0.7, 장당 최대 500KB, EXIF·GPS 제거,
  글·댓글당 최대 4장). 프로필 사진도 같은 기준. 서버도 크기·형식을 다시 검사하고 메타데이터를 한 번 더
  지운다(디코딩 없이 JPEG 세그먼트를 다시 쓴다). 썸네일은 만들지 않는다.
- 저장은 맥미니의 Docker 볼륨(파일)로 시작하고, 내려받기는 API가 그룹 멤버인지
  확인한 뒤 짧게(10분) 유효한 서명 URL로 준다. 글이 사라질 때 사진 파일도 함께 지운다 — 사진 행이 어떤
  이유로 지워지든 DB 트리거가 파일 삭제를 예약하고 worker가 지운다.

### 그룹 스티커

- 멤버가 사진을 정사각형으로 잘라 만든다(256px, 100KB 이하, 같은 업로드 경로). 그룹당 최대 30개.
- 그 그룹 안에서 모두가 반응과 댓글에 쓴다. 만든 사람과 관리자가 지울 수 있고, 지우면 그 스티커로 한 반응도
  지워진다. 그룹이 지워지면 스티커도 지워진다.

### 숨김·차단·신고

- 숨김(글 단위·사람 단위)은 내 화면에만 적용되지만 서버에 저장해 내 기기끼리 맞춘다.
- 차단은 양방향이다. 서로의 글·댓글·반응을 보지 않고 푸시도 막는다.
- 신고는 신고 시점의 본문 스냅샷을 저장하고 90일 뒤 지운다.

### 알림

- **새 글:** 글을 저장하는 트랜잭션에서 `push_outbox`에 넣고 worker가 5초마다 APNs로 보낸다. 문구는
  `loc-key`로 앱이 만들고, 기도 내용은 잠금화면에 싣지 않는다. 차단·숨긴 사람, 알림을 끈 멤버에게는 보내지
  않는다. 댓글은 바로 보내지 않는다(로드맵 결정).
- **Daily Report:** 사용자 시간대 기준 22:00(설정에서 변경)에 그 시각까지 24시간의 댓글·반응·연장·새 글과
  곧 사라지는 글을 모아 한 번 보낸다. 보낼 게 없으면 보내지 않는다. `GET /api/v1/me/daily-report`가 같은
  내용을 앱 화면용으로 준다.

### worker (예약 작업)

"누가 요청하지 않아도 시간이 되면 서버가 알아서 해야 하는 일"을 맡는다. API와 같은
코드·같은 Docker 이미지를 쓰고, 실행 명령만 다른 별도 컨테이너로 띄운다(`Run worker`). 따로 두는 이유:
무거운 일(사진 정리, 대량 알림)이 API 응답을 느리게 하지 않고, API를 다시 시작해도 예약 작업이 끊기지
않으며, 둘 중 하나가 죽어도 다른 하나는 산다.

**큐 라이브러리 없이 polling 루프로 한다(2026-11-14 결정).** 할 일은 전부 Postgres 행(`expires_at`,
`ends_at`, `push_outbox` 등)에 이미 있으므로, 루프마다 "지금 처리할 행"을 골라 한 트랜잭션으로 처리하면 된다.
`vapor/queues`는 Postgres 드라이버가 마땅치 않아 Redis를 하나 더 띄워야 했다. 루프마다
`pg_try_advisory_lock`을 잡아 worker가 둘 떠도 같은 일을 두 번 하지 않고, heartbeat를 남긴다.

| 루프 | 간격 | 하는 일 |
| --- | --- | --- |
| 푸시 outbox | 5초 | APNs 발송, 잘못된 토큰 정리, 재시도 |
| 기한 삭제 | 60초 | 기한이 지난 글 → 글·댓글·반응·사진 삭제 |
| 사진 파일 | 60초 | 지워진 사진 행의 파일 삭제, 24시간 동안 어디에도 안 붙은 업로드 삭제 |
| 투표 | 60초 | 마감(3일) → 동률이면 재투표(1일) → 또 동률이면 무작위 → 아무도 안 했으면 1주 유예 후 그룹 삭제 |
| Daily Report | 60초 | 리포트 시각이 지난 사용자 집계·발송 |
| Apple 토큰 폐기 | 5분 | 계정 삭제한 사용자의 Apple 토큰 `/auth/revoke` 재시도 |
| 구독 | 10분 | `SUBSCRIPTION_REQUIRED=true`일 때만: 만료 반영, 웹훅을 놓쳤을 때를 대비한 재확인 |
| 정리 | 1시간 | 오래된 초대·신고(90일)·보낸 알림·리포트 기록·토큰 삭제 |

개발과 테스트에서는 `TIME_SCALE_DAY_SECONDS`로 "하루"를 몇 초로 줄여 기한·투표·유예·초대 만료를 확인한다.

### 운영자 도구 (App Review 1.2 대응)

신고가 오면 운영자(개발자)가 내용을 보고 지우거나 사용자를 막을 수 있어야 한다.
자체 서버라 가능해진다. **기존 관리자 콘솔(`web/admin`)에 "신고" 페이지를 더하고, 서버는 터널에 노출하지
않는 내부 라우트를 둔다(2026-11-14 결정).** 처음 안이었던 별도 호스트 `pilgrim-admin.delight-house.org` +
Cloudflare Access는 쓰지 않는다 — 콘솔이 이미 같은 호스트에서 로그인·세션·rate limit을 갖고 있고, 운영자
화면을 두 군데 둘 이유가 없다.

- 서버 `/internal/admin/v1/*`: 공유 Docker 네트워크로만 닿는다. `X-Admin-Token`(콘솔 `.env`와 서버
  `.env.prod`에만)을 요구하고, `Cf-Ray` 헤더가 붙은 요청은 거부한다.
- 콘솔 "신고" 페이지: 신고 목록·스냅샷·원본, 글·댓글·스티커 삭제, 사용자 정지·해제, 처리 완료.
  모든 운영자 조치는 기록(`moderation_log`)으로 남긴다.
- 새 신고는 `REPORT_WEBHOOK_URL`로 알린다(선택, 본문 없이).
- 콘솔이 사용자 데이터(신고 내용)를 다루게 되므로 `docs/privacy.md`에 적는다.

## 맥미니 운영

- **항상 켜두기**: 잠자기 끔, 정전 후 자동 켜기, 로그인 시 Docker Desktop 자동 시작,
  `cloudflared`는 launchd 서비스. compose 서비스는 `restart: always`.
- **집 한 대라는 한계 (받아들임, 2026-11-03)**: 정전·인터넷 장애·맥 업데이트 재시작
  동안 그룹 기능이 멈춘다. 기록장(로컬 + iCloud)은 영향이 없어야 한다 — 앱은 서버가
  안 될 때 "그룹 서버에 연결할 수 없어요"를 보여주고 작성 중인 카드를 잃지 않게 한다.
  Docker 구성을 유지하므로 사용자가 늘면 클라우드로 옮길 수 있다. macOS 업데이트는
  자동 설치를 끄고 사용자가 적은 시간에 직접 한다.
- **감시**: `/api/health`(DB 연결과 worker heartbeat 포함)를 외부에서 확인(Cloudflare 상태 알림이나
  healthchecks.io 같은 서비스).
- **백업**: 매일 `pg_dump` + 사진 볼륨. 보관은 7일. 맥미니 한 대에만 있으면 디스크
  고장 때 다 잃으므로 암호화해서 Cloudflare R2에 한 벌 더 둔다(아래 "백업 사본 위치").
  글이 기한 후 지워져도 백업에는 최대 보관 기간만큼 남는다는 점을 개인정보
  처리방침에 적는다.
- **보안**: Postgres는 외부에 열지 않는다. API는 `127.0.0.1`과 공유 Docker 네트워크에만 연다. Cloudflare에서
  레이트 리밋·봇 차단 규칙(`/api`, `/.well-known`은 예외), API에서도 사용자별 레이트 리밋. 비밀 값(Sign in
  with Apple 키 `.p8`, APNs 키, In-App Purchase 키, JWT 비밀, Apple 토큰 암호화 키, 사진 URL 서명 키, 관리자
  토큰, DB 비밀번호)은 `server/.env.prod`에만 두고 저장소에 넣지 않는다. 맥미니는 FileVault 사용.

## 앱 쪽

- 새 라이브러리 `Sources/JournalGroups/`: API 클라이언트, 세션·토큰 갱신, 그룹 상태, 사진 압축(ImageIO),
  업로드. 기존 `JournalData`(SwiftData + CloudKit)와 섞지 않는다. 화면은 `Sources/PilgrimJournal/Groups/`.
- 사이드바에 "그룹" 섹션(가족 공유의 공유 공간 섹션과 같은 방식). `GroupsFeature.isEnabled`로 켜고 끈다 —
  Release는 서버 운영이 시작될 때까지 끈다.
- 계정 삭제(`AccountDeletionService`)에 서버 쪽 삭제를 **가장 먼저** 더한다: 서버 계정·내 글·댓글·
  사진·스티커·기기 토큰 삭제 + Apple 토큰 폐기. 그룹 관리자였으면 위임 투표로 넘어간다. 실패하면 로컬 삭제
  전에 멈춘다.
- 스크랩은 기존 기록·첨부 모델만 쓴다(새 기본 유형 "스크랩"과 노트북 "스크랩 · <그룹 이름>"). CloudKit
  스키마 변경이 없다는 확인은 `design.md` 15절.
- 서버 주소는 빌드 설정으로(개발: 로컬 Docker, 운영: `pilgrim.delight-house.org`).

## 개인정보 경계 변경

`docs/privacy.md`의 "자체 기록 서버를 사용하지 않는다"가 바뀐다. 함께 적을 것:

- 서버(집의 맥미니, 운영자 관리)에 저장되는 것: Apple 사용자 식별자, 그룹 표시 이름·
  프로필 사진, 기기 알림 토큰, 시간대, 구독 상태, 그룹에 올린 카드·댓글·반응·스티커·사진, 숨김·차단 목록,
  신고 기록(스냅샷 90일).
- 저장되지 않는 것: 일기 원문, 기록장 데이터, 스크랩.
- 스크랩하면 다른 멤버가 쓴 글·댓글·사진이 내 iCloud 기록장에 복사된다.
- Cloudflare를 거친다(터널이 TLS를 Cloudflare에서 끝낸다).
- 관리자 콘솔이 신고 내용(사용자 데이터)을 보게 된다.
- 보관 기간(공개 기간 + 백업 보관 기간)과 계정 삭제 범위, 서버가 Apple 토큰을 폐기한다는 것.
- App Store 개인정보 라벨 갱신.

## 결정

| # | 항목 | 결정 |
| --- | --- | --- |
| 1 | 방향 | 개인 기록은 iCloud, 공유·SNS는 자체 서버(맥미니). PR #22의 CloudKit 검토는 기록으로 남긴다(`groups-cloudkit.md`에 "채택 안 됨" 표시, `docs/roadmap.md` 기술 방향도 #22에서 이 문서를 가리키게 고침) (2026-11-03) |
| 2 | 서버 언어 | Swift + Vapor (2026-11-03) |
| 3 | DB | Pilgrim 전용 Postgres 컨테이너 (2026-11-03) |
| 4 | 사진 저장소 | 맥미니 디스크(Docker 볼륨) (2026-11-03) |
| 5 | 주소 구조 | `pilgrim.delight-house.org`를 콘솔과 함께 쓰고 **경로로 나눈다**: `^/(api/\|i/\|\.well-known/)` → 그룹 서버 3100, 나머지 → 콘솔 8420 (2026-11-14, 처음 안 "호스트 전체를 Pilgrim 서버로"를 바꿈) |
| 6 | 암호화 | 전송 TLS + 맥미니 디스크 암호화(FileVault). 종단간 암호화는 하지 않는다 (2026-11-03) |
| 7 | 백업 사본 | 지금은 Cloudflare R2(무료 한도 안), 나중에 AWS S3 서울 리전으로 옮긴다. 아래 "백업 사본 위치" (2026-11-03) |
| 8 | 테스트 서버 | 개발 맥 로컬 Docker만 (2026-11-03) |
| 9 | 서버 코드 위치 | 이 저장소의 `server/` (Vapor 앱과 `server/PilgrimAPI` 공유 패키지) (2026-11-03) |
| 10 | 예약 작업 | 별도 worker 컨테이너(같은 이미지, 다른 실행 명령)에서 **단순 polling 루프**. `vapor/queues`·Redis 없음 (2026-11-14) |
| 11 | 운영자 도구 | 기존 콘솔(`web/admin`)의 "신고" 페이지 + 터널에 노출하지 않는 서버 내부 라우트(`X-Admin-Token`, `Cf-Ray` 거부). `pilgrim-admin` 호스트와 Cloudflare Access는 쓰지 않는다 (2026-11-14) |
| 12 | 장애 허용 | 집 맥미니 한 대의 중단을 받아들인다 (2026-11-03) |
| 13 | 범위 | 사진·그룹 스티커·위임 투표·Daily Report·스크랩·숨김까지 한 번에. 구독은 만들되 `SUBSCRIPTION_REQUIRED=false`로 끈 채 출시 (2026-11-14) |
| 14 | 번들 ID | Release·Debug 두 ID를 토큰 검증·AASA·APNs·StoreKit 모두에서 받는다 (2026-11-14) |

## 백업 사본 위치 (결정 7)

목적: 맥미니 디스크 고장·도난·침수 때 그룹 데이터를 통째로 잃지 않게, 매일 만드는
DB 덤프와 사진 백업을 맥미니 밖에 한 벌 더 둔다. 어디에 두든 **올리기 전에 암호화**하고,
복호화 키는 맥미니 밖(운영자의 암호 관리자)에도 보관한다. 보관은 최근 7일치.

**결정 (2026-11-03): 지금은 Cloudflare R2, 나중에 AWS S3 서울 리전으로 옮긴다.**

- 도구는 `restic`(암호화·중복 제거·보관 정리·복원)으로, 저장소 주소만 바꿔 끼울 수
  있게 한다. R2에는 이 버킷에만 쓸 수 있는 토큰을 따로 만든다. Cloudflare 계정에는
  2단계 인증을 건다.
- 지금 규모(하루 수십~수백 MB, 7일 보관)는 R2 무료 한도(월 10GB 저장) 안이다. 착수 때
  요금표를 다시 확인한다.
- **S3로 옮기는 시점**(하나라도 해당하면): 백업이 무료 한도를 넘을 때, 국내 보관이
  필요해질 때(개인정보 처리방침의 해외 이전 설명 단순화), 백업을 못 지우게 잠그는
  Object Lock이 필요할 때, 서버를 AWS로 옮길 때.
- **옮기는 방법**: S3 서울 리전 버킷·업로드 전용 IAM 사용자·예산 알림을 만들고, 1주일 동안
  양쪽에 함께 올린 뒤 R2를 끈다(보관이 7일이라 예전 백업을 옮길 필요가 없다). R2에서
  내려받는 요금이 없어 옮기는 비용은 0원이다. 바꾸면 개인정보 처리방침의 백업 보관
  업체·국가를 고친다.

아래는 고를 때 비교한 내용이다.

| | 운영자 본인 iCloud Drive | Cloudflare R2 | 사용자들의 iCloud |
| --- | --- | --- | --- |
| 방식 | 맥미니의 iCloud Drive 폴더에 파일을 넣으면 macOS가 알아서 올림 | S3 호환 API로 직접 업로드(`rclone` 등) | 각 사용자 앱이 자기 그룹 데이터를 자기 iCloud에 저장 |
| 비용 | 쓰고 있는 iCloud 용량 안이면 0원 | 무료 한도(월 10GB 저장) 안이면 사실상 0원, 넘으면 GB당 소액. 착수 때 요금표 확인 | 사용자 용량을 씀 |
| 업로드 확인 | 어려움 — 올라갔는지 명령으로 확인할 방법이 마땅치 않고, 동기화가 멈춰도 조용함 | 쉬움 — 업로드 성공·실패가 바로 나와 실패 알림을 붙일 수 있음 | 해당 없음 |
| 복원 | 같은 Apple ID로 로그인한 맥에서 내려받기 | 어디서든 키로 내려받기 | **불가능에 가까움** — 서버는 사용자 iCloud를 읽을 수 없고, 모든 멤버 앱이 다시 올려야 함 |
| 담기는 것 | 전부(계정·구독 연결·그룹·관리자·투표·글·사진) | 전부 | 각자 볼 수 있던 글뿐. 계정·구독·관리자·투표 상태는 없음 |
| 개인정보 | 운영자 Apple 계정에 암호화된 사본 | Cloudflare에 암호화된 사본 | 기한 지나 서버에서 지운 남의 글이 각자의 iCloud에 계속 남음 → "스크랩한 것만 남는다" 결정과 어긋남 |
| 기타 | 새 계정 필요 없음. 개인 Apple ID와 섞이지 않게 폴더 분리 | 이미 Cloudflare(DNS·터널)를 씀. 업로드 전용 권한 토큰 발급 가능. 한 업체에 집중되는 점은 단점 | — |

- 사용자들의 iCloud는 백업 장소로 맞지 않는다(복원 불가, 삭제 정책과 충돌).
- 운영자 iCloud Drive는 업로드가 실제로 됐는지 확인하기 어렵고, 맥이 아닌 서버로
  옮기면 쓸 수 없으며, 개인 계정과 서비스 데이터가 섞인다.
- AWS S3(서울)는 업체 분산·국내 보관·Object Lock이 장점이고 월 몇백 원과 설정 부담이
  든다. 그래서 무료인 R2로 시작하고 필요해지면 S3로 옮긴다.
- 한 달에 한 번 개발 맥에서 최신 사본을 로컬 Docker에 복원해 본다.
- 개인정보 처리방침에 "서버 백업은 암호화되어 Cloudflare R2에 최대 7일 보관된다"를 적는다.

## 작업 순서

작업 단위(T0.1~T0.4, S1~S8, A1~A8, I1, W1, D1, Phase 2)와 각 작업이 맡는 파일은
`openspec/changes/add-private-groups/tasks.md`에 있다. 큰 흐름:

1. 계약(openspec 스펙 → `PilgrimAPI` DTO·규칙 → 앱·서버 뼈대).
2. 서버(인증·그룹·글·안전·worker → 사진·Daily Report·구독)와 앱(클라이언트·화면 → 올리기·계정 삭제·스크랩·
   알림·구독)을 병렬로. 앱 화면은 `PreviewGroupAPI`로 서버를 기다리지 않는다.
3. 인프라(compose·백업·entitlement), 콘솔 신고 페이지, 문서(`privacy.md` 등).
4. 통합: 현지화, 실제 클라이언트 연결, 맥미니 배포와 터널 경로 규칙, 실기기 확인. main에는 서버·CI 먼저,
   앱은 Release에서 그룹 기능을 끈 채로 합친다. entitlement 변경은 1.2.0 출시 뒤.
