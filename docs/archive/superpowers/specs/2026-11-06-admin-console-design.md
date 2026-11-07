# 개발자 관리 콘솔(`pilgrim.delight-house.org/admin`) — 설계

- 날짜: 2026-11-06
- 상태: 설계 승인됨, 스펙 검토 대기
- 브랜치: `feat/admin-console` (`main`에서 분기)

## 배경과 목표

개발자(운영자) 한 사람이 브라우저에서 Pilgrim Journal의 **구조와 상태**를 한눈에 보는
관리 콘솔을 만든다. 볼 것은 네 가지다.

1. **대시보드** — 출시 게이트 진행, 남은 할 일, 최근 커밋, 운영 콘솔 바로가기
2. **데이터베이스** — SwiftData/CloudKit 스키마(엔티티·속성·관계)
3. **아키텍처** — SwiftPM 타깃 의존 그래프와 모듈 설명
4. **앱 플로우** — 실행·인증·잠금·동기화·가져오기·계정 삭제 흐름도

### 사용자와 확정한 결정

| 질문 | 결정 |
|---|---|
| 어디서 실행하나 | 사용자의 Mac mini에서 Docker로 실행한다. 도메인 `delight-house.org`는 Cloudflare에 있고 Cloudflare Tunnel로 노출한다. |
| 무엇을 보여 주나 | 개발·운영 뷰. 사용자 기록 데이터는 보여 주지 않는다(볼 수도 없다, 아래 개인정보). |
| 초기 계정 | `admin` / `admin`. 단, 코드에 하드코딩하지 않는다. 환경 변수로 최초 1회 시드하고, 첫 로그인에서 비밀번호 변경을 강제한다. |

### 하지 않는 것 (YAGNI)

- 사용자 기록·계정·CloudKit 레코드 열람. 기록은 각 사용자의 CloudKit private DB에만 있고
  자체 서버로 모으지 않는다(`docs/privacy.md`).
- 여러 관리자, 역할·권한 체계. 계정은 하나이며 비밀번호 변경만 지원한다.
- App Store Connect API 지표(다운로드·크래시). 필요하면 별도 스펙.
- 콘솔에서 무언가를 **수정**하는 기능(공지, 문의 등). 읽기 전용 콘솔이다.

## 개인정보 경계

- 콘솔 서버는 **개발자 메타데이터만** 가진다: 스키마 스냅샷, 패키지 구조, 저장소의 추적 문서,
  커밋 제목, 관리자 계정 해시와 세션. 사용자 기록, Apple 로그인 식별자, 이메일, iCloud 정보는
  없다.
- `docs/privacy.md`의 "자체 기록 서버를 사용하지 않는다"는 그대로 유효하다. 같은 문서에
  "개발자 관리 콘솔은 사용자 데이터를 받거나 저장하지 않는다"는 한 줄을 추가한다.
- 스냅샷에는 Day One 원문이나 fixture 내용이 들어가지 않는다. 스키마와 구조만 담는다.
  `scripts/check.sh`의 개인 데이터 스캔은 그대로 둔다.

## 구성

```
web/admin/
  package.json, tsconfig.json
  Dockerfile, docker-compose.yml, .env.example
  src/
    server.ts          Hono 앱 조립, 라우팅, 정적 파일
    config.ts          환경 변수 읽기·검증
    db.ts              node:sqlite 연결, 마이그레이션
    auth/
      password.ts      scrypt 해시·검증 (crypto.scrypt, timingSafeEqual)
      bootstrap.ts     계정이 없을 때만 환경 변수로 시드
      sessions.ts      세션 발급·검증·폐기
      rateLimit.ts     로그인 실패 제한
      middleware.ts    requireSession, requirePasswordChanged, originCheck
    content/
      snapshot.ts      snapshot/*.json 읽기
      checklist.ts     pre-release-checklist.md, implementation-todo.md 파싱
      flows.ts         앱 플로우 Mermaid 정의
    views/             서버 렌더링 HTML (layout, login, change-password, 네 페이지)
  public/              CSS, 번들된 mermaid.min.js
  snapshot/            schema.json, architecture.json, commits.json (생성물, 커밋함)
  test/                node:test
Sources/AdminSnapshot/ 스냅샷 생성 Swift 실행 파일
scripts/admin-snapshot.sh
```

### 기술 선택

- **Node 24 + TypeScript**, 웹 프레임워크 **Hono**(`@hono/node-server`). 저장소는 Node 내장
  `node:sqlite`라서 네이티브 모듈 빌드가 없다. 실행은 Node의 타입 제거(`--experimental-strip-types`
  가 필요 없는 Node 24 기본 동작)로 별도 빌드 단계 없이 `.ts`를 바로 돌린다. 타입 검사는
  `tsc --noEmit`로 한다.
- 화면은 **서버 렌더링 HTML**과 작은 CSS 하나. 프런트엔드 빌드 도구가 없다. 색은 지원 페이지
  (`site/index.html`)의 토큰을 그대로 쓰고 다크 모드를 지원한다.
- 다이어그램은 **Mermaid**를 이미지에 번들해(`public/mermaid.min.js`, 버전 고정) CDN 없이 그린다.

## 배포

- `Dockerfile`: `node:24-alpine`, 비루트 사용자, `/data`에 SQLite 볼륨. 빌드 컨텍스트는 저장소
  루트이고, `web/admin`, `docs/*.md`, `site/index.html`만 복사한다(`.dockerignore`로 나머지 제외).
- `docker-compose.yml`:
  - `admin` 서비스: 포트 `127.0.0.1:8420:8420`(외부 인터페이스에 열지 않는다), `/data` 볼륨,
    `restart: unless-stopped`, `.env` 사용.
  - `cloudflared` 서비스(선택, `profiles: [tunnel]`): `TUNNEL_TOKEN`으로 터널 실행. Mac mini에
    이미 터널이 있으면 이 서비스 대신 기존 터널에 `pilgrim.delight-house.org → http://localhost:8420`
    ingress만 추가한다.
- 라우팅: `/admin/*`는 콘솔, `/`는 지원 페이지(`site/index.html`), `/healthz`는 상태 확인.
- 배포 절차(빌드·실행·터널 연결·첫 로그인)는 `docs/development.md`에 "관리 콘솔" 절로 적는다.
  Mac mini 실제 배포는 사용자가 한다. 이 작업은 로컬 Docker 실행까지 검증한다.

## 인증

### 최초 계정 시드

- 서버 시작 시 `admins` 테이블이 **비어 있을 때만** `ADMIN_BOOTSTRAP_USERNAME`,
  `ADMIN_BOOTSTRAP_PASSWORD`로 계정을 하나 만들고 `must_change_password = 1`로 둔다.
- 계정이 이미 있으면 두 변수를 무시하고 로그에 "bootstrap ignored"를 남긴다(값은 남기지 않는다).
- 테이블이 비어 있는데 두 변수가 없으면 서버는 시작을 거부한다(로그인할 방법이 없는 상태를 막는다).
- `admin`/`admin`은 `.env.example`에만 있다. 소스 코드에는 기본 사용자 이름·비밀번호 문자열이 없다.
  테스트가 이를 확인한다(`src/` 안에 bootstrap 기본값 리터럴이 없는지 검사).

### 비밀번호

- `crypto.scrypt`(N=2^15, r=8, p=1, 64바이트), 무작위 16바이트 salt. 저장 형식은
  `scrypt$N$r$p$salt$hash`(base64). 검증은 `timingSafeEqual`.
- 첫 로그인 뒤 `/admin/change-password`로만 이동할 수 있다. 다른 경로는 이곳으로 돌려보낸다.
- 새 비밀번호 규칙: 12자 이상, 사용자 이름이나 bootstrap 비밀번호와 같으면 거부.
- 변경하면 그 계정의 다른 세션을 모두 폐기하고 새 세션을 발급한다.

### 세션

- 로그인 성공 시 32바이트 무작위 토큰을 쿠키 `pilgrim_admin`으로 보낸다
  (`HttpOnly`, `Secure`, `SameSite=Strict`, `Path=/admin`). DB에는 토큰의 SHA-256만 저장한다.
- 만료: 마지막 활동 후 12시간, 최대 7일. 로그아웃은 세션 행을 지운다.
- 로컬 HTTP 개발용으로 `ADMIN_COOKIE_SECURE=false`를 둘 수 있다(기본값 true).
- Cloudflare 뒤에서는 `X-Forwarded-Proto`를 신뢰하도록 `TRUST_PROXY=true`를 둔다.

### 공격 완화

- 로그인 실패 제한: (IP, 사용자 이름)별로 15분에 5회 실패하면 15분 잠금. IP는 `TRUST_PROXY`일 때만
  `CF-Connecting-IP`를 쓴다. 상태는 SQLite에 둔다(재시작해도 유지).
- 실패 응답은 사용자 이름 존재 여부를 드러내지 않는다. 없는 사용자도 더미 해시로 scrypt를 한 번
  돌려 응답 시간을 맞춘다.
- 모든 POST는 `Origin`(없으면 `Referer`)이 `ADMIN_ORIGIN`과 같아야 한다. `SameSite=Strict`와 함께
  CSRF를 막는다.
- 보안 헤더: `Content-Security-Policy`(self만, 인라인 스크립트 없음), `X-Frame-Options: DENY`,
  `Referrer-Policy: same-origin`, `Cache-Control: no-store`(콘솔 경로).

## 데이터 경로

Linux 컨테이너는 SwiftData를 실행할 수 없으므로 macOS에서 스냅샷을 만들어 커밋한다.

### `AdminSnapshot` (Swift 실행 파일)

- 새 executable target, `JournalData`에 의존. `swift run AdminSnapshot <out-dir>`.
- `Schema(JournalContainerFactory.canonicalModels)`와 `Schema(JournalContainerFactory.localModels)`의
  `entities`에서 엔티티 이름, 속성(이름·타입·optional·unique·transformable/external storage 여부),
  관계(대상·to-many·삭제 규칙·inverse)를 읽어 `schema.json`에 저장소별로 쓴다. 정규식 파싱이
  아니라 SwiftData가 실제로 보는 스키마다.
- 스냅샷은 구조만 담는다. 엔티티 설명 문구는 콘솔 쪽 `content/`에 둔다.
- 출력은 키 정렬·안정된 순서라서 같은 모델이면 같은 바이트가 나온다.

### `scripts/admin-snapshot.sh`

- `swift run AdminSnapshot web/admin/snapshot`
- `swift package dump-package`에서 타깃 이름·종류·의존·링크 프레임워크만 뽑아 `architecture.json`
- `git log -n 30 --format=%h%x09%cI%x09%s`에서 `commits.json`

### 신선도 검사

- `scripts/check.sh`에 단계 추가: 임시 디렉터리에 `schema.json`과 `architecture.json`을 다시
  만들어 커밋된 파일과 비교하고, 다르면 "run scripts/admin-snapshot.sh" 메시지와 함께 실패한다.
  `commits.json`은 매 커밋 바뀌므로 비교하지 않는다.
- 이 검사는 CloudKit 스키마 드리프트(`docs/known-issues.md`)와 같은 종류의 실수, 즉 모델을 바꾸고
  주변 산출물을 잊는 일을 잡는다.

## 페이지

모든 페이지는 상단 내비게이션(대시보드·데이터베이스·아키텍처·앱 플로우·로그아웃)을 공유하고
375px 폭에서 가로 스크롤 없이 보인다.

### 대시보드 `/admin`

- **출시 게이트**: `docs/pre-release-checklist.md`의 최상위 체크박스 항목별 완료/미완료 수와
  미완료 항목 제목 목록.
- **남은 일**: `docs/implementation-todo.md`의 "완료" 절을 뺀 항목 수와 제목.
- **최근 커밋**: `commits.json` 상위 10개.
- **스냅샷 정보**: 생성 시각, 스키마 버전(`PilgrimJournalSchemaV1.versionIdentifier`), 엔티티 수.
- **바로가기**: CloudKit Console, App Store Connect, TestFlight, GitHub 저장소·Actions, 지원 페이지.
  URL은 상수로 둔다(비밀이 아님).
- CI 상태 카드는 `GITHUB_TOKEN`과 `GITHUB_REPO`가 있을 때만 GitHub API로 `main`의 마지막
  workflow run을 5분 캐시해 보여 준다. 없으면 카드를 숨긴다.

파서는 체크박스(`- [ ]`, `- [x]`)와 제목(`#`) 구조만 읽는다. 문서 형식이 바뀌어 아무것도 못 읽으면
빈 목록이 아니라 "파싱 실패" 경고를 띄운다.

### 데이터베이스 `/admin/database`

- 상단 경고: CloudKit 스키마는 자동 생성되지 않으므로 모델 변경 뒤 `initializeCloudKitSchema()`와
  Console 배포가 필요하다는 안내(`docs/known-issues.md` 링크 대신 요약 문구).
- 두 저장소 탭: **Canonical (CloudKit 동기화)**, **LocalAuxiliary (기기 전용)**.
- 엔티티 목록 → 엔티티별 속성 표(이름, 타입, optional, 특성)와 관계 표.
- 엔티티 사이 관계를 Mermaid `erDiagram`으로 그린다(스냅샷에서 생성).

### 아키텍처 `/admin/architecture`

- `architecture.json`으로 Mermaid `graph`를 그린다: 라이브러리·실행 파일·테스트 타깃을 모양으로
  구분, 테스트 타깃은 기본 접힘(토글).
- 모듈별 설명 카드: 역할, 의존, 핵심 타입. 문구는 `CLAUDE.md`의 아키텍처 절을 옮긴 정적 내용이며
  `content/`에 둔다. 스냅샷에 없는 타깃이 생기면 "설명 없음" 표시를 단다.
- 저장 구조 그림: Canonical store ↔ CloudKit private DB, LocalAuxiliary store, 검색 인덱스(SQLite FTS5),
  Keychain(앱 잠금, Apple 세션), iCloud KVS(노트북·유형 목록).

### 앱 플로우 `/admin/flows`

Mermaid 흐름도, 내용은 `docs/`와 소스의 현재 동작을 따른다.

1. 실행 → Apple 로그인 게이트 → 앱 잠금 → iCloud 계정 확인·identity binding → 기록 화면
   (binding 불일치 시 차단, iCloud 없음 시 local-only)
2. Day One 가져오기: ZIP 선택 → `SafeZipArchive` 추출 → `DayOneArchiveAnalyzer` → 분류 규칙 →
   draft → 저장, import audit
3. 동기화·충돌: 로컬 편집 → revision → CloudKit mirroring → `RevisionResolver`
   (timestamp → deviceID → UUID)
4. 계정 삭제: `docs/privacy.md` "계정 삭제" 다섯 단계

흐름도 정의는 `content/flows.ts`의 정적 문자열이다. 앱 동작이 바뀌면 함께 고친다는 점을
`docs/development.md` 관리 콘솔 절에 적는다.

## 오류 처리

- 스냅샷 파일이 없거나 JSON이 깨지면 해당 페이지에 "스냅샷 없음 — scripts/admin-snapshot.sh 실행"
  안내를 띄우고 다른 페이지는 정상 동작한다.
- 설정 오류(`ADMIN_ORIGIN` 누락, 빈 DB에 bootstrap 변수 없음)는 시작 시 명확한 메시지로 종료한다.
- 500 응답은 일반 오류 페이지만 보여 주고, 스택은 서버 로그에만 남긴다.

## 테스트

`web/admin/test/`, `node --test`:

- password: 해시·검증 왕복, 잘못된 비밀번호 거부, 저장 형식 파싱
- bootstrap: 빈 DB에서 시드되고 `must_change_password`가 켜짐, 계정이 있으면 무시, 변수 없으면
  시작 실패, `src/`에 기본 자격 증명 리터럴 없음
- sessions: 발급·검증·만료(유휴·최대)·로그아웃, DB에 원문 토큰이 없음
- rateLimit: 5회 실패 후 잠금, 15분 뒤 해제, 성공 시 카운터 초기화
- 라우팅(Hono `app.request`): 미로그인 시 `/admin/login`으로, 비밀번호 미변경 시
  `/admin/change-password`로, Origin 불일치 POST 거부, 변경 후 다른 세션 폐기
- checklist 파서: 저장소의 실제 두 문서를 읽어 0개가 아닌 항목이 나오는지, 형식 깨짐 시 경고
- snapshot: 커밋된 JSON을 읽어 다섯 canonical 엔티티와 세 local 엔티티가 있는지

Swift 쪽은 `AdminSnapshot` 출력이 결정적인지(두 번 실행 결과 동일) `scripts/check.sh` 신선도
검사로 확인한다.

CI: `.github/workflows/check.yml`에 `web/admin`의 `npm ci`, `tsc --noEmit`, `node --test` 잡을
추가한다. `scripts/check.sh`는 Swift 게이트이므로 Node 테스트는 넣지 않고 신선도 검사만 넣는다.

수동 검증: 로컬에서 `docker compose up`, 브라우저로 로그인(admin/admin) → 비밀번호 변경 강제 →
네 페이지 확인 → 375px 폭·다크 모드 확인.

## 추적 문서

- `docs/development.md`: "관리 콘솔" 절(스냅샷 생성, 로컬 실행, Docker, Cloudflare Tunnel, 첫 로그인)
- `docs/privacy.md`: 콘솔이 사용자 데이터를 다루지 않는다는 한 줄
- `docs/implementation-todo.md`: Mac mini 배포와 Cloudflare ingress 등록(사용자 작업)을 남은 일로 기록
- `CLAUDE.md`: Commands에 `scripts/admin-snapshot.sh`, Architecture에 `AdminSnapshot`과 `web/admin` 한 줄
