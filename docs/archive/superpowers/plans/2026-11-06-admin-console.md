# 개발자 관리 콘솔 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `pilgrim.delight-house.org/admin`에서 로그인한 개발자가 대시보드·DB 스키마·아키텍처·앱 플로우를 보는 읽기 전용 콘솔을 Docker로 제공한다.

**Architecture:** `web/admin/`의 Node + Hono 서버가 SQLite(`node:sqlite`)에 관리자 계정·세션·로그인 실패만 저장하고, 화면은 서버 렌더링 HTML이다. 스키마·패키지 구조는 macOS에서 Swift 실행 파일 `AdminSnapshot`과 `scripts/admin-snapshot.sh`가 만든 JSON 스냅샷(커밋됨)에서, 진행 상황은 저장소의 추적 문서에서 읽는다. Docker 컨테이너는 Mac mini에서 Cloudflare Tunnel 뒤에 돈다.

**Tech Stack:** Node ≥22.18(로컬) / Node 24(Docker·CI), TypeScript(타입 제거 실행, `tsc --noEmit` 검사), Hono 4 + `@hono/node-server`, `node:sqlite`, `node:test`, Mermaid(로컬 번들), Swift 6.2 + SwiftData `Schema`.

**Spec:** `docs/superpowers/specs/2026-11-06-admin-console-design.md`

## Global Constraints

- 작업 위치: worktree `.claude/worktrees/admin-console`, 브랜치 `feat/admin-console`. 모든 경로는 그 루트 기준.
- 사용자 기록·Apple 식별자·이메일·iCloud 정보는 어디에도 읽거나 저장하지 않는다. 콘솔은 읽기 전용, 관리자 계정은 하나.
- `admin`/`admin` 문자열은 `web/admin/.env.example`에만 둔다. `web/admin/src/`에 기본 사용자 이름·비밀번호 리터럴 금지.
- TypeScript는 erasable syntax만(enum·namespace·parameter property 금지), import는 `.ts` 확장자를 붙인다. JSX 없음 — HTML은 `hono/html`의 `html` 태그(자동 이스케이프)로 만든다.
- 런타임 의존성은 `hono`, `@hono/node-server`, `mermaid` 셋뿐. 개발 의존성은 `typescript`, `@types/node`. 버전은 설치 시점 최신을 받고 `package-lock.json`을 커밋한다.
- 포트 `8420`, 컨테이너는 `127.0.0.1:8420:8420`으로만 공개.
- 쿠키 `pilgrim_admin`: `HttpOnly`, `Secure`(기본; `ADMIN_COOKIE_SECURE=false`일 때만 끔), `SameSite=Strict`, `Path=/admin`.
- scrypt N=2^15, r=8, p=1, keylen 64, salt 16바이트, 저장 형식 `scrypt$32768$8$1$<salt b64>$<hash b64>`. 비밀번호는 NFC 정규화 후 해시.
- 세션: 토큰 32바이트 무작위(base64url), DB에는 SHA-256 hex만. 유휴 12시간, 최대 7일.
- 로그인 실패: 키 `${ip}|${username}`, 15분 창에서 5회 실패 시 15분 잠금.
- 새 비밀번호: 12자 이상, 사용자 이름·bootstrap 비밀번호와 같으면 거부.
- 보안 헤더(모든 `/admin` 응답): `Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'`(Mermaid가 SVG 안에 인라인 style을 넣으므로 style만 `unsafe-inline`), `X-Frame-Options: DENY`, `Referrer-Policy: same-origin`, `Cache-Control: no-store`.
- UI 문구는 한국어. 색 토큰은 `site/index.html`의 `--bg --surface --ink --ink-secondary --rule --accent --accent-soft`와 다크 값 그대로. 375px 폭에서 가로 스크롤 없음.

## Review Focus

- Cloudflare Tunnel 뒤 요청: `Host`는 내부 주소일 수 있지만 브라우저 `Origin`은 `https://pilgrim.delight-house.org`다. Origin 검사는 `ADMIN_ORIGIN`과만 비교해야 통과한다 → Task 6 테스트 `accepts POST whose Origin equals ADMIN_ORIGIN regardless of Host`.
- 사용자 이름 앞뒤 공백(`"admin "`)과 macOS의 NFD 한글 비밀번호: 로그인은 사용자 이름을 trim(대소문자 구분 유지)하고 비밀번호는 NFC로 맞춰 같은 사람으로 인식해야 한다 → Task 2 `verifies NFD input against NFC hash`, Task 6 `trims username on login`.
- 비밀번호를 바꾼 뒤 `.env`에 admin/admin이 남은 채로 재시작: 비밀번호가 되돌아가면 안 된다 → Task 3 `does not reset password when admin exists`.
- 세션이 만료된 상태에서 비밀번호 변경 폼 제출: 500이 아니라 로그인 화면으로 가야 한다 → Task 6 `expired session POST redirects to login`.
- 추적 문서의 들여쓴 하위 체크박스와 체크박스가 아닌 목록: 최상위 항목만 세어야 대시보드 숫자가 문서와 맞는다 → Task 8 `counts only top-level checkboxes`.

---

### Task 1: `web/admin` 골격 — 설정과 DB

**Files:**
- Create: `web/admin/package.json`, `web/admin/tsconfig.json`, `web/admin/.gitignore`, `web/admin/src/config.ts`, `web/admin/src/db.ts`
- Modify: `scripts/check.sh:9` (ZIP 스캔에서 `./web/admin/node_modules` prune)
- Test: `web/admin/test/config.test.ts`, `web/admin/test/db.test.ts`

**Interfaces:**
- Produces:
  - `type Config = { port: number; dbPath: string; origin: string; cookieSecure: boolean; trustProxy: boolean; repoRoot: string; snapshotDir: string; bootstrap: { username: string; password: string } | null; github: { token: string; repo: string } | null }`
  - `class ConfigError extends Error`
  - `loadConfig(env: Record<string, string | undefined>, baseDir: string): Config` — env: `PORT`(8420), `ADMIN_DB_PATH`(`data/admin.sqlite`), `ADMIN_ORIGIN`(필수, 끝 `/` 제거), `ADMIN_COOKIE_SECURE`(`"false"`만 false), `TRUST_PROXY`(`"true"`만 true), `ADMIN_REPO_ROOT`(`../..`), `ADMIN_SNAPSHOT_DIR`(`snapshot`), `ADMIN_BOOTSTRAP_USERNAME`+`ADMIN_BOOTSTRAP_PASSWORD`(둘 다 있어야 객체, 하나만 있으면 ConfigError), `GITHUB_TOKEN`+`GITHUB_REPO`(둘 다 있어야 객체). 상대 경로는 `baseDir` 기준으로 resolve.
  - `openDatabase(path: string): DatabaseSync` — 상위 디렉터리 생성, `PRAGMA foreign_keys=ON`, `journal_mode=WAL`, `user_version` 기반 마이그레이션 1단계로 아래 테이블 생성:
    - `admins(id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, password_hash TEXT NOT NULL, must_change_password INTEGER NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)`
    - `sessions(token_hash TEXT PRIMARY KEY, admin_id INTEGER NOT NULL REFERENCES admins(id) ON DELETE CASCADE, created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL)`
    - `login_failures(key TEXT PRIMARY KEY, count INTEGER NOT NULL, first_failed_at INTEGER NOT NULL, locked_until INTEGER)`
    - 시각은 모두 epoch ms.

- [ ] **Step 1: 골격 파일 작성** — `package.json`: `"name": "pilgrim-admin"`, `"private": true`, `"type": "module"`, `"engines": {"node": ">=22.18"}`, scripts `start: "node src/main.ts"`, `test: "node --test --disable-warning=ExperimentalWarning test/"`, `typecheck: "tsc --noEmit"`. `tsconfig.json`: `strict`, `noEmit`, `module`/`moduleResolution` `nodenext`, `target` `es2023`, `allowImportingTsExtensions`, `verbatimModuleSyntax`, `erasableSyntaxOnly`, `types: ["node"]`, include `src`, `test`. `.gitignore`: `node_modules/`, `data/`, `.env`. 그 뒤 `npm install hono @hono/node-server mermaid` 과 `npm install -D typescript @types/node`.
- [ ] **Step 2: 실패하는 테스트 작성**
  - `config.test.ts`: `throws ConfigError when ADMIN_ORIGIN is missing`; `applies defaults` (`port === 8420`, `cookieSecure === true`, `trustProxy === false`, `dbPath === resolve(base, 'data/admin.sqlite')`, `bootstrap === null`); `strips trailing slash from origin` (`'https://x.test/'` → `'https://x.test'`); `throws when only one bootstrap variable is set`; `reads bootstrap pair`.
  - `db.test.ts`: `creates tables and sets user_version 1` (`sqlite_master`에 세 테이블, `PRAGMA user_version` = 1); `is idempotent on reopen` (같은 파일 두 번 열어도 오류 없음, 임시 디렉터리 사용).
- [ ] **Step 3: 실패 확인** — Run: `cd web/admin && npm test` / Expected: 모듈 없음으로 FAIL.
- [ ] **Step 4: `config.ts`, `db.ts` 구현.**
- [ ] **Step 5: 통과 확인** — Run: `cd web/admin && npm test && npm run typecheck` / Expected: 모두 PASS, tsc 출력 없음.
- [ ] **Step 6: `scripts/check.sh` ZIP 스캔 수정** — `find . -path './.build' -prune -o -path './web/admin/node_modules' -prune -o -type f -name '*.zip' -print`. Run: `sh -n scripts/check.sh` / Expected: 출력 없음.
- [ ] **Step 7: Commit** — `git add web/admin scripts/check.sh && git commit -m "feat(admin): scaffold console package with config and SQLite schema"`

### Task 2: 비밀번호 해시

**Files:**
- Create: `web/admin/src/auth/password.ts`
- Test: `web/admin/test/password.test.ts`

**Interfaces:**
- Produces: `hashPassword(plain: string): Promise<string>`; `verifyPassword(plain: string, stored: string): Promise<boolean>` (형식이 깨진 stored는 false, 예외 없음); `burnPasswordCheck(plain: string): Promise<void>` (없는 사용자일 때 같은 비용의 scrypt 한 번).

- [ ] **Step 1: 실패하는 테스트** — `round-trips a password`; `rejects a wrong password`; `uses the pinned format` (`/^scrypt\$32768\$8\$1\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$/`); `produces different salts for the same password`; `returns false for malformed stored value` (`'nope'`, `'scrypt$1$2'`); `verifies NFD input against NFC hash` (`hashPassword('기도'.normalize('NFC'))` 후 `verifyPassword('기도'.normalize('NFD'), h) === true`).
- [ ] **Step 2: 실패 확인** — `npm test` FAIL.
- [ ] **Step 3: 구현** — `crypto.scrypt`를 promisify, `maxmem`은 `128 * N * r * 2` 이상으로 지정, 비교는 `timingSafeEqual`.
- [ ] **Step 4: 통과 확인** — `npm test` PASS.
- [ ] **Step 5: Commit** — `feat(admin): scrypt password hashing`

### Task 3: 관리자 계정과 최초 시드

**Files:**
- Create: `web/admin/src/auth/admins.ts`, `web/admin/src/auth/bootstrap.ts`
- Test: `web/admin/test/bootstrap.test.ts`

**Interfaces:**
- Consumes: `openDatabase`, `Config['bootstrap']`, `hashPassword`.
- Produces:
  - `type Admin = { id: number; username: string; passwordHash: string; mustChangePassword: boolean }`
  - `countAdmins(db): number`; `findAdminByUsername(db, username: string): Admin | null`; `findAdminById(db, id: number): Admin | null`; `insertAdmin(db, username: string, passwordHash: string, mustChange: boolean, now: number): number`; `updateAdminPassword(db, id: number, passwordHash: string, now: number): void` (must_change_password=0으로)
  - `class BootstrapError extends Error`
  - `ensureBootstrapAdmin(db, bootstrap: Config['bootstrap'], log: (msg: string) => void, now?: number): Promise<'seeded' | 'ignored' | 'existing'>` — 계정 0개+bootstrap 있음 → 시드, `'seeded'`; 계정 있음+bootstrap 있음 → `log('bootstrap ignored: admin already exists')`, `'ignored'`; 계정 있음+bootstrap 없음 → `'existing'`; 계정 0개+bootstrap 없음 → `BootstrapError`.

- [ ] **Step 1: 실패하는 테스트** — `seeds admin with must_change_password on empty db`; `does not reset password when admin exists` (시드 → `updateAdminPassword`로 바꿈 → 같은 bootstrap으로 다시 호출 → `'ignored'`, 해시가 바뀐 값 그대로, 로그 메시지에 bootstrap 비밀번호 문자열이 없음); `throws BootstrapError on empty db without bootstrap`; `src has no default credential literals` (`src/` 아래 모든 `.ts`를 읽어 `/['"`]admin['"`]/` 매치 0건).
- [ ] **Step 2: 실패 확인.**
- [ ] **Step 3: 구현.**
- [ ] **Step 4: 통과 확인.**
- [ ] **Step 5: Commit** — `feat(admin): admin account store and env-based bootstrap seed`

### Task 4: 세션

**Files:**
- Create: `web/admin/src/auth/sessions.ts`
- Test: `web/admin/test/sessions.test.ts`

**Interfaces:**
- Consumes: `openDatabase`, `insertAdmin`.
- Produces: `SESSION_IDLE_MS = 12 * 3600_000`; `SESSION_MAX_MS = 7 * 86_400_000`; `createSession(db, adminId: number, now: number): string`; `resolveSession(db, token: string, now: number): { adminId: number; username: string; mustChangePassword: boolean } | null` (유효하면 `last_seen_at=now`로 갱신, 만료면 행 삭제 후 null); `deleteSession(db, token: string): void`; `deleteOtherSessions(db, adminId: number, keepToken: string): void`.

- [ ] **Step 1: 실패하는 테스트** — `creates and resolves a session`; `stores only the token hash` (`sessions.token_hash !== token`, 길이 64 hex); `expires after idle timeout` (`now + SESSION_IDLE_MS + 1` → null); `sliding activity extends idle but not max` (11시간마다 resolve하며 7일+1ms 시점에 null); `deleteSession logs out`; `deleteOtherSessions keeps only the given token`.
- [ ] **Step 2: 실패 확인.** **Step 3: 구현** (`randomBytes(32).toString('base64url')`, `createHash('sha256')`). **Step 4: 통과 확인.**
- [ ] **Step 5: Commit** — `feat(admin): hashed server-side sessions with idle and absolute expiry`

### Task 5: 로그인 실패 제한

**Files:**
- Create: `web/admin/src/auth/rateLimit.ts`
- Test: `web/admin/test/rateLimit.test.ts`

**Interfaces:**
- Produces: `LOGIN_WINDOW_MS = 15 * 60_000`; `LOGIN_MAX_FAILURES = 5`; `LOGIN_LOCK_MS = 15 * 60_000`; `loginKey(ip: string, username: string): string`; `isLocked(db, key: string, now: number): boolean`; `recordFailure(db, key: string, now: number): void` (창이 지났으면 count를 1로 재시작, 5회째에 `locked_until = now + LOGIN_LOCK_MS`); `clearFailures(db, key: string): void`.

- [ ] **Step 1: 실패하는 테스트** — `locks after five failures within the window`; `four failures do not lock`; `unlocks after lock period`; `failures outside the window restart the count` (4회 → 16분 후 1회 → 잠기지 않음); `clearFailures resets`; `keys differ per ip and username`.
- [ ] **Step 2~4: 실패 확인 → 구현 → 통과 확인.**
- [ ] **Step 5: Commit** — `feat(admin): persistent login failure lockout`

### Task 6: 서버, 인증 라우트, 공통 레이아웃

**Files:**
- Create: `web/admin/src/server.ts`, `web/admin/src/main.ts`, `web/admin/src/auth/middleware.ts`, `web/admin/src/views/layout.ts`, `web/admin/src/views/auth.ts`, `web/admin/public/app.css`
- Test: `web/admin/test/server.test.ts`

**Interfaces:**
- Consumes: Task 1–5 전부.
- Produces:
  - `type AppDeps = { db: DatabaseSync; config: Config; now?: () => number; fetch?: typeof fetch }`
  - `createApp(deps: AppDeps): Hono` — 라우트: `GET /healthz` → `ok`; `GET /` → `${repoRoot}/site/index.html`; `GET /admin/login`, `POST /admin/login`, `POST /admin/logout`, `GET|POST /admin/change-password`; `GET /admin/static/:file` (`app.css`, `app.js`는 `public/`, `mermaid.min.js`는 `node_modules/mermaid/dist/mermaid.min.js`; 그 외 404). 페이지 라우트는 Task 9가 `registerPages(app, deps)`로 붙인다(`server.ts`에서 호출).
  - `layout(opts: { title: string; active?: 'dashboard' | 'database' | 'architecture' | 'flows'; body: HtmlEscapedString; nav?: boolean }): HtmlEscapedString` — 내비게이션 링크 `/admin`, `/admin/database`, `/admin/architecture`, `/admin/flows`, 로그아웃 폼.
  - 미들웨어(`middleware.ts`): `securityHeaders`, `originCheck(origin)` (POST의 `Origin` 또는 `Referer`의 origin이 `config.origin`과 다르면 403), `requireSession` (쿠키 → `resolveSession`; 없으면 `/admin/login`으로 302, `c.set('session', …)`), `requirePasswordChanged` (`mustChangePassword`면 `/admin/change-password`로 302).
  - 클라이언트 IP: `trustProxy`면 `CF-Connecting-IP`, 아니면 `getConnInfo(c).remote.address`, 둘 다 없으면 `'unknown'`.
  - `main.ts`: `loadConfig(process.env, <web/admin 절대경로>)` → `openDatabase` → `ensureBootstrapAdmin` (BootstrapError/ConfigError면 메시지 출력 후 `process.exit(1)`) → `serve({ fetch: app.fetch, port, hostname: '0.0.0.0' })`.
- 로그인 흐름: username trim, 잠금이면 429 + "잠시 후 다시 시도하세요", 사용자 없음이면 `burnPasswordCheck` 후 실패 처리, 실패 메시지는 항상 "아이디 또는 비밀번호가 올바르지 않습니다." 성공 시 `clearFailures`, 쿠키 설정, `mustChangePassword`면 `/admin/change-password`, 아니면 `/admin`으로 302.
- 비밀번호 변경: 현재 비밀번호 확인, 새 비밀번호·확인 일치, Global Constraints 규칙 위반이면 400과 폼 재표시; 성공 시 `updateAdminPassword` → `deleteOtherSessions` → 기존 세션도 지우고 새 세션 발급 → `/admin`.

- [ ] **Step 1: 실패하는 테스트** (`app.request` 사용, 테스트용 `Config`는 `origin: 'https://pilgrim.test'`, `cookieSecure: true`, 임시 DB, bootstrap `tester`/`initial-pass-1`):
  - `healthz returns ok`
  - `unauthenticated /admin redirects to /admin/login`
  - `login sets HttpOnly Secure SameSite=Strict cookie on /admin path`
  - `first login redirects to change-password and blocks other pages` (`/admin` GET → 302 `/admin/change-password`)
  - `rejects new password shorter than 12, equal to username, or equal to the bootstrap password`
  - `unexpected error renders generic page without stack` (페이지 핸들러 하나가 throw하도록 만든 테스트 라우트 → 500, 본문에 `Error`·파일 경로 없음; `app.onError`가 로그에만 스택을 남김)
  - `password change revokes other sessions` (세션 두 개 → 하나로 변경 → 다른 하나로 `/admin` 접근 시 302 login)
  - `wrong password and unknown user give the same message`
  - `sixth attempt after five failures returns 429`
  - `trims username on login` (`' tester '`로 성공)
  - `rejects POST with foreign Origin` (403)
  - `accepts POST whose Origin equals ADMIN_ORIGIN regardless of Host` (`Host: localhost:8420`, `Origin: https://pilgrim.test` → 403 아님)
  - `expired session POST redirects to login` (`now`를 8일 뒤로 바꾼 뒤 `POST /admin/change-password` → 302 `/admin/login`)
  - `sets CSP and no-store on admin responses`
  - `logout clears the session`
  - `static serves mermaid and rejects unknown files` (`/admin/static/mermaid.min.js` 200, `/admin/static/../config.ts` 404)
- [ ] **Step 2: 실패 확인.**
- [ ] **Step 3: 구현** — 쿠키는 `hono/cookie`의 `setCookie`/`getCookie`/`deleteCookie`. CSS는 지원 페이지 토큰과 다크 모드 블록을 옮기고 표·카드·내비게이션 스타일을 더한다. 정적 파일은 화이트리스트 맵으로만 찾는다(경로 결합 금지).
- [ ] **Step 4: 통과 확인** — `npm test && npm run typecheck`.
- [ ] **Step 5: 수동 확인** — `cd web/admin && ADMIN_ORIGIN=http://localhost:8420 ADMIN_COOKIE_SECURE=false ADMIN_BOOTSTRAP_USERNAME=admin ADMIN_BOOTSTRAP_PASSWORD=admin npm start` 후 `curl -s localhost:8420/healthz` → `ok`. 서버를 끈다.
- [ ] **Step 6: Commit** — `feat(admin): Hono server with login, forced password change and security headers`

### Task 7: 스냅샷 생성 (`AdminSnapshot`)과 신선도 검사

**Files:**
- Create: `Sources/AdminSnapshot/main.swift`, `scripts/admin-snapshot.sh`, `web/admin/snapshot/schema.json`, `web/admin/snapshot/architecture.json`, `web/admin/snapshot/commits.json`
- Modify: `Package.swift` (executable product·target `AdminSnapshot`, 의존 `JournalData`, `swiftSettings: [swiftDataDefine]`), `scripts/check.sh` (신선도 검사)

**Interfaces:**
- Produces (Task 8이 읽는 JSON, 모든 배열은 이름순, 키 정렬 `JSONEncoder.OutputFormatting [.prettyPrinted, .sortedKeys]`):
  - `schema.json`: `{ "schemaVersion": "1.0.0", "stores": [ { "name": "Canonical", "cloudKitSynced": true, "entities": [ { "name": "JournalEntryEntity", "attributes": [ { "name", "type", "optional": Bool, "unique": Bool, "externalStorage": Bool, "transformable": Bool } ], "relationships": [ { "name", "destination", "toMany": Bool, "deleteRule": "cascade|nullify|deny|noAction", "inverse": String|null } ] } ] }, { "name": "LocalAuxiliary", "cloudKitSynced": false, … } ] }` — 시각 같은 비결정 값 없음.
  - `architecture.json`: `{ "targets": [ { "name", "kind": "library|executable|test", "dependencies": [String], "linkedFrameworks": [String] } ] }` (`dump-package`의 `regular` → `library`).
  - `commits.json`: `{ "generatedAt": ISO8601, "commits": [ { "hash", "date", "subject" } ] }` (최근 30개).
  - `scripts/admin-snapshot.sh [out-dir]` — 기본 `web/admin/snapshot`. `swift run AdminSnapshot "$out"`; `swift package dump-package | python3 -I -c …`로 `architecture.json`(키 정렬, 들여쓰기 2, 끝 줄바꿈); `git log -n 30 --format='%h%x09%cI%x09%s'`로 `commits.json`.

- [ ] **Step 1: `AdminSnapshot` 작성** — `#if PILGRIM_SWIFTDATA` 안에서 `Schema(JournalContainerFactory.canonicalModels)`/`Schema(JournalContainerFactory.localModels)`의 `entities`를 순회. 속성 타입은 `String(describing: attribute.valueType)`, optional은 `attribute.isOptional`, unique·externalStorage·transformable은 `attribute.options`에서, 관계는 `relationship.destination`, `relationship.isToOneRelationship`, `relationship.deleteRule`, `relationship.inverseName`. `schemaVersion`은 `JournalContainerFactory`에 공개 프로퍼티가 없으면 `public static let schemaVersionString = "\(PilgrimJournalSchemaV1.versionIdentifier)"`를 `JournalContainerFactory`에 추가해 쓴다. `#else`에서는 stderr에 이유를 쓰고 exit 1.
- [ ] **Step 2: 실행** — Run: `swift build && ./scripts/admin-snapshot.sh` / Expected: 세 파일 생성, `schema.json`의 Canonical에 `AttachmentEntity, ClassificationRuleEntity, EntryRevisionEntity, JournalEntryEntity, RestoreEpochEntity`, LocalAuxiliary에 `ImportItemEntity, ImportJobEntity, SourceSnapshotEntity`.
- [ ] **Step 3: 결정성 확인** — Run: `./scripts/admin-snapshot.sh "$TMPDIR/snap2" && diff web/admin/snapshot/schema.json "$TMPDIR/snap2/schema.json" && diff web/admin/snapshot/architecture.json "$TMPDIR/snap2/architecture.json"` / Expected: diff 출력 없음.
- [ ] **Step 4: `check.sh` 신선도 검사 추가** — `swift run JournalChecks` 다음에: 임시 디렉터리로 스냅샷 생성 → `schema.json`, `architecture.json`을 `cmp`로 비교 → 다르면 `관리 콘솔 스냅샷이 오래됐습니다. scripts/admin-snapshot.sh를 실행하고 커밋하세요.`를 stderr에 쓰고 exit 1. `swift format lint`가 새 Swift 파일을 통과하는지 함께 확인. Run: `./scripts/check.sh` / Expected: `Pilgrim Journal 검증 완료`. 그 뒤 `JournalSchema.swift`에 임시 속성을 넣지 말고, 대신 `schema.json`의 한 글자를 바꿔 `./scripts/check.sh`가 그 메시지로 실패하는지 확인하고 되돌린다.
- [ ] **Step 5: Xcode 빌드 확인** — Run: CLAUDE.md의 iOS unsigned `xcodebuild … build` / Expected: `BUILD SUCCEEDED`.
- [ ] **Step 6: Commit** — `feat(admin): AdminSnapshot schema/architecture export with check.sh freshness gate`

### Task 8: 콘텐츠 읽기 — 스냅샷과 추적 문서

**Files:**
- Create: `web/admin/src/content/snapshot.ts`, `web/admin/src/content/checklist.ts`
- Test: `web/admin/test/snapshot.test.ts`, `web/admin/test/checklist.test.ts`

**Interfaces:**
- Consumes: Task 7 JSON 형식, `Config.snapshotDir`, `Config.repoRoot`.
- Produces:
  - `type Loaded<T> = { ok: true; value: T } | { ok: false; error: string }`
  - `SchemaSnapshot`, `ArchitectureSnapshot`, `CommitsSnapshot` 타입(Task 7 JSON 그대로)
  - `loadSnapshot(dir: string): { schema: Loaded<SchemaSnapshot>; architecture: Loaded<ArchitectureSnapshot>; commits: Loaded<CommitsSnapshot> }` — 매 요청마다 읽지 않도록 파일 mtime 기준 캐시. 파일 없음·JSON 오류·필수 키 누락은 `ok: false`.
  - `type ChecklistItem = { title: string; done: boolean; section: string }`
  - `parseChecklist(markdown: string): Loaded<ChecklistItem[]>` — 줄 시작이 정확히 `- [ ] ` 또는 `- [x] `인 줄만(들여쓴 줄 제외). title은 첫 `**…**` 안 텍스트, 없으면 박스 뒤 텍스트에서 끝의 공백 제거. section은 직전 `## ` 제목. 항목 0개면 `ok: false, error: '체크박스 항목을 찾지 못했습니다'`.
  - `type TodoItem = { title: string }`
  - `parseTodo(markdown: string): Loaded<TodoItem[]>` — `## 대기 중` 절 안에서 줄 시작이 `- **`인 항목, title은 `**…**` 안. 절이 없거나 0개면 `ok: false`.
  - `readTrackingDocs(repoRoot: string): { checklist: Loaded<ChecklistItem[]>; todo: Loaded<TodoItem[]> }`

- [ ] **Step 1: 실패하는 테스트**
  - `checklist.test.ts`: `counts only top-level checkboxes` (픽스처 문자열: 최상위 `- [ ] **A**`, 들여쓴 `  - [ ] B`, `- [x] C`, 일반 `- D` → 항목 2개, `A` open, `C` done); `uses section heading` (`## 완료` 아래 항목의 section이 `완료`); `fails when nothing parses`; `parses the real repo docs` (`readTrackingDocs(<repo root>)`의 checklist·todo 모두 `ok`, 길이 > 0).
  - `snapshot.test.ts`: `loads committed snapshot` (Canonical 엔티티 5개, LocalAuxiliary 3개, `JournalEntryEntity` 존재, architecture에 `JournalDomain` kind `library`); `reports missing files` (빈 임시 디렉터리 → 셋 다 `ok: false`); `reports malformed JSON`.
- [ ] **Step 2~4: 실패 확인 → 구현 → 통과 확인.**
- [ ] **Step 5: Commit** — `feat(admin): snapshot loader and tracking-doc parsers`

### Task 9: 네 페이지와 다이어그램

**Files:**
- Create: `web/admin/src/pages.ts`, `web/admin/src/views/dashboard.ts`, `web/admin/src/views/database.ts`, `web/admin/src/views/architecture.ts`, `web/admin/src/views/flows.ts`, `web/admin/src/content/flows.ts`, `web/admin/src/content/modules.ts`, `web/admin/src/content/links.ts`, `web/admin/src/content/github.ts`, `web/admin/src/content/mermaid.ts`, `web/admin/public/app.js`
- Modify: `web/admin/src/server.ts` (`registerPages` 호출)
- Test: `web/admin/test/pages.test.ts`, `web/admin/test/mermaid.test.ts`

**Interfaces:**
- Consumes: `layout`, `requireSession`, `requirePasswordChanged`, `loadSnapshot`, `readTrackingDocs`, `AppDeps.fetch`.
- Produces:
  - `registerPages(app: Hono, deps: AppDeps): void` — `GET /admin`, `/admin/database`, `/admin/architecture`, `/admin/flows`, 모두 두 미들웨어 뒤.
  - `erDiagram(store: SchemaSnapshot['stores'][number]): string`, `targetGraph(arch: ArchitectureSnapshot, includeTests: boolean): string` (`content/mermaid.ts`, 라이브러리 `[(…)]`·실행 파일 `([…])`·테스트 `{{…}}` 모양; 식별자는 `[A-Za-z0-9_]`만 남긴다).
  - `FLOWS: { id: string; title: string; mermaid: string }[]` — 스펙 "앱 플로우" 네 개(`launch`, `dayone-import`, `sync`, `account-deletion`). 노드 라벨은 모두 `"…"`로 감싸고 라벨 안에 `"`를 쓰지 않는다.
  - `MODULES: Record<string, { role: string; keyTypes: string[] }>` — `CLAUDE.md` Architecture 절의 여덟 타깃(+`AdminSnapshot`) 설명.
  - `CONSOLE_LINKS: { label: string; url: string }[]` — CloudKit Console `https://icloud.developer.apple.com/dashboard/`, App Store Connect `https://appstoreconnect.apple.com/`, TestFlight `https://appstoreconnect.apple.com/apps`, GitHub 저장소·Actions(`GITHUB_REPO`가 있으면 그 저장소, 없으면 생략), 지원 페이지 `/`.
  - `latestCiRun(github: NonNullable<Config['github']>, fetchFn: typeof fetch, now: number): Promise<Loaded<{ status: string; conclusion: string | null; url: string; updatedAt: string }>>` — `GET https://api.github.com/repos/{repo}/actions/runs?branch=main&per_page=1`, 5분 메모리 캐시, 실패는 `ok: false`.
  - `public/app.js`: `mermaid.initialize({ startOnLoad: true, securityLevel: 'strict', theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'neutral' })`, 아키텍처 페이지 테스트 타깃 토글(`data-toggle-tests` 버튼이 두 그래프 `<pre class="mermaid">` 중 하나를 보이게).
- 화면 내용은 스펙 "페이지" 절을 따른다. 데이터베이스 페이지의 저장소 탭은 JS 없이 `/admin/database?store=LocalAuxiliary` 쿼리로 바꾼다(기본 Canonical). 스냅샷이나 문서가 `ok: false`인 카드는 `error`와 함께 "scripts/admin-snapshot.sh 실행" 또는 "파싱 실패" 안내를 보이고 나머지는 정상 렌더링.

- [ ] **Step 1: 실패하는 테스트**
  - `pages.test.ts` (Task 6 테스트 헬퍼로 로그인·비밀번호 변경까지 마친 쿠키 사용): `dashboard shows release gate counts` (본문에 `출시 게이트`, `미완료` 숫자, 최근 커밋 해시 하나); `dashboard hides CI card without github config`; `dashboard shows CI card with stubbed fetch` (`deps.fetch`가 `{workflow_runs:[{status:'completed',conclusion:'success',html_url:'https://github.com/x/y/actions/runs/1',updated_at:'2026-11-06T00:00:00Z'}]}` 반환 → 본문에 `success`); `database lists canonical entities and switches store by query`(`JournalEntryEntity` 포함 / `?store=LocalAuxiliary`에 `ImportJobEntity` 포함, `JournalEntryEntity` 미포함); `database shows CloudKit schema warning` (`initializeCloudKitSchema` 문자열); `architecture renders target graph and module cards` (`<pre class="mermaid">`, `JournalDomain`); `flows renders four diagrams` (`<pre class="mermaid">` 4개); `missing snapshot shows guidance instead of 500` (`snapshotDir`를 빈 디렉터리로 → 200, `scripts/admin-snapshot.sh`); `pages escape snapshot text` (엔티티 이름에 `<script>`를 넣은 임시 스냅샷 → 본문에 `&lt;script&gt;`).
  - `mermaid.test.ts`: `erDiagram includes every relationship`; `identifiers are sanitized`; `flow labels contain no inner double quotes` (`FLOWS` 각 정의에서 `"…"` 라벨을 추출해 내부 `"` 없음).
- [ ] **Step 2: 실패 확인.**
- [ ] **Step 3: 구현.**
- [ ] **Step 4: 통과 확인** — `npm test && npm run typecheck`.
- [ ] **Step 5: Commit** — `feat(admin): dashboard, database, architecture and flow pages`

### Task 10: Docker와 Cloudflare Tunnel

**Files:**
- Create: `web/admin/Dockerfile`, `web/admin/docker-compose.yml`, `web/admin/.env.example`, `.dockerignore`(저장소 루트)

**Interfaces:**
- Consumes: `npm start`, `/healthz`, `Config` 환경 변수.
- Produces: `docker compose -f web/admin/docker-compose.yml up -d --build`로 `http://127.0.0.1:8420` 서비스, `--profile tunnel`이면 `cloudflared`도 실행.

- [ ] **Step 1: 파일 작성**
  - `Dockerfile` (빌드 컨텍스트 = 저장소 루트): `FROM node:24-alpine`, `WORKDIR /app/web/admin`, `package*.json` 복사 → `npm ci --omit=dev` → `web/admin/src`, `web/admin/public`, `web/admin/snapshot` 복사, `docs/*.md`를 `/app/docs/`로, `site/index.html`을 `/app/site/`로 복사. `ENV ADMIN_REPO_ROOT=/app ADMIN_DB_PATH=/data/admin.sqlite NODE_ENV=production`, `/data`를 `node` 사용자 소유로 만들고 `USER node`, `EXPOSE 8420`, `HEALTHCHECK CMD wget -qO- http://127.0.0.1:8420/healthz || exit 1`, `CMD ["node", "--disable-warning=ExperimentalWarning", "src/main.ts"]`.
  - `docker-compose.yml`: `admin` 서비스 `build: { context: ../.., dockerfile: web/admin/Dockerfile }`, `env_file: .env`, `ports: ["127.0.0.1:8420:8420"]`, `volumes: [admin-data:/data]`, `restart: unless-stopped`. `cloudflared` 서비스 `image: cloudflare/cloudflared:latest`, `command: tunnel --no-autoupdate run`, `environment: [TUNNEL_TOKEN]`(`.env`에서), `profiles: [tunnel]`, `depends_on: [admin]`, `restart: unless-stopped`. 터널 대시보드의 public hostname 서비스는 `http://admin:8420`.
  - `.env.example`: `ADMIN_ORIGIN=https://pilgrim.delight-house.org`, `ADMIN_BOOTSTRAP_USERNAME=admin`, `ADMIN_BOOTSTRAP_PASSWORD=admin`, `TRUST_PROXY=true`, `ADMIN_COOKIE_SECURE=true`, 주석 처리된 `TUNNEL_TOKEN=`, `GITHUB_TOKEN=`, `GITHUB_REPO=`. 각 줄 위에 한 줄 한국어 설명(첫 로그인 후 비밀번호 변경 강제, 계정 생성 후 bootstrap 값은 무시됨).
  - `.dockerignore`: `*` 후 `!web/admin/package*.json !web/admin/src !web/admin/public !web/admin/snapshot !docs/*.md !site/index.html`, 그리고 `web/admin/node_modules`, `web/admin/data`, `web/admin/.env` 제외.
- [ ] **Step 2: 로컬 실행** — `web/admin/.env`를 `.env.example`에서 만들되 `ADMIN_ORIGIN=http://localhost:8420`, `ADMIN_COOKIE_SECURE=false`, `TRUST_PROXY=false`. Run: `docker compose -f web/admin/docker-compose.yml up -d --build && sleep 5 && curl -s http://127.0.0.1:8420/healthz && docker compose -f web/admin/docker-compose.yml logs admin | tail -5` / Expected: `ok`, 로그에 시드 메시지.
- [ ] **Step 3: 재시작해도 비밀번호 유지 확인** — 브라우저 확인(Task 12)에서 비밀번호를 바꾼 뒤 `docker compose … restart admin` → 로그에 `bootstrap ignored`, 새 비밀번호로 로그인됨. (Task 12에서 수행)
- [ ] **Step 4: Commit** — `.env`는 커밋하지 않는다(`git status`로 확인). `feat(admin): Docker image and compose with optional Cloudflare Tunnel`

### Task 11: CI와 문서

**Files:**
- Modify: `.github/workflows/check.yml`, `docs/development.md`, `docs/privacy.md`, `docs/implementation-todo.md`, `CLAUDE.md`

- [ ] **Step 1: CI 잡 추가** — `admin-console` 잡, `runs-on: ubuntu-latest`, `actions/setup-node@v4`(`node-version: 24`, `cache: npm`, `cache-dependency-path: web/admin/package-lock.json`), `working-directory: web/admin`에서 `npm ci`, `npm run typecheck`, `npm test`. Run: `python3 -I -c "import yaml,sys; yaml.safe_load(open('.github/workflows/check.yml'))"` (yaml 모듈 없으면 `ruby -ryaml -e 'YAML.load_file(".github/workflows/check.yml")'`) / Expected: 오류 없음.
- [ ] **Step 2: `docs/development.md`에 "관리 콘솔" 절** — 스냅샷 생성(`scripts/admin-snapshot.sh`, 모델·패키지 변경 시 필수, `check.sh`가 검사), 로컬 실행(`npm start` + 환경 변수), Docker 실행, Mac mini 배포 절차(저장소 clone → `.env` 작성 → `docker compose up -d --build` → Cloudflare Zero Trust에서 public hostname `pilgrim.delight-house.org` → `http://admin:8420`(compose 터널) 또는 `http://localhost:8420`(기존 터널)), 첫 로그인과 비밀번호 변경, 비밀번호 분실 시 `data` 볼륨의 `admins` 행 삭제 후 bootstrap으로 재시드, 앱 플로우(`content/flows.ts`)·모듈 설명(`content/modules.ts`)은 앱 동작이 바뀌면 함께 고칠 것.
- [ ] **Step 3: `docs/privacy.md`** — 경계 목록에 한 줄: "개발자 관리 콘솔(`web/admin`)은 스키마·패키지 구조·저장소 문서만 보여 주며 사용자 기록, Apple 로그인 식별자, 이메일, iCloud 정보를 받거나 저장하지 않는다."
- [ ] **Step 4: `docs/implementation-todo.md` "대기 중"에** — `- **관리 콘솔 Mac mini 배포** (2026-11-06)` 항목: Mac mini에서 compose 실행, Cloudflare public hostname 등록, 첫 로그인 후 비밀번호 변경. 사용자 작업.
- [ ] **Step 5: `CLAUDE.md`** — Commands에 `./scripts/admin-snapshot.sh` 한 줄(모델·`Package.swift` 변경 후 실행, `check.sh`가 검사), Architecture 목록에 `AdminSnapshot`과 `web/admin` 각 한 줄.
- [ ] **Step 6: Commit** — `chore(admin): CI job and docs for the admin console`

### Task 12: 브라우저 검증

**Files:** 없음(문제가 나오면 해당 Task 파일 수정 후 별도 커밋).

- [ ] **Step 1:** Task 10의 컨테이너가 떠 있는 상태에서 `.claude/launch.json`에 `{"name": "admin-console", "url": "http://localhost:8420"}` 구성을 추가하고 `preview_start`로 연다(명령 없는 attach 구성).
- [ ] **Step 2:** `/admin` → 로그인 화면으로 이동 확인 → `admin`/`admin` 로그인 → 비밀번호 변경 화면 강제 확인 → 11자 비밀번호 거부 메시지 확인 → 12자 이상으로 변경 → 대시보드.
- [ ] **Step 3:** 네 페이지 각각 `read_page`로 내용 확인, `read_console_messages`로 오류 없음(특히 CSP 위반·Mermaid 오류) 확인, Mermaid SVG가 그려졌는지 `javascript_tool`로 `document.querySelectorAll('pre.mermaid svg').length` 확인.
- [ ] **Step 4:** `resize_window` mobile(375px)에서 `document.documentElement.scrollWidth <= innerWidth` 확인, `colorScheme: dark`로 대시보드 스크린샷.
- [ ] **Step 5:** Task 10 Step 3(재시작 후 비밀번호 유지) 수행.
- [ ] **Step 6:** `./scripts/check.sh`와 `cd web/admin && npm test && npm run typecheck` 최종 실행 / Expected: 모두 통과. 테스트로 만든 컨테이너는 `docker compose … down`(볼륨은 유지)으로 내린다.
