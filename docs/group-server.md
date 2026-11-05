# 그룹 서버 설계안 (맥미니 자체 호스팅)

2026-11-03 작성. 주인 요청: 그룹 기능 전용 서버를 집의 M1 맥미니에 두고
`pilgrim.delight-house.org/api`로 연다. DB와 함께 Docker로 돌린다.

**원칙(2026-11-03 확정): 개인 기록은 iCloud, 공유·SNS는 서버.** 기록장·스크랩은
지금처럼 기기 + 사용자 본인의 CloudKit private DB에 두고, 그룹에 올린 카드와 그룹
활동만 이 서버에 둔다. 이 결정으로 2026-10-21의 "그룹 저장소를 CloudKit으로"
방향(PR #22 `groups-cloudkit.md`)은 다시 **자체 서버**로 돌아온다. CloudKit 검토는
왜 서버가 필요한지에 대한 기록으로 남긴다. 기능 요구사항은 `docs/roadmap.md`를 따른다.

## 지금 맥미니에 있는 것 (2026-11-03 확인)

- SSH 이름 `delight`. Docker Desktop, Homebrew.
- **놀담 서버**가 이미 같은 방식으로 돌고 있다(`~/Developments/noldam/server`):
  Node 22 + TypeScript + Fastify + drizzle + Postgres 17(`postgres:17-alpine`),
  `docker compose -p noldam-prod`, API는 `127.0.0.1:3000`에만 열고 **Cloudflare
  Tunnel**이 공개 입구다. `https://api.delight-house.org/health`가 응답한다.
- 배포는 개발 맥에서 `make deploy`(rsync → 맥미니에서 `make prod` → `/health` 대기),
  백업은 launchd로 매일 04:00 `pg_dump`, 최근 7개 보관.
- 도메인 `delight-house.org`는 Cloudflare DNS. `pilgrim.delight-house.org`는 아직 없다.
  루트 도메인은 지금 Cloudflare 1033(터널 연결 없음)을 돌려준다.
- 확인 못 한 것: 맥미니의 `cloudflared` 설정이 로컬 `config.yml`인지 Cloudflare
  대시보드 관리형인지. 새 호스트 이름을 추가하는 방법이 이에 따라 다르다.

## 구성

```
iPhone/Mac 앱 ──HTTPS──▶ Cloudflare ──Tunnel──▶ 맥미니
                                                 ├─ cloudflared (launchd)
                                                 └─ docker compose -p pilgrim-prod
                                                     ├─ api      (127.0.0.1:3100)
                                                     ├─ worker   (스케줄 작업, APNs)
                                                     └─ postgres (내부망만)
                                                 └─ 사진 볼륨 / 백업(launchd)
API ──▶ Apple: Sign in with Apple(JWKS·토큰 폐기), App Store Server API,
           App Store Server Notifications(웹훅 수신), APNs
```

- **호스트 하나를 통째로 Pilgrim에 준다**: 터널 ingress
  `pilgrim.delight-house.org → http://localhost:3100`. API는 `/api/v1/...`에 둔다.
  같은 호스트에서
  - `/.well-known/apple-app-site-association` — 초대 링크를 앱으로 바로 여는
    Universal Link에 필요하다.
  - `/i/<초대코드>` — 앱이 없는 사람이 링크를 열었을 때 보여줄 안내 페이지
    (App Store 링크, "구독 회원만 들어올 수 있어요").
  - `/api/appstore/notifications` — App Store 구독 상태 웹훅.
- **놀담과 완전히 분리**: compose 프로젝트, Postgres 컨테이너, 볼륨, `.env.prod`,
  백업 폴더, launchd 작업 이름을 따로 둔다. 한쪽 배포·장애·복원이 다른 쪽에 번지지 않게.
- **코드 위치**: 이 저장소의 `server/`. 놀담 `server/`의 구조(Makefile, compose 3장,
  `make deploy`, `db-backup`)를 그대로 옮겨 시작한다.

## API 서버

**Swift + Vapor 4** (2026-11-03 결정). 앱과 같은 언어라 요청·응답 타입을 공유 패키지
하나로 앱과 서버가 함께 쓴다. 착수 때 각 라이브러리의 현재 버전을 확인한다.

| 용도 | 후보 |
| --- | --- |
| 웹 프레임워크 | `vapor/vapor` 4 |
| DB | `vapor/fluent` + `fluent-postgres-driver`, 마이그레이션은 Fluent migration |
| Sign in with Apple 검증 | `vapor/jwt` (Apple identity token 검증 내장) |
| 구독 검증·웹훅 | `apple/app-store-server-library-swift` (Apple 공식) |
| 푸시 | `vapor/apns` (APNSwift 기반, 토큰 인증 `.p8`) |
| 예약 작업 | `vapor/queues` 의 scheduled job (드라이버는 Postgres만 쓰도록 Fluent 기반 드라이버 검토, 아니면 Redis 추가) |
| 테스트 | `XCTVapor`/Swift Testing, DB는 테스트용 Postgres 컨테이너 |
| 공유 타입 | `PilgrimAPI` Swift 패키지(Codable 요청·응답, 오류 코드) — 앱과 서버가 함께 의존 |

Docker 이미지는 공식 `swift` 이미지로 빌드하고, 실행 단계는 작은 런타임 이미지로
나눈다(arm64, 맥미니 M1). 서버 패키지는 앱의 루트 `Package.swift`와 **분리**한다 —
Vapor 의존성이 앱 빌드에 섞이지 않게.

### 인증

1. 앱이 이미 하고 있는 Sign in with Apple에서 `identityToken`과 `authorizationCode`를
   받아 서버로 보낸다(구독 전환 = 그룹 가입 때).
2. 서버가 Apple 공개 키로 `identityToken`을 검증(놀담 `verifiers.ts`와 같은 절차,
   Vapor에서는 `vapor/jwt`)하고,
   `authorizationCode`를 Apple 토큰 엔드포인트에서 교환해 **refresh token을 보관**한다
   — 계정 삭제 때 `/auth/revoke`로 Apple 연결을 서버가 직접 끊기 위해서다. 지금은
   서버가 없어 사용자에게 해제 방법을 안내만 한다(5.1.1(v) 반려 이력).
3. 서버는 자체 access(짧게)·refresh(길게) JWT를 발급한다. refresh는 해시로 저장하고
   회전한다.
4. 기기 등록: APNs device token, 시간대(Daily Report용), 앱 언어.

### 구독

- 결제는 기기에서 StoreKit 2. 앱이 서명된 거래(JWS)를 서버로 보내면 서버가 Apple 루트
  인증서로 검증한다(Apple 공식 `app-store-server-library-swift`).
- App Store Server Notifications V2를 받아 갱신·만료·환불을 반영한다. 만료되면
  로드맵 결정대로 그 사람을 그룹에서 빼고 그 사람이 올린 내용을 지운다.
- 그룹 API는 매 요청에서 "구독 중인가"를 서버 DB 기준으로 확인한다 — CloudKit
  검토에서 "약화"였던 구독자 전용 가입이 여기서 **유지**가 된다.

### 데이터 (Postgres)

| 테이블 | 내용 |
| --- | --- |
| `users` | Apple `sub`, 표시 이름, 프로필 사진, 시간대, 생성·삭제 시각 |
| `apple_tokens` | Apple refresh token(암호화 저장), 폐기용 |
| `devices` | APNs 토큰, 플랫폼, 언어 |
| `subscriptions` | 원 거래 ID, 상태, 만료 시각, 지역 |
| `groups` | 이름, 만든 사람, 현재 관리자(없으면 공석), 상태(정상·투표 중·삭제 예정), 삭제 예정 시각 |
| `memberships` | 그룹 × 사용자, 역할, 가입 시각, 강퇴 여부 |
| `invites` | 코드, 만든 사람, 최대 인원, 사용 수, 만료(생성 + 3일), 취소 여부 |
| `posts` | 종류(기도제목·독후감·간증), 제목, 본문, 데드라인, 공개 종료 `expires_at`, 원작성자 |
| `post_extensions` | 독후감 토론 연장 기록(누가, 언제, +1주) |
| `comments`, `reactions`, `photos` | 댓글(텍스트), 이모지 반응, 압축 사진 메타데이터 |
| `hides`, `blocks` | 글 단위·사람 단위 숨김, 차단 |
| `reports` | 신고(대상, 사유, 처리 상태) |
| `admin_votes`, `ballots` | 위임 투표(3일), 재투표(1일), 결과 |

일기 원문은 서버로 오지 않는다. 오는 것은 주인이 승인한 카드와 그룹 활동뿐이다.
스크랩은 지금처럼 각자의 iCloud(기록장)로 복사하고 서버에는 남기지 않는다.

### 사진

- 앱이 압축해서 올린다(긴 변 1600px, JPEG 0.7, 장당 최대 500KB, EXIF·GPS 제거,
  최대 4장). 서버도 크기·형식을 다시 검사하고 메타데이터를 한 번 더 지운다.
- 저장은 맥미니의 Docker 볼륨(파일)로 시작하고, 내려받기는 API가 그룹 멤버인지
  확인한 뒤 짧게 유효한 서명 URL로 준다. 글이 사라질 때 사진 파일도 함께 지운다.

### worker (스케줄 작업)

"누가 요청하지 않아도 시간이 되면 서버가 알아서 해야 하는 일"을 맡는다. API와 같은
코드·같은 Docker 이미지를 쓰고, 실행 명령만 다른 별도 컨테이너로 띄운다(Vapor
Queues의 scheduled job 실행 모드). 따로 두는 이유: 무거운 일(사진 정리, 대량 알림)이
API 응답을 느리게 하지 않고, API를 다시 시작해도 예약 작업이 끊기지 않으며, 둘 중
하나가 죽어도 다른 하나는 산다. 1분마다 돌며:

- 공개 기간이 끝난 글(`expires_at` 지남) → 글·댓글·반응·사진 삭제
- 3일 지난 초대 링크 만료
- 위임 투표 마감(3일) → 동률이면 재투표(1일) → 또 동률이면 무작위 → 아무도 안 했으면
  1주 유예 후 그룹 삭제
- 구독 만료 반영(웹훅을 놓쳤을 때를 대비한 재확인)
- **Daily Report**: 사용자 시간대 기준 22:00(설정 가능)에 그날 소식을 모아 APNs 발송
- 새 글 알림은 API가 글을 받는 즉시 큐에 넣고 worker가 APNs로 보낸다. 댓글은 바로
  보내지 않고 Daily Report에 모은다(로드맵 결정).

큐는 가능하면 별도 Redis 없이 Postgres로 해결한다(위 표의 Queues 드라이버 검토).

### 운영자 도구 (App Review 1.2 대응)

신고가 오면 운영자(개발자)가 내용을 보고 지우거나 사용자를 막을 수 있어야 한다.
자체 서버라 가능해진다. **보호된 관리자 페이지**로 만든다(2026-11-03 결정).

- 주소는 앱용과 분리: `pilgrim-admin.delight-house.org`(같은 터널, 같은 서버의 관리자
  라우트만 응답).
- **Cloudflare Access**로 앞을 막는다: 운영자 이메일로 받은 일회용 코드로 로그인해야
  페이지에 닿는다. 서버도 Access가 붙여 보내는 서명 토큰(`Cf-Access-Jwt-Assertion`)을
  검증해, 터널을 우회한 요청은 관리자 라우트에서 거부한다.
- 기능: 신고 목록·처리, 글·댓글·사진 삭제, 사용자 정지, 그룹 상태, 서버·worker 상태.
  모든 운영자 조치는 기록(`moderation_log`)으로 남긴다.

## 맥미니 운영

- **항상 켜두기**: 잠자기 끔, 정전 후 자동 켜기, 로그인 시 Docker Desktop 자동 시작,
  `cloudflared`는 launchd 서비스. compose 서비스는 `restart: always`.
- **집 한 대라는 한계 (받아들임, 2026-11-03)**: 정전·인터넷 장애·맥 업데이트 재시작
  동안 그룹 기능이 멈춘다. 기록장(로컬 + iCloud)은 영향이 없어야 한다 — 앱은 서버가
  안 될 때 "그룹 서버에 연결할 수 없어요"를 보여주고 작성 중인 카드를 잃지 않게 한다.
  Docker 구성을 유지하므로 사용자가 늘면 클라우드로 옮길 수 있다. macOS 업데이트는
  자동 설치를 끄고 사용자가 적은 시간에 직접 한다.
- **감시**: `/api/health`(DB 연결 포함)를 외부에서 확인(Cloudflare 상태 알림이나
  healthchecks.io 같은 서비스), worker는 주기적으로 heartbeat를 보낸다.
- **백업**: 매일 `pg_dump` + 사진 볼륨. 보관은 7일. 맥미니 한 대에만 있으면 디스크
  고장 때 다 잃으므로 암호화해서 Cloudflare R2에 한 벌 더 둔다(아래 "백업 사본 위치").
  글이 기한 후 지워져도 백업에는 최대 보관 기간만큼 남는다는 점을 개인정보
  처리방침에 적는다.
- **보안**: Postgres는 외부에 열지 않는다. API는 `127.0.0.1`에만 연다. Cloudflare에서
  레이트 리밋·봇 차단 규칙, API에서도 사용자별 레이트 리밋. 비밀 값(Apple 키 `.p8`,
  APNs 키, JWT 비밀, DB 비밀번호)은 `server/.env.prod`에만 두고 저장소에 넣지 않는다.
  맥미니는 FileVault 사용.

## 앱 쪽

- 새 Swift 타깃(예: `JournalGroups`): API 클라이언트, 그룹 화면 상태, 카드 업로드.
  기존 `JournalData`(SwiftData + CloudKit)와 섞지 않는다.
- 계정 삭제(`AccountDeletionService`)에 서버 쪽 삭제를 더한다: 서버 계정·내 글·댓글·
  사진·기기 토큰 삭제 + Apple 토큰 폐기. 그룹을 만든 사람이면 관리자 위임 투표 흐름.
- 서버 주소는 빌드 설정으로(개발: 로컬 Docker, 운영: `pilgrim.delight-house.org`).

## 개인정보 경계 변경

`docs/privacy.md`의 "자체 기록 서버를 사용하지 않는다"가 바뀐다. 함께 적을 것:

- 서버(집의 맥미니, 운영자 관리)에 저장되는 것: Apple 사용자 식별자, 그룹 표시 이름·
  프로필 사진, 기기 알림 토큰, 구독 상태, 그룹에 올린 카드·댓글·반응·사진, 신고 기록.
- 저장되지 않는 것: 일기 원문, 기록장 데이터, 스크랩.
- Cloudflare를 거친다(터널이 TLS를 Cloudflare에서 끝낸다).
- 보관 기간(공개 기간 + 백업 보관 기간)과 계정 삭제 범위.
- App Store 개인정보 라벨 갱신.

## 결정 (2026-11-03)

| # | 항목 | 결정 |
| --- | --- | --- |
| 1 | 방향 | 개인 기록은 iCloud, 공유·SNS는 자체 서버(맥미니). PR #22의 CloudKit 검토는 기록으로 남긴다(`groups-cloudkit.md`에 "채택 안 됨" 표시, `docs/roadmap.md` 기술 방향도 #22에서 이 문서를 가리키게 고침) |
| 2 | 서버 언어 | Swift + Vapor |
| 3 | DB | Pilgrim 전용 Postgres 컨테이너 |
| 4 | 사진 저장소 | 맥미니 디스크(Docker 볼륨) |
| 5 | 주소 구조 | `pilgrim.delight-house.org` 전체를 Pilgrim 서버로(`/api`, 초대 페이지, Universal Link 파일) |
| 6 | 암호화 | 전송 TLS + 맥미니 디스크 암호화(FileVault). 종단간 암호화는 하지 않는다 |
| 7 | 백업 사본 | 지금은 Cloudflare R2(무료 한도 안), 나중에 AWS S3 서울 리전으로 옮긴다. 아래 "백업 사본 위치" |
| 8 | 테스트 서버 | 개발 맥 로컬 Docker만 |
| 9 | 서버 코드 위치 | 이 저장소의 `server/` (Vapor 앱과 `PilgrimAPI` 공유 패키지) |
| 10 | 예약 작업 | 별도 worker 컨테이너(같은 이미지, 다른 실행 명령) |
| 11 | 운영자 도구 | Cloudflare Access로 보호한 관리자 페이지(`pilgrim-admin.delight-house.org`) |
| 12 | 장애 허용 | 집 맥미니 한 대의 중단을 받아들인다 |

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

## 착수 순서 (제안)

1. `docs/privacy.md` 갱신(그룹은 자체 서버, 서버에 저장되는 것과 백업). `docs/roadmap.md`
   기술 방향은 #22에서 이미 이 문서를 가리키게 고쳤다. `privacy.md`는 출시된 앱의
   동작을 적는 문서라 서버가 실제로 생길 때 바꾼다.
2. `server/` 뼈대: Vapor 앱 + `PilgrimAPI` 공유 패키지, `/api/health`, Postgres,
   놀담과 같은 `make dev/prod/deploy` 흐름.
3. 맥미니: compose 프로젝트, 터널 ingress `pilgrim.delight-house.org`·
   `pilgrim-admin.delight-house.org`, Cloudflare Access 정책, 백업 launchd(`restic` →
   R2).
4. 인증(Sign in with Apple) + 구독 검증 + 기기 등록.
5. 그룹·초대·글·댓글·반응·사진 API, worker(기한 삭제·초대 만료·알림).
6. 앱 `JournalGroups` 타깃과 화면(디자인 시안 12개 화면 기준).
7. 신고·차단·운영자 도구, 계정 삭제 확장, 개인정보 처리방침 갱신, App Review 준비.
