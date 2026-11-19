# 출시 전 확인 리스트

실기기 검증(`docs/device-verification.md`)과 알려진 문제(`docs/known-issues.md`)를
바탕으로 한 최상위 상태 추적 문서. 절차 상세는 각 문서를 참고하고, 여기서는
아직 열린 항목만 관리한다. 끝난 항목과 지난 세션 기록은
[`archive/pre-release-checklist-history.md`](archive/pre-release-checklist-history.md).

매 TestFlight 빌드(Release 구성) 전: [에디터 입력 릴리스 게이트](known-issues.md#에디터-입력-릴리스-게이트).
아래 항목이 게이트를 다시 돌리라고 하면 이것을 뜻한다.

## 미룬 항목 (재개 필요)

- [ ] **데이터 안전 수정 — 실기기 확인** (2026-11-16, 브랜치 `fix/app-safety`). 자동 테스트와
      서명 없는 빌드만 통과했다. **아래는 하지 않았다.**
      - iCloud 연결 불일치(`.mismatch`) 뒤 재실행: 온라인·비행기 모드 모두 로그인 화면이고 다른
        사람의 iCloud 기록이 열리지 않는지. 'iCloud 연결 다시 확인'으로 내 iCloud에 돌아오면 다시
        들어가지는지 (B-2).
      - 이 빌드로 업데이트한 기존 기기: 첫 실행이 비행기 모드여도 기록이 보이는지, 온라인 첫
        실행은 확인 화면을 잠깐 거친 뒤 들어가는지 (B-1, 세션 F).
      - iCloud 상태 확인이 시간 초과일 때 계정 삭제가 아무것도 지우지 않고 다시 시도를 안내하는지 (B-3).
      - 앱 잠금을 켠 채 콜드 런치: 기록 화면이 한 프레임도 보이지 않는지(iOS·macOS). Keychain을
        못 읽으면 잠긴 채 '기기 암호로 잠금 해제'가 뜨는지.
      - 휴지통 기록이 든 백업 복원(병합·교체): 휴지통에 그대로 남는지.

- [ ] **비공개 그룹 — 실기기 확인** (2026-11-15, 브랜치 `feat/groups`, openspec
      `add-private-groups`). Phase 1(서버 S1~S8, 앱 A1~A8, 인프라 I1, 콘솔 W1)이 합쳐졌고, 앱 연결
      (실제 클라이언트, 계정 삭제 원격 단계, 스크랩 버튼, 알림 opener, 구독, macOS entitlement)은
      2026-11-16 `groups/p2-app`에서 끝났다. 확인한 것은 자동 테스트, 서명 없는 iOS·macOS 빌드, iOS
      시뮬레이터 테스트뿐이다. `docs/device-verification.md` 세션 H로 확인한다. **아래는 모두 하지
      않았다.**
      - 실기기 푸시: 새 글 푸시가 잠금 화면에 기도 내용 없이 오는지, 탭이 앱 잠금 뒤 글을 여는지,
        Debug(sandbox)·TestFlight(production) 각각, Daily Report 시각 (H-4).
      - 그룹 서버로 보내는 Sign in with Apple: nonce 재인증, 다른 Apple ID 거부, code 교환과
        Apple refresh token 저장 (H-1).
      - 초대 Universal Link: AASA가 두 앱 ID로 열리는지, 앱이 꺼진·잠긴·미가입 상태, QR, 앱 없는
        기기의 `/i/<코드>` 페이지에 그룹 정보가 없는지 (H-2).
      - 스크랩: "스크랩" 유형과 노트북 생성, 사진·댓글, 두 번째 기기로 iCloud 동기화, 1.1.0~1.2.x
        기기에서 사용자 유형처럼 보이는지 (H-7). 영어 글은 영어 문구로, 한국어 글과 같은
        "스크랩 · <그룹 이름>" 노트북에 들어가는지, 기기 언어를 English로 바꿔도 같은 글의 문구가 같은지.
        CloudKit 스키마 변경 없음 — 스키마 배포 불필요.
      - 원격 삭제가 든 계정 삭제: 그룹 서버를 가장 먼저 지우고, 실패하면 iCloud·로컬 삭제 전에
        멈추는지, 관리 그룹 투표, Apple 토큰 폐기로 설정의 "Apple로 로그인" 목록에서 연결이
        끊기는지 (H-8). App Review 5.1.1(v) 대응이므로 B-3도 이 빌드로 다시 돈다.
      - `SUBSCRIPTION_REQUIRED=false`(출시 값)에서 구독 화면이 한 번도 안 뜨는지 (H-9).
      - 신고 → 콘솔 신고 페이지(스냅샷·삭제·정지), 차단·숨김의 기기 간 맞춤 (H-5), 위임 투표 (H-6),
        서버가 꺼졌을 때 기록장이 그대로인지 (H-10).
      - macOS 서명 빌드의 푸시 entitlement: macOS는 이제 `PilgrimJournal-macOS.entitlements`
        (`com.apple.developer.aps-environment`)로 서명한다. 프로비저닝 프로필이 받는지, APNs 토큰이
        오는지, 샌드박스 앱이 `ENABLE_OUTGOING_NETWORK_CONNECTIONS`로 그룹 서버와 스크랩 사진 URL에
        닿는지 (H-11).
      - "그룹에 올리기"를 그룹에 로그인하지 않은 상태에서 누르면 그 자리에서 "그룹 시작하기"가 열리고,
        가입을 마치면 작성 화면으로 이어지는지(compact iPhone 포함) (H-12).
      - **보류(구독을 켤 때, H-9b):** StoreKit 샌드박스 구매·복원·서버 JWS 검증·Notifications
        V2(Sandbox)·만료 처리, Xcode Run의 로컬 StoreKit(`PilgrimJournal.storekit`)으로 구매·복원.
      - 기록 화면에 진입점(그룹에 올리기)을 더했으므로 다음 TestFlight 전에
        [에디터 입력 릴리스 게이트](known-issues.md#에디터-입력-릴리스-게이트)를 이 빌드로 돈다.

- [ ] **비공개 그룹 — 운영·출시 준비** (2026-11-15, 브랜치 `feat/groups`). 절차는
      `docs/development.md` "그룹 서버".
      - 맥미니(2026-11-16~18 끝남): 공유 네트워크 `pilgrim-edge`, `server/.env.prod` 비밀 값,
        `make -C server deploy`. 백업은 restic → iCloud Drive로 설치하고 launchd 실행과 맥미니에서의
        읽어 내기(`restic check --read-data`, `pg_restore --list`)까지 확인했다(2026-11-18). restic
        비밀번호(`~/.config/pilgrim-backup/restic-password`)를 운영자 암호 관리자에 옮기는 것과 개발
        Mac으로 `make restore ARGS='--into dev'` 복원 연습은 아직.
      - 터널: `^/(api/|i/|\.well-known/)` → 3100 규칙은 들어가 있다. 인터넷에서 확인(2026-11-18):
        `/api/health` 200, AASA 200 JSON(리디렉트 없음, 두 App ID), Apple CDN
        (`app-site-association.cdn-apple.com`)에 같은 AASA가 캐시됨, 봇처럼 보이는 UA(`python-requests`,
        빈 UA)도 200, `/internal/admin/v1/status`는 콘솔의 404. `--path-as-is`로 보낸
        `/api/../internal/admin/v1/status`(`/i/..`, `/.well-known/..`도)는 터널을 지나 그룹 서버에 닿지만
        라우트가 맞지 않아 JSON 404다(맞았다면 `AdminGuardMiddleware`가 `Cf-Ray`로 403). 2026-11-19 다시: `curl`,
        `python-requests`, 임의 봇 UA, iPhone Safari UA 모두 `/api/health`·AASA·`/i/<코드>` 200, Apple CDN AASA 200.
        **남은 것:** Cloudflare 대시보드에서 봇·WAF 규칙이 `/api`·`/.well-known`에 챌린지를 걸지 않는지 눈으로
        확인(지금 응답으로는 막는 규칙이 없다).
      - Apple: Sign in with Apple 키·APNs 키는 `.env.prod`에 있고 Debug App ID도 그룹에 묶였다.
        **남은 것:** 두 App ID에 Push Notifications·Associated Domains가 켜져 있는지 Developer 사이트에서
        확인. In-App Purchase 키, App Store Server Notifications V2 URL, 구독 상품은 구독을 켤 때(보류).
      - 콘솔 `ADMIN_API_TOKEN` 연결과 CI `server` job(Linux, Postgres)은 끝났다.
      - 처리방침·이용 안내·링크(2026-11-19): `site/index.html`에 그룹 서버 처리방침(`#ko-privacy`,
        `#en-privacy`), `site/group-terms.html`(한·영, 운영자 Seonghoon Kim, 문의 메일·지원 페이지), 가입 화면
        "이용 안내 보기"는 `SupportLinks.groupTerms`. `/i/:code`와 업데이트 안내(`GroupsAppStoreLink`)의 App Store
        링크는 `id6799469852`. 라벨 값은 `docs/app-store-privacy-label.md`. **남은 것:**
        - `site/` 두 파일을 공개 저장소 `shkim0604/pilgrim-support`에 올리고 두 주소가 열리는지 확인(주인).
        - 서버 재배포(`make -C server deploy`) 뒤 `/i/<코드>`의 App Store 링크 확인.
        - 시행일은 그룹을 켜는 업데이트 때 `site/group-terms.html`과 `docs/group-terms.md`에 적는다.
        - 라벨은 그룹을 켜는 빌드를 심사에 낼 때 App Store Connect에 넣는다.
      - 출시 순서: 서버·CI와 `aps-environment`·`applinks` entitlement는 이미 main에 있다. 앱은 Release
        `GroupsFeature.isEnabled = false` 그대로 두고, 세션 H가 끝난 뒤 켜는 PR → 편집기 입력 게이트 →
        TestFlight 순서로 낸다.

- [ ] **기도제목 나누기 — 실기기 확인과 출시 기준** (2026-11-12, 브랜치
      `feat/prayer-request-share`). 절차는 `docs/device-verification.md` 세션 G.
      - **한 것(iOS 26.2 시뮬레이터뿐):** 시트가 직접 쓰기로 열림, 복사 결과가
        "• a\n• b", 번역이 실패하면 원래 언어로 돌아가며 알림이 뜨고 같은 언어로 다시
        시도할 수 있음. 시뮬레이터는 번역("Translation is not supported on simulated
        devices")과 모델 제안을 못 한다.
      - **하지 않은 것:** 실기기 전부, iOS 17·18, macOS 화면, 실제 번역, 기기의 모델 제안,
        메시지·카카오톡으로 넘기기.
      - 한 번 재현 못 한 관찰: 시스템 번역 시트가 닫히는 중에 흐려진 바깥을 누르자 버리기
        확인 없이 시트 전체가 닫혔다. 실기기 세션에서 다시 본다.
      - 출시 기준: 세션 G가 모두 통과하고, 실험실 21개 일기에서 기도할 내용 없는 일기 2개가
        모두 걸러진다. 미달이면 `ShareDraftFeature.onDeviceDraftsEnabled = false`로
        내보낸다(직접 쓰기만).
      - 저장 모델·CloudKit 스키마 변경 없음 — 스키마 배포 불필요.

- [ ] **기도노트 기도제목 체크리스트 — 실기기 확인** (2026-11-06, 브랜치
      `feat/prayer-topics`). 자동 테스트·서명 없는 빌드·시뮬레이터 확인은 통과,
      아래는 하지 않았다.
      - **편집기 입력 게이트 재실행(필수):** 두 가지가 겹친다. ① 양쪽 편집기의
        `typeSpecificFields`가 기도 상태 피커에서 기도제목 체크리스트로 바뀌어
        본문 에디터의 형제 뷰 구조가 달라졌다. ② 같은 브랜치의 인라인 마커
        숨김(c02325f)이 `LiveMarkdownStyler`와 selection 콜백 경로를 바꿨다 —
        커서가 스팬을 드나들 때의 재스타일, 한글 조합 중 커서 이동, 긴 단일
        문단을 특히 본다. [에디터 입력 릴리스 게이트](known-issues.md#에디터-입력-릴리스-게이트).
      - 두 기기 동기화: 한 기기에서 기도제목 추가·체크(응답) → 다른 기기 목록·
        모아보기·열린 편집기에 수렴하는지. 모아보기에서 체크하는 순간 같은 노트를
        다른 기기가 편집 중일 때 마지막 저장 승리 동작 확인.
      - 레거시 기도노트(본문만, 노트 단위 기도 상태 저장됨)가 그대로 열리고
        옛 상태가 UI에 더는 보이지 않는지, 리비전 복원이 기도제목을 되돌리는지.
      - 템플릿(iCloud KV 동기화): 한 기기에서 저장한 템플릿이 다른 기기 템플릿
        메뉴에 나타나는지, 삭제가 수렴하는지(유형 카탈로그와 같은 경로).
      - CloudKit 스키마 변경 없음(`detailsData` 블롭 내부 배열) — 스키마 배포 불필요.

- [ ] **계정 삭제가 가족 공유도 지우는지 — 실기기 CloudKit 확인** (2026-11-07, 브랜치
      `claude/competent-volhard-bedf3d`). 계정 삭제가 이제 받은 공유에서 나가고(shared
      database의 zone 전체 share 삭제) 개인 데이터베이스의 기본 zone 밖 zone을 모두
      지운다(`pilgrim-share-*` 포함, 범위는 `docs/privacy.md` "계정 삭제"). 자동 테스트는
      순서·실패 보고·zone 선택만 확인했고 실제 CloudKit 호출은 돌리지 않았다.
      - 두 Apple 계정(A 소유자, B 참여자)으로: A가 노트북과 기록 하나를 공유하고 B가
        수락, B도 노트북 하나를 공유해 A가 수락한 상태에서 A 계정 삭제.
      - CloudKit Console(A의 개인 DB)에 기본 zone 말고 zone이 없고, binding record도 없다.
      - B 기기: A가 공유한 공간이 목록에서 사라지고, B가 공유한 노트북의 참여자 목록에서
        A가 빠진다. B의 노트북·기록은 그대로다.
      - A 기기 삭제 직후 앱을 다시 열어도 `pilgrim-share-*` zone이 다시 생기지 않는다
        (닫힐 때 남은 `CKSyncEngine` 전송이 zone을 되살리지 않는지).
      - 비행기 모드 등으로 2단계 중간 실패를 만들어 "iCloud 항목 N개를 지우지
        못했습니다" 오류가 나오고, 다시 시도하면 끝까지 지워지는지.
      - CloudKit 스키마 변경 없음(삭제만 함) — 스키마 배포 불필요.

- [ ] **오래된 항목 묶음 확인 — 다음 업데이트와 함께** (2026-11-18 정리). 2026-08~11-03에 생긴
      미룬 항목 23개를 1.1.0·1.2.0 출시 기록과 사용자 실사용 확인(2026-11-18)으로 정리하고 남은
      것만 모았다. 내린 항목과 근거는 [아카이브](archive/pre-release-checklist-history.md#2026-11-18-정리로-내린-것).
      다음 빌드의 [에디터 입력 릴리스 게이트](known-issues.md#에디터-입력-릴리스-게이트)·"데이터 안전 수정"
      확인과 같은 자리에서 돈다(약 15분).
      - **백업·복원 수렴 (세션 C-2):** 시작할 때 Mac에서 전체 백업을 내보내고 iPhone을 비행기
        모드로 둔다(30분 이상). 그동안 아래를 하고, Mac에서 기록 2개를 고친 뒤 replace 모드로
        복원한다. iPhone을 온라인으로 돌려도 복원 결과가 유지돼야 한다. 위 "데이터 안전 수정"의
        휴지통 기록 든 백업 복원도 같은 파일로 한다. 예전 빌드의 파일 선택 창 문제는 `7ecc452`에서 고쳤다.
      - **iPhone 1분 (소프트 키보드, Release):** 체크박스 탭 뒤 캐럿이 그대로이고 실행 취소가
        되는지(체크리스트 토글). 빈 불릿에서 Backspace 한 번으로 마커가 지워지는지(불릿 5건). 제목
        칸에서 Return이 편집기를 닫는지 — 하드웨어 키보드에서는 닫았다(첫 입력 항목). 키보드를 내린
        채 집중 모드에서 오른쪽 위 버튼으로 나오는지. 본문을 아래로 쓸어내려 키보드가 닫히는지
        ("키보드 닫기" 버튼은 📷에 자리를 내줬다).
      - **Mac 1분:** 체크박스 클릭과 ⌘Z(체크리스트 토글). 집중 모드에서 ⌘N 5번 — 크래시가 없어야
        한다(build 20의 집중 모드 → 새 노트 크래시, `MacNavigationSplitFocus`의 `keyWindow` 가드).
      - **지금 동기화 콘솔 (2분):** 버튼으로 다른 기기 기록이 들어오는 것은 사용자가 실사용으로
        확인했다. Xcode에서 Mac Debug로 실행해 버튼을 2~3번 누르고, 콘솔에 CoreData+CloudKit
        "second handler"·중복 container 경고가 없는지, "다른 작업이 기록을 사용하고 있어…" 오류가
        뜨지 않는지 본다(옛 container가 실제로 풀렸다는 증거, `JournalSessionController.reopenForManualSync`).
      - **영어 화면 한 바퀴 (1.1.0 (29)에서 옮김):** 설정 › 언어를 English로 두고 사이드바·목록·
        편집기·설정을 훑은 뒤 시스템 설정으로 되돌린다. 현지화는 시뮬레이터에서만 봤다.

- [ ] **사용자 유형 관리 — 실기기 확인** (2026-10-15, 브랜치
      `feat/user-managed-kinds`, 스펙 6·7절). 자동 테스트와 서명 없는 빌드는
      통과했지만 아래는 하지 않았다.
      - 두 기기 간 카탈로그 동기화: 추가, 이름 변경, 순서 변경, 삭제, 되살리기.
      - 한 기기가 삭제하는 동안 다른 기기가 오프라인에서 그 유형으로 기록을 쓰고,
        다시 연결한 뒤 정리 작업이 기록을 옮기는지.
      - 백업 → 다른 기기 복원 후 유형 구성.
      - **유형을 추가·삭제하기 전에 모든 기기를 이 빌드 이상으로 업데이트
        (필수):** 이전 빌드는 사용자 유형 기록과 미분류로 옮긴 손 기록을
        미분류로 보고, 저장할 때마다 `invalidManualKind`로 **거부한다.** 기록이
        덮이지는 않지만 그 빌드의 편집기에서 고친 내용은 저장되지 않고, 편집기를
        닫으면 사라질 수 있다. 업데이트 전에는 이전 빌드에서 그런 기록을 열어
        고치지 않는다. 새 백업은 이전 빌드가 복원도 거부한다.
      - **기기 간 순서 경합 ①: 카탈로그(KV)가 기록(CloudKit)보다 먼저 도착.**
        A 기기에서 기도노트 기록을 고친 뒤 기도노트를 삭제(다른 유형으로 이동)
        하고, B 기기는 A의 옮긴 기록을 받기 전에 카탈로그부터 받게 한다(예: B를
        잠시 오프라인 → 다시 연결). B의 정리 작업이 A가 마지막으로 저장한 옛
        사본을 옮기지 않고 기다리는지, 이후 CloudKit이 A의 옮긴 판(본문에 붙인
        전용 필드 줄 포함)을 가져와 B에서도 그 판이 보이는지 확인한다.
      - **기기 간 순서 경합 ②: 기록(CloudKit)이 카탈로그(KV)보다 먼저 도착.**
        A에서 삭제했던 기본 유형을 되살리고 그 유형으로 새 기록을 쓴 뒤, B가
        새 기록을 받고 나서야 되살린 카탈로그를 받게 한다. B가 옛 카탈로그로
        CloudKit 가져오기 정리 작업을 돌리면 그 기록을 다시 옮길 수 있다. 실제로
        옮겨지는지, 옮겨진다면 사용자가 이해할 수 있는 결과인지 기록한다.
      - macOS 인라인 편집기로 기록을 연 채 `유형 편집`에서 그 기록의 유형을
        삭제: 편집기가 새 유형과 붙은 본문으로 다시 읽히는지, 바로 이어서 입력해도
        옛 유형으로 되돌아가지 않는지, 삭제 직전에 입력한 글자가 남는지.
      - **편집기 재로드 경계 사례** (브랜치 `fix/kind-reload-edge-cases-v2`,
        자동 테스트는 순수 함수와 AppModel 경로만 덮는다):
        - iPhone 전체 화면 편집기로 기록을 연 채, 다른 기기에서 그 기록의 유형을
          삭제하고 동기화를 기다린다. 편집기가 새 유형과 붙은 본문으로 다시
          읽히는지, 이어서 입력해도 옛 유형·본문으로 되돌아가지 않는지 확인한다.
          (iOS 편집기가 이번에 처음으로 재로드와 flush를 받는다.)
        - **한글 조합 중 재로드 (macOS·iPhone 각각):** 본문 끝에서 한글 음절을
          조합하는 중에(밑줄이 보이는 상태) 그 기록이 옮겨지게 한다 — 다른
          기기에서 유형을 삭제하고 이 기기가 동기화를 받는 순간 계속 입력하는
          식. 조합이 끝난 뒤 본문에 붙은 전용 필드 줄이 남아 있고, 조합하던
          글자도 남는지 확인한다. 타이밍을 맞추기 어려우면 여러 번 시도한다.
        - macOS에서 새 기록(아직 저장 전)을 쓰는 중에 다른 기기의 유형 삭제가
          동기화되게 한다. 목록에 같은 기록이 두 개 생기지 않는지 확인한다.
        - 위 항목 뒤에 [에디터 입력 릴리스 게이트](known-issues.md#에디터-입력-릴리스-게이트)를
          다시 통과시킨다. 이번 변경이 조합 중 binding 발행 경로를 건드린다(재로드가
          대기 중일 때만).
      - macOS에서 `유형 편집` 시트 실행: 빌드만 했다. 삭제 확인 창과
        컨텍스트 메뉴·Delete 키 삭제를 확인한다.
      - 편집기의 인라인 오류 문구(이름 중복, 빈 이름 등)는 시뮬레이터에서
        확인하지 않았다.
      - iOS 26에서 삭제 확인이 취소 버튼 없는 팝오버로 뜬다. 바깥을 누르면
        취소된다. 이대로 괜찮은지 결정한다.
