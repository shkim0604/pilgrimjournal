## Why

기도제목 나누기(shkim0604/pilgrimjournal#41)는 뽑은 기도제목을 시스템 공유 시트로 넘기는 데서 끝난다.
`docs/roadmap.md`가 정한 다음 단계는 **비공개 그룹**이다. 초대받은 사람끼리 기도제목·독후감·간증을
올리고, 정해진 기간이 지나면 서버에서 사라지게 하고, 남기고 싶은 사람만 자기 기록장에 스크랩한다.

2026-11-03에 "개인 기록은 iCloud, 공유·SNS는 자체 서버"로 정했다(`docs/group-server.md`). 그룹 크기
제한 없음, 관리자 위임 투표, 기한 자동 삭제, 초대 링크 인원·만료 제한, 밤 10시 Daily Report, 구독자 전용
가입은 CloudKit만으로는 강제할 곳이 없다(`docs/roadmap.md` 검토 표). 그래서 맥미니(`delight`)에 Swift +
Vapor 4 + Postgres 서버를 두고 `pilgrim.delight-house.org`로 연다. 2026-11-14에 주인이 이번 범위를 정했다
(승인된 계획 `shimmying-seeking-tiger`).

## What Changes

**앱**

- 사이드바에 "그룹" 섹션을 둔다(하단 탭 바가 아니다). `GroupsFeature.isEnabled`가 꺼져 있으면 그룹 관련
  화면·알림·딥링크가 하나도 보이지 않는다. Release는 서버 운영이 시작될 때까지 끈다.
- "그룹 시작하기": nonce를 붙인 Apple 재인증 → 기록장 사용자와 같은지 확인 → 서버 로그인 → 이름·프로필
  사진(선택) 가입. 세션은 `ThisDeviceOnly` Keychain에 둔다.
- 그룹 만들기, 초대 링크·QR(링크별 최대 인원, 3일 만료), 초대 코드 직접 입력, 멤버·강퇴·관리자 넘기기·
  나가기, 관리자 위임 투표 화면.
- 글: 기도제목·독후감·간증. 기록에서 바로 올리기(#41 기도제목 시트에 "그룹에 올리기", 독후감·간증은 기록
  내용을 채운 작성 화면). 기한 배지, 먼저 내리기, 독후감 토론 연장. 사진(기기에서 압축, 최대 4장).
- 댓글, 이모지 반응, 그룹 스티커(멤버가 사진으로 만드는 그룹 전용 이모티콘).
- 신고, 양방향 차단, 숨김(글 단위·사람 단위, 내 기기끼리 서버로 맞춤).
- 알림: 새 글 즉시 푸시(잠금화면에 기도 내용 없음), 댓글 등은 Daily Report로 모아서(기본 22:00, 설정 가능),
  Daily Report 화면.
- 스크랩: 그룹 글을 내 기록장에 새 기록으로 복사한다. 새 기본 유형 "스크랩", 그룹별 노트북
  "스크랩 · <그룹 이름>", 사진은 첨부, 댓글은 본문 아래 인용. 서버에는 아무 흔적도 남지 않는다.
- 구독: StoreKit 2 월간 구독 `com.dhouse.PilgrimJournal.groups.monthly`. 구매·복원·서버 검증까지 만들되,
  서버 설정 `SUBSCRIPTION_REQUIRED=false`이면 구독 화면이 뜨지 않는다(출시 때 무료로 연다).
- 계정 삭제: 그룹 서버 계정을 **가장 먼저** 지운다(멱등). 실패하면 로컬·iCloud 삭제 전에 멈춘다. 내가 관리하는
  그룹은 투표로 넘어간다는 것을 확인 화면에 보인다.

**서버 (`server/`, 새로 만든다)**

- `server/PilgrimAPI`: Foundation만 쓰는 공유 계약 패키지(DTO, 오류 코드, 기한·투표·사진 규칙 순수 함수).
  앱과 서버가 함께 쓴다.
- Vapor API(`/api/v1`), 같은 이미지로 띄우는 polling worker, Postgres 17. 맥미니 Docker, Cloudflare Tunnel.
- 터널은 경로로 나눈다: `^/(api/|i/|\.well-known/)` → 그룹 서버 3100, 나머지 → 기존 관리자 콘솔 8420.
- 신고 처리는 기존 콘솔(`web/admin`)의 "신고" 페이지 + 터널에 노출하지 않는 `/internal/admin/v1`.
- 두 번들 ID(`com.dhouse.PilgrimJournal`, `com.dhouse.PilgrimJournal.debug`)를 Apple 토큰 검증, AASA,
  APNs topic, StoreKit 검증 모두에서 받는다.
- `X-Pilgrim-Client`로 오래된 앱을 막을 수 있다(426). 쓰기 요청은 `clientId`로 멱등 처리한다.

**BREAKING:** 없음. 기존 기록장 동작, CloudKit 스키마, 백업 형식은 바뀌지 않는다(아래 Impact).

## Capabilities

### New Capabilities

- `private-groups`: 앱 쪽 그룹 기능 — 가입·세션, 그룹·초대·투표 화면, 글·사진·댓글·반응·스티커, 신고·차단·
  숨김, 알림·Daily Report 화면, 스크랩, 구독 화면, 계정 삭제 연동, 기능 플래그.
- `group-server`: 그룹 서버 동작 — 공개 경로와 터널 경계, 인증·세션, 계정 삭제, 멤버 권한, 초대, 위임 투표,
  기한 규칙과 삭제, 사진·스티커, 차단·숨김 필터, 신고와 운영자 처리, 푸시 outbox, Daily Report, 구독 검증과
  만료 처리, 제한과 멱등성.

### Modified Capabilities

- 없음. 스크랩은 기존 `journal-organization`(유형·노트북)의 동작을 바꾸지 않고 새 기본 유형 하나와 노트북
  이름 규칙을 더한다. 요구사항은 `private-groups`의 "스크랩"에 둔다.

## Impact

- 새 코드: `server/**`(Vapor 앱, worker, 마이그레이션, Docker·Makefile), `server/PilgrimAPI/**`,
  `Sources/JournalGroups/**`, `Sources/PilgrimJournal/Groups/**`, `Tests/JournalGroupsTests/**`.
- 바뀌는 앱 코드: `Package.swift`(PilgrimAPI·JournalGroups), `project.pbxproj`, `AppModel`·사이드바·세션
  컨트롤러(그룹 진입점), `FamilySharing.swift`의 app/scene delegate(푸시 토큰, 알림 탭, Universal Link),
  `JournalDomain`의 `BuiltInKind`(스크랩 유형), `KindCatalog`, `AccountDeletionService`,
  `JournalShareDrafts`(`DatePhraseResolver` 이동, `DeadlineSuggester`), `Share/**`, `SettingsView`.
- 권한·설정: `aps-environment`, `applinks:pilgrim.delight-house.org`, 알림·사진 권한 문구
  (`InfoPlist.xcstrings`), StoreKit 설정 파일. entitlement 변경은 1.2.0(PR #40) 출시 뒤에 main에 넣는다.
- **CloudKit 스키마 변경 없음.** 그룹 데이터는 서버에만 있다. 스크랩은 기존 `JournalEntryEntity`의
  `kindRaw`·`title`·`body`·`occurredAt`·`tagsData`(노트북)와 `AttachmentEntity`만 쓴다(design.md
  "스크랩과 CloudKit 스키마"). 유형 카탈로그와 노트북 목록은 이미 iCloud 키-값 저장소에 있다.
- 개인정보 경계가 바뀐다: `docs/privacy.md`의 "자체 기록 서버를 사용하지 않는다", 관리자 콘솔이 사용자
  데이터를 다루지 않는다는 문장, 계정 삭제의 Apple 토큰 폐기 설명. App Store 개인정보 라벨. 문서 갱신은 D1
  작업이 맡는다.
- 운영: 맥미니 compose 프로젝트 `pilgrim-prod`, 터널 ingress 추가, Apple 키(.p8) 두 개, App Store Server
  Notifications V2 URL, restic → R2 백업. 서버가 꺼져도 기록장은 그대로 동작한다.
- CI: `server` job(Linux, Postgres 서비스) 추가, `scripts/check.sh`가 `server/` lint와 PilgrimAPI 테스트를
  돌린다.
