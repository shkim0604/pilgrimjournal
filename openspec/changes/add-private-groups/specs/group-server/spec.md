## ADDED Requirements

### Requirement: 공개 경로와 터널 경계
시스템은 Cloudflare Tunnel로 `^/(api/|i/|\.well-known/)` 경로만 그룹 서버(3100)로 받아야 하며(MUST), 나머지 경로는
기존 관리자 콘솔(8420)이 받아야 한다(MUST). 그룹 서버는 `127.0.0.1`과 내부 Docker 네트워크에만 열어야 하고(MUST)
Postgres는 외부에 열어서는 안 된다(MUST NOT). `GET /api/health`는 DB 연결과 worker heartbeat 상태를 돌려줘야
한다(MUST).

#### Scenario: 콘솔과 API가 같은 호스트
- **WHEN** 인터넷에서 `https://pilgrim.delight-house.org/admin`과 `/api/health`를 요청한다
- **THEN** `/admin`은 콘솔이, `/api/health`는 그룹 서버가 응답한다

#### Scenario: worker가 멈춤
- **WHEN** worker heartbeat가 2분 넘게 갱신되지 않았다
- **THEN** `/api/health`가 `status: "degraded"`, `worker.healthy: false`를 돌려준다

### Requirement: 클라이언트 식별과 버전 차단
시스템은 `/api/v1/*` 요청마다 `X-Pilgrim-Client` 헤더를 검사해야 한다(MUST). 헤더가 없거나 형식이 틀리거나 버전이
`MIN_CLIENT_VERSION`보다 낮으면 426 `CLIENT_UPGRADE_REQUIRED`를 돌려줘야 한다(MUST). 번들 ID는
`com.dhouse.PilgrimJournal`과 `com.dhouse.PilgrimJournal.debug`만 받아야 한다(MUST).

#### Scenario: 오래된 앱
- **WHEN** `MIN_CLIENT_VERSION=1.3.0`인 서버에 `ios/1.2.9 (30) com.dhouse.PilgrimJournal`이 요청한다
- **THEN** 서버는 426과 `CLIENT_UPGRADE_REQUIRED`를 돌려준다

### Requirement: Apple 로그인 검증
시스템은 identityToken을 Apple JWKS로 검증하고 `iss`, `exp`, `aud`(요청한 bundleId이며 두 번들 ID 중 하나),
`nonce == SHA256(rawNonce)`를 확인해야 한다(MUST). authorizationCode를 같은 bundleId로 교환하고 받은 Apple refresh
token을 암호화해 저장해야 하며(MUST), 교환이 실패하면 로그인도 실패시켜야 한다(MUST). Apple 토큰을 평문으로
저장하거나 로그에 남겨서는 안 된다(MUST NOT).

#### Scenario: Debug 번들의 로그인
- **WHEN** `aud = com.dhouse.PilgrimJournal.debug`인 토큰과 같은 bundleId로 로그인한다
- **THEN** 서버는 검증을 통과시키고 Debug 번들의 client secret으로 code를 교환한다

#### Scenario: nonce가 다름
- **WHEN** identityToken의 `nonce`가 보낸 rawNonce의 해시와 다르다
- **THEN** 서버는 401 `APPLE_NONCE_MISMATCH`를 돌려주고 사용자를 만들지 않는다

### Requirement: 세션 토큰
시스템은 15분짜리 access JWT와 90일짜리 회전 refresh token을 발급해야 한다(MUST). refresh token은 해시로만
저장해야 하고(MUST), 한 번 쓴 refresh token이 다시 오면 그 family 전체를 폐기하고 `REFRESH_TOKEN_REUSED`를
돌려줘야 한다(MUST). 단, 같은 기기에서 30초 안에 오고 대신 발급한 토큰이 아직 쓰이지 않았으면 다시 회전해야
한다(MUST).

#### Scenario: 탈취된 refresh token
- **WHEN** 이미 회전된 refresh token이 다른 기기에서 쓰인다
- **THEN** 서버는 그 family의 모든 refresh token을 폐기하고 401 `REFRESH_TOKEN_REUSED`를 돌려준다

#### Scenario: 응답을 못 받은 재시도
- **WHEN** 같은 `installationId`가 10초 뒤 같은 refresh token을 다시 보낸다
- **THEN** 서버는 아직 쓰이지 않은 새 토큰을 폐기하고 다른 새 토큰을 발급한다

### Requirement: 개발 로그인
시스템은 `DEV_LOGIN_ENABLED=true`일 때만 `POST /api/v1/auth/dev`를 등록해야 한다(MUST). `APP_ENV=production`에서
이 설정이 켜져 있으면 시작을 거부해야 한다(MUST).

#### Scenario: 운영 설정 실수
- **WHEN** `APP_ENV=production`, `DEV_LOGIN_ENABLED=true`로 서버를 시작한다
- **THEN** 서버는 오류를 남기고 시작하지 않는다

### Requirement: 가입 정보와 정지
시스템은 표시 이름이 없는 사용자의 그룹 API 요청을 403 `SIGNUP_REQUIRED`로 막아야 한다(MUST). 정지된 사용자는 내
정보 조회, 계정 삭제, 로그아웃, 기기 삭제 외의 요청에서 403 `ACCOUNT_SUSPENDED`를 받아야 한다(MUST). 시간대와
Daily Report 시각은 사용자가 바꿀 수 있어야 한다(MUST).

#### Scenario: 가입 전 그룹 만들기
- **WHEN** 이름을 저장하지 않은 사용자가 `POST /groups`를 보낸다
- **THEN** 서버는 403 `SIGNUP_REQUIRED`를 돌려준다

### Requirement: 계정 삭제
시스템은 `DELETE /api/v1/me`에서 사용자의 서버 데이터(멤버십, 글, 댓글, 반응, 스티커, 사진 파일, 기기 토큰, 세션,
구독 행, 숨김, 차단, 투표, 알림 대기열)를 한 트랜잭션으로 지워야 한다(MUST). 관리자였던 그룹은 위임 투표를
시작해야 하고(MUST), Apple refresh token은 폐기 대기열로 옮겨 재시도해야 한다(MUST). 이미 지워진 사용자의 삭제
요청에는 성공(`alreadyDeleted`)으로 답해야 한다(MUST).

#### Scenario: 관리자의 계정 삭제
- **WHEN** 멤버 5명 그룹의 관리자가 계정을 삭제한다
- **THEN** 그 사용자의 글·사진이 사라지고, 그룹은 남은 4명을 후보로 3일 투표 상태가 되며 멤버들에게 알림이 간다

#### Scenario: 두 번 삭제
- **WHEN** 삭제가 끝난 뒤 앱이 응답을 못 받아 같은 access token으로 다시 요청한다
- **THEN** 서버는 200 `alreadyDeleted: true`를 돌려준다

### Requirement: 멤버만 보는 그룹
시스템은 그룹, 그 그룹의 글·댓글·반응·스티커·사진을 멤버에게만 보여야 하며(MUST), 멤버가 아닌 사용자에게는 존재
여부를 드러내지 않고 404 `NOT_FOUND`를 돌려줘야 한다(MUST). 사진 파일은 멤버 확인 뒤 발급한 짧은(10분) 서명 URL로만
내려줘야 한다(MUST).

#### Scenario: 다른 그룹의 글 ID
- **WHEN** 멤버가 아닌 사용자가 다른 그룹 글의 ID로 `GET /posts/:id`를 보낸다
- **THEN** 서버는 404 `NOT_FOUND`를 돌려준다

#### Scenario: 만료된 사진 URL
- **WHEN** 발급 10분 뒤 서명 URL로 사진을 요청한다
- **THEN** 서버는 403을 돌려주고, 앱은 `GET /media/:id`로 새 URL을 받는다

### Requirement: 그룹 관리 권한
시스템은 그룹을 만든 사람을 관리자로 두어야 한다(MUST). 그룹 이름 변경, 초대 만들기·취소, 강퇴·강퇴 해제, 관리자
넘기기, 그룹 삭제, 다른 사람 글·댓글 삭제는 관리자만 할 수 있어야 한다(MUST). 강퇴된 사람의 글·댓글은 남겨야
하고(MUST), 강퇴된 사람은 관리자가 풀기 전까지 다시 들어올 수 없어야 한다(MUST). 관리자의 그룹 삭제는 7일 유예 뒤
실행해야 한다(MUST).

#### Scenario: 강퇴된 사람의 재참여
- **WHEN** 강퇴된 사용자가 새 초대 링크로 참여하려 한다
- **THEN** 서버는 403 `REMOVED_FROM_GROUP`을 돌려주고 초대 사용 수를 늘리지 않는다

### Requirement: 초대
시스템은 12자 Crockford base32 코드로 초대를 만들고, 만든 지 3일 뒤 만료시켜야 한다(MUST). `maxUses`는 1~100이어야
한다(MUST). 수락은 한 트랜잭션의 조건부 UPDATE로 처리해 동시에 수락해도 `maxUses`를 넘지 않게 해야 한다(MUST).
투표 중이거나 삭제 예정인 그룹의 초대는 받지 않아야 한다(MUST). 이미 멤버인 사용자의 수락은 사용 수를 늘리지 않고
성공으로 답해야 한다(MUST).

#### Scenario: 동시 수락
- **WHEN** `maxUses = 1`인 초대를 두 사용자가 동시에 수락한다
- **THEN** 한 명만 멤버가 되고 다른 한 명은 409 `INVITE_FULL`을 받는다

#### Scenario: 3일 지난 초대
- **WHEN** 만든 지 3일이 지난 초대를 수락한다
- **THEN** 서버는 410 `INVITE_EXPIRED`를 돌려준다

#### Scenario: 투표 중인 그룹의 초대
- **WHEN** 위임 투표 중인 그룹의 살아 있는 초대를 수락한다
- **THEN** 서버는 409 `ADMIN_VOTE_IN_PROGRESS`를 돌려준다

### Requirement: 초대 링크 페이지와 Universal Link
시스템은 AASA에 두 앱 ID와 `/i/*`를 담아 `application/json`으로 리디렉트 없이 내려줘야 한다(MUST). `/i/:code`
페이지는 그룹 이름·인원·초대한 사람 같은 그룹 정보를 담아서는 안 되며(MUST NOT), 코드가 유효한지도 드러내서는 안
된다(MUST NOT).

#### Scenario: 앱이 없는 사람이 링크를 엶
- **WHEN** 앱이 없는 기기에서 초대 링크를 연다
- **THEN** App Store 안내와 초대 코드만 있는 페이지가 보이고 그룹 이름은 없다

### Requirement: 관리자 위임 투표
시스템은 관리자가 나가거나 계정을 삭제하면 남은 멤버 전원을 후보·투표권자로 3일 투표를 시작해야 한다(MUST). 투표
중에는 관리자가 없어야 하고 관리자 기능은 409 `ADMIN_VOTE_IN_PROGRESS`로 막아야 한다(MUST). 최다 득표가 한 명이면
관리자로 정하고, 동률이면 동률인 사람끼리 1일 재투표, 재투표도 동률이면 무작위로 정해야 한다(MUST). 아무도
투표하지 않으면 멤버에게 삭제를 알리고 1주일 유예 뒤 그룹을 지워야 한다(MUST). 관리자가 직접 넘기면 투표 없이
넘겨야 한다(MUST). 남은 멤버가 한 명이면 투표 없이 그 사람을, 없으면 그룹을 바로 지워야 한다(MUST).

#### Scenario: 동률 후 재투표
- **WHEN** 1라운드가 2:2:1로 끝난다
- **THEN** 2표인 두 사람만 후보인 1일 재투표가 열리고 멤버에게 알림이 간다

#### Scenario: 재투표도 동률
- **WHEN** 재투표가 1:1로 끝난다
- **THEN** 서버가 두 사람 중 무작위로 관리자를 정하고 결과를 알린다

#### Scenario: 아무도 투표하지 않음
- **WHEN** 1라운드 3일 동안 표가 하나도 없다
- **THEN** 그룹이 `pendingDeletion`이 되고 `delete_at = 마감 + 7일`, 그동안 읽기·스크랩만 되고 7일 뒤 지워진다

### Requirement: 글 종류와 기한 규칙
시스템은 글 종류별로 `expires_at`을 정해야 한다(MUST): 데드라인이 있는 기도제목은 올린 사람 시간대 기준 데드라인
다음 날 0시 + 3일, 데드라인이 없는 기도제목은 `visibleDays`(3·7·14·30, 기본 7)일, 독후감과 간증은 7일. 데드라인은
오늘부터 365일 이내여야 한다(MUST). 모든 조회는 `expires_at`이 지난 글과 그 댓글·반응·사진을 돌려줘서는 안 된다(MUST
NOT). 작성자는 언제든 글을 지울 수 있어야 한다(MUST).

#### Scenario: 데드라인이 있는 기도제목
- **WHEN** `Asia/Seoul` 사용자가 데드라인 2026-11-20으로 기도제목을 올린다
- **THEN** `expiresAt`은 2026-11-24T00:00+09:00이다

#### Scenario: 기한이 지난 글 조회
- **WHEN** `expires_at`이 지났지만 worker가 아직 지우지 않은 글을 조회한다
- **THEN** 서버는 404를 돌려주고 피드에도 넣지 않는다

### Requirement: 독후감 토론 연장
시스템은 멤버 누구나 독후감의 `expires_at`을 현재 값에서 7일 늘릴 수 있게 해야 하며(MUST) 횟수를 제한해서는 안
된다(MUST NOT). 독후감이 아닌 글의 연장은 422 `EXTEND_NOT_ALLOWED`로 거부해야 한다(MUST). 같은 `clientId`의
연장은 한 번만 반영해야 한다(MUST).

#### Scenario: 연장 재시도
- **WHEN** 같은 `clientId`로 연장 요청이 두 번 온다
- **THEN** `expires_at`은 7일만 늘어나고 두 번째 응답은 같은 결과를 돌려준다

### Requirement: 쓰기 멱등성
시스템은 그룹·초대·글·연장·댓글·스티커·업로드·신고를 만드는 요청을 작성자별 `clientId`로 멱등 처리해야 한다(MUST).
같은 `clientId`가 다시 오면 새로 만들지 않고 처음 만든 리소스를 돌려줘야 한다(MUST).

#### Scenario: 댓글 재전송
- **WHEN** 같은 `clientId`의 댓글 요청이 두 번 온다
- **THEN** 댓글은 하나만 있고 두 번째 응답은 200과 같은 댓글이다

### Requirement: 입력 제한과 rate limit
시스템은 design.md "제한" 표의 값을 넘는 요청을 422 `LIMIT_EXCEEDED`(필드와 한도 포함)로 거부해야 한다(MUST):
글 2,000자, 댓글 500자, 기도제목 10항목, 사진 4장, `maxUses` 1~100, 스티커 그룹당 30개 등. 사용자별(인증 전은 IP별)
rate limit을 넘으면 429 `RATE_LIMITED`와 `Retry-After`를 돌려줘야 한다(MUST).

#### Scenario: 기도제목 11줄
- **WHEN** 항목 11개인 기도제목을 올린다
- **THEN** 서버는 422 `LIMIT_EXCEEDED`, `field: "items"`, `limit: 10`을 돌려준다

### Requirement: 사진 업로드 검증과 삭제
시스템은 업로드된 사진이 JPEG이고 목적별 한도(글·댓글·프로필: 긴 변 1600px·500KB 이하, 스티커: 256×256·100KB
이하) 안인지 다시 검사해야 한다(MUST). 저장하기 전에 EXIF·GPS 등 메타데이터 세그먼트를 지워야 한다(MUST). 사진은
맥미니 Docker 볼륨에 저장하고, 어떤 이유로든 사진 행이 지워지면 파일도 지워야 한다(MUST). 24시간 동안 어디에도 붙지
않은 업로드는 지워야 한다(MUST).

#### Scenario: GPS가 남은 업로드
- **WHEN** 앱 압축을 거치지 않아 EXIF GPS가 남은 JPEG이 올라온다
- **THEN** 서버가 저장한 파일에는 APP1(EXIF) 세그먼트가 없다

#### Scenario: 글이 사라질 때 사진
- **WHEN** 사진 3장이 붙은 글이 기한이 지나 지워진다
- **THEN** 세 사진의 DB 행과 볼륨의 파일이 모두 지워진다

### Requirement: 그룹 스티커
시스템은 멤버가 그룹 안에서만 쓰는 스티커를 그룹당 30개까지 만들게 해야 한다(MUST). 스티커는 같은 그룹의 반응과
댓글에만 쓸 수 있어야 한다(MUST). 만든 사람과 관리자만 지울 수 있어야 하고(MUST), 지우면 그 스티커로 한 반응을 함께
지워야 한다(MUST). 그룹이 지워지면 스티커도 지워야 한다(MUST).

#### Scenario: 다른 그룹 스티커로 반응
- **WHEN** 그룹 A의 스티커 ID로 그룹 B의 글에 반응한다
- **THEN** 서버는 404를 돌려준다

### Requirement: 댓글과 반응
시스템은 멤버가 글에 댓글(500자, 사진 4장, 스티커 선택)과 반응(시스템 이모지 한 개 또는 그 그룹 스티커)을 달게
해야 한다(MUST). 반응은 (글, 사용자, 이모지 또는 스티커)마다 하나여야 하고 다시 보내도 늘어나서는 안 된다(MUST
NOT). 작성자와 관리자는 댓글을 지울 수 있어야 한다(MUST).

#### Scenario: 같은 반응 두 번
- **WHEN** 같은 사용자가 같은 글에 🙏 반응을 두 번 보낸다
- **THEN** 🙏 개수는 1이다

### Requirement: 차단과 숨김 필터
시스템은 차단을 양방향으로 적용해 두 사람이 서로의 글·댓글·반응을 받지 못하게 해야 한다(MUST). 글 단위 숨김과
사람 단위 숨김(모든 그룹)은 숨긴 사용자의 피드·상세·안 읽은 수·푸시·Daily Report에서 대상을 빼야 한다(MUST).
숨김과 차단은 서버에 저장해 같은 사용자의 기기끼리 맞춰야 한다(MUST). 차단 사실을 상대에게 알려서는 안 된다(MUST
NOT).

#### Scenario: 차단당한 쪽
- **WHEN** A가 B를 차단한 뒤 B가 같은 그룹 피드를 연다
- **THEN** B의 피드에 A의 글이 없고, A의 반응도 개수에서 빠진다

#### Scenario: 사람 숨김과 새 글 푸시
- **WHEN** C가 D를 사람 단위로 숨긴 뒤 D가 글을 올린다
- **THEN** C에게는 새 글 푸시가 가지 않는다

### Requirement: 신고와 운영자 처리
시스템은 신고를 받을 때 대상의 그 시점 내용(작성자, 제목, 본문, 항목, 책 정보, 사진 ID)을 스냅샷으로 저장하고 90일
뒤 지워야 한다(MUST). 운영자 라우트 `/internal/admin/v1/*`는 터널로 노출해서는 안 되며(MUST NOT), `X-Admin-Token`이
맞지 않으면 401, `Cf-Ray` 또는 `Cf-Connecting-IP` 헤더가 있으면 403으로 거부해야 한다(MUST). 글·댓글·스티커 삭제,
사용자 정지·해제, 신고 처리는 모두 `moderation_log`에 남겨야 한다(MUST). `REPORT_WEBHOOK_URL`이 있으면 새 신고를
본문 없이 알려야 한다(MUST).

#### Scenario: 터널을 거친 운영자 요청
- **WHEN** 맞는 `X-Admin-Token`과 `Cf-Ray` 헤더가 함께 붙은 요청이 운영자 라우트에 온다
- **THEN** 서버는 403을 돌려주고 아무것도 바꾸지 않는다

#### Scenario: 콘솔에서 글 삭제
- **WHEN** 운영자가 콘솔 신고 페이지에서 신고된 글을 지운다
- **THEN** 글과 사진이 지워지고 `moderation_log`에 `deletePost`, 운영자 이름, 신고 ID가 남는다

### Requirement: 새 글 푸시
시스템은 글을 저장하는 트랜잭션에서 받는 사람마다 `push_outbox`에 넣고 worker가 5초 주기로 APNs에 보내야 한다(MUST).
작성자, 그 그룹 새 글 알림을 끈 멤버, 작성자와 차단 관계인 사람, 작성자를 숨긴 사람에게는 보내서는 안 된다(MUST
NOT). 알림에는 글 제목·본문·기도 항목을 넣어서는 안 되며(MUST NOT) `loc-key`와 그룹·작성자 이름만 보내야 한다(MUST).
APNs topic은 기기의 번들 ID(두 ID 모두)여야 하고(MUST), 무효 토큰 응답을 받으면 그 토큰을 지워야 한다(MUST).
댓글·반응은 즉시 푸시하지 않아야 한다(MUST NOT).

#### Scenario: 무효 토큰
- **WHEN** APNs가 한 기기에 410 `Unregistered`를 돌려준다
- **THEN** 그 기기 행의 토큰이 지워지고 다음 알림부터 그 기기로 보내지 않는다

### Requirement: Daily Report
시스템은 사용자 시간대 기준 Daily Report 시각(기본 22:00, 사용자가 변경)에 그 시각까지 24시간의 새 글, 내 글에 달린
댓글·반응, 연장된 글, 24시간 안에 사라질 글을 모아 하루 한 번 푸시해야 한다(MUST). 모을 것이 없으면 보내서는 안
된다(MUST NOT). 같은 날 두 번 보내서는 안 된다(MUST NOT). `GET /api/v1/me/daily-report`는 같은 내용을 돌려줘야
한다(MUST). 숨김·차단과 그룹별 Daily Report 끄기를 적용해야 한다(MUST).

#### Scenario: 소식이 없는 날
- **WHEN** 22:00까지 24시간 동안 사용자의 그룹에 아무 활동도 없고 곧 사라질 글도 없다
- **THEN** 리포트 알림이 가지 않고 `daily_report_log`에 `skipped`가 남는다

#### Scenario: 시각 변경
- **WHEN** 21:00에 이미 리포트를 받은 사용자가 시각을 23:00으로 바꾼다
- **THEN** 그날은 다시 보내지 않고 다음 날부터 23:00에 보낸다

### Requirement: 구독 검증과 권한
시스템은 앱이 보낸 StoreKit 2 서명 거래(JWS)를 Apple 루트 인증서와 두 번들 ID로 검증하고 원 거래 ID로 저장해야
한다(MUST). App Store Server Notifications V2를 `/api/appstore/notifications`에서 받아 `notificationUUID`로 중복을
거르고 상태에 반영해야 한다(MUST). 다른 사용자에 묶인 거래는 409로 거부해야 한다(MUST). 서버 설정
`SUBSCRIPTION_REQUIRED`가 false면 모든 사용자를 구독 중으로 보아야 하고(MUST), true면 그룹 API를 구독 중이 아닌
사용자에게 402 `SUBSCRIPTION_REQUIRED`로 막아야 한다(MUST). 인증, 내 정보, 구독 검증, 계정 삭제는 언제나 허용해야
한다(MUST).

#### Scenario: 출시 상태
- **WHEN** `SUBSCRIPTION_REQUIRED=false`인 서버에 구독하지 않은 사용자가 그룹을 만든다
- **THEN** 그룹이 만들어지고 `GET /me/entitlement`는 `subscriptionRequired: false, active: true`다

#### Scenario: 구독 필요 상태의 비구독자
- **WHEN** `SUBSCRIPTION_REQUIRED=true`인 서버에 구독하지 않은 사용자가 글을 올린다
- **THEN** 서버는 402 `SUBSCRIPTION_REQUIRED`를 돌려준다

### Requirement: 구독 만료 처리
시스템은 `SUBSCRIPTION_REQUIRED`가 true일 때만 구독이 만료·환불된 사용자를 모든 그룹에서 빼고 그 사람이 올린 글·
댓글·반응·스티커·사진을 지워야 한다(MUST). 관리자였던 그룹은 위임 투표를 시작해야 한다(MUST). false일 때는 아무것도
지워서는 안 된다(MUST NOT). 한 구독의 만료 처리는 한 번만 해야 한다(MUST).

#### Scenario: 플래그가 꺼진 상태의 만료
- **WHEN** `SUBSCRIPTION_REQUIRED=false`인 동안 `EXPIRED` 알림이 온다
- **THEN** 구독 상태만 `expired`가 되고 멤버십과 글은 그대로다

#### Scenario: 플래그가 켜진 상태의 만료
- **WHEN** `SUBSCRIPTION_REQUIRED=true`인 동안 한 멤버의 구독이 `expired`가 된다
- **THEN** worker가 그 멤버를 모든 그룹에서 빼고 그 사람의 글과 사진을 지우며 처리 시각을 기록한다

### Requirement: 기한 삭제와 예약 작업
시스템은 API와 같은 이미지의 별도 worker 프로세스로 예약 작업을 돌려야 한다(MUST): 기한이 지난 글 삭제(60초),
사진 파일 정리(60초), 투표 마감·유예 삭제(60초), Daily Report(60초), 푸시 outbox(5초), Apple 토큰 폐기 재시도
(5분), 구독 확인(10분), 초대·보관 기간 정리(1시간). 루프마다 heartbeat를 남겨야 하고(MUST), 같은 루프를 두 worker가
동시에 실행해서는 안 된다(MUST NOT). 하루의 길이는 `TIME_SCALE_DAY_SECONDS`로 줄일 수 있어야 한다(MUST).

#### Scenario: 축소 모드 테스트
- **WHEN** `TIME_SCALE_DAY_SECONDS=10`으로 독후감을 올린다
- **THEN** 70초가 지나면 그 글이 조회되지 않고, 그다음 기한 삭제 루프(60초 안)에서 글과 댓글·반응·사진 행과
  파일이 지워진다

### Requirement: 서버 백업과 보관
시스템은 매일 Postgres 덤프와 사진 볼륨을 암호화해 맥미니 밖(Cloudflare R2)에 최근 7일치 보관해야 한다(MUST). 기한이
지나 지운 글도 백업에는 최대 보관 기간만큼 남는다는 것을 개인정보 처리방침에 적어야 한다(MUST). 비밀 값(Apple 키,
APNs 키, JWT 비밀, DB 비밀번호, 관리자 토큰)을 저장소에 넣어서는 안 된다(MUST NOT).

#### Scenario: 백업 확인
- **WHEN** 매일 04:00 백업 작업이 돈다
- **THEN** restic 저장소에 DB 덤프와 사진 스냅샷이 추가되고 7일보다 오래된 스냅샷은 정리된다
