# 개발 및 배포 구성

## 식별자

- 제품명: Pilgrim Journal
- bundle identifier: `com.dhouse.PilgrimJournal` (Release),
  `com.dhouse.PilgrimJournal.debug` (Debug)
- CloudKit container: `iCloud.com.dhouse.PilgrimJournal` (두 구성 공통. Debug 서명은
  Development 환경만 쓴다)
- 그룹 서버: `https://pilgrim.delight-house.org/api/v1` (개발: `http://localhost:3100/api/v1`).
  두 bundle identifier를 Apple 토큰 검증·AASA·APNs topic·StoreKit 검증에서 모두 받는다.
- 그룹 구독 상품: `com.dhouse.PilgrimJournal.groups.monthly` (월간 자동 갱신)

Debug 빌드는 설치된 릴리스 앱과 나란히 실행해도 구분되도록 bundle identifier에
`.debug`가 붙는다(2026-11-05). 그래서 Debug 빌드는:

- 앱 샌드박스 컨테이너, Keychain(앱 잠금, Apple 로그인 기록), 앱별 언어 설정이
  릴리스 앱과 따로다. 처음 실행하면 로컬 저장소가 비어 있고, CloudKit
  Development 환경에서 다시 받는다.
- iCloud key-value store는 entitlements에 `com.dhouse.PilgrimJournal`로 고정돼 있어
  **릴리스 앱과 같은 저장소를 쓴다**(노트북 목록, 유형 카탈로그). 일부러 공유하는
  것이다(2026-11-05 결정). Debug 전용 저장소로 바꾸지 않는다.
- 처음 서명 빌드할 때 Xcode 자동 서명이 새 App ID를 등록해야 한다(Xcode에서 한 번
  빌드하거나 `xcodebuild … -allowProvisioningUpdates`). Apple Developer에서 그 App
  ID의 Sign in with Apple을 기존 primary App ID 그룹에 묶고, iCloud container가
  `iCloud.com.dhouse.PilgrimJournal`인지 확인한다. 묶지 않으면 Apple 로그인 사용자
  식별자가 달라질 수 있고, 그러면 CloudKit 귀속 확인이 Debug 앱을 막는다.

## Xcode capability

iOS와 macOS target 모두에 다음 capability가 필요하다.

1. Sign in with Apple
   - Xcode의 Signing & Capabilities에서 두 플랫폼 target에 추가
   - iOS와 macOS App ID를 Apple Developer의 같은 primary App ID 그룹으로 구성
   - 실제 기기에서는 Two-Factor Authentication이 활성화된 Apple 계정 사용
2. iCloud
   - CloudKit 활성화
   - 동일한 private container 선택
3. Background Modes
   - Remote notifications 활성화
4. Push Notifications (그룹 새 글·Daily Report 푸시, `feat/groups`)
5. Associated Domains: `applinks:pilgrim.delight-house.org` (그룹 초대 Universal Link `/i/*`)

저장소의 `PilgrimJournal.entitlements`에는 Sign in with Apple, CloudKit private
container와 iCloud key-value store entitlement가 포함되어 있다. `feat/groups`에는
`aps-environment`(`development`)와 `applinks:pilgrim.delight-house.org`도 있다. 이 두
entitlement는 1.2.0 출시 뒤에 main에 넣는다(openspec `add-private-groups` Migration Plan).
Apple Developer에서 두 App ID(`com.dhouse.PilgrimJournal`, `.debug`) 모두에 Push
Notifications와 Associated Domains를 켜야 서명된다. macOS도 같은 entitlements 파일을 쓰는데,
macOS 푸시 키는 `com.apple.developer.aps-environment`라 서명한 macOS 빌드에서 확인이 필요하다
(필요하면 `CODE_SIGN_ENTITLEMENTS[sdk=macosx*]`로 파일을 나눈다). 실제 로그인과
CloudKit은 소유한 Apple Developer Team과 provisioning profile로 서명해야 하며
`CODE_SIGNING_ALLOWED=NO` 빌드는 UI·컴파일 검증만 가능하다.

CloudKit private database의 고정 account-binding record에는 Apple 로그인의 opaque
사용자 식별자를 앱 범위에서 SHA-256한 값만 저장한다. 같은 private database를 다른
Apple 로그인 사용자가 열면 journal UI를 차단한다. Apple은 로그인 계정과 시스템
iCloud 계정의 이메일을 앱에 제공하지 않으므로 최초 연결은 현재 iCloud private
database를 현재 Apple 로그인 사용자에게 귀속시키는 동작이다.

iOS target의 `Info.plist`에는 Face ID 앱 잠금 설명을 추가한다.

- `NSFaceIDUsageDescription`: `개인 일기 기록의 앱 잠금을 해제하기 위해 Face ID를 사용합니다.`

CloudKit production schema는 additive-only 정책으로 관리한다. 개발 container에서
생성·수정·동시 편집·삭제 tombstone·첨부·복원을 실제 Mac과 iPhone으로 검증한
뒤에만 production으로 승격한다.

앱은 `NSPersistentCloudKitContainer.eventChangedNotification`의 setup·import·export
이벤트를 관찰한다. 진행 중에는 동기화 대기로 표시하고, export/import 완료 시
완료 시각을 갱신한다. Remote import가 완료되면 canonical 목록과 로컬 검색 색인을
새로고침하며 실패 이벤트는 재시도 가능한 오류로 표시한다. 이 이벤트 처리는
자동화 테스트 대상이지만, 실제 두 기기의 네트워크 수렴은 아래 실제 기기 관문을
별도로 통과해야 한다.

## 저장 adapter 관문

adapter는 SwiftData를 쓴다. 실제 기기 spike(`docs/device-verification.md` 세션 A)에서
SwiftData **go**로 결정했다(`docs/pre-release-checklist.md`). 대량 배치 성능만 그
결정에서 빠졌다. 아래 조건은 이제 회귀 기준이다 — 동기화·삭제·첨부 경로를 바꾸면
다시 확인한다.

- 같은 계정의 두 기기에서 background 수렴
- 오프라인 동시 편집 revision 보존
- 삭제 tombstone과 명시적 복원
- 외부 저장 첨부 업로드와 지연 다운로드
- 대량 Day One import 후 앱 응답성 유지

어느 조건이 깨져 고칠 수 없으면 도메인 protocol은 유지하고
`NSPersistentCloudKitContainer` adapter로 교체한다.

## 로컬라이제이션

UI는 한국어가 원문이고, 한국어 문장 자체가 로컬라이제이션 키다. 영어는 String
Catalog에 있다.

| 파일 | 대상 |
| --- | --- |
| `Sources/PilgrimJournal/Localizable.xcstrings` | 앱(main bundle). SwiftPM에서 빠져 있고 Xcode 앱 target이 컴파일한다 |
| `Sources/<Library>/Resources/Localizable.xcstrings` | 라이브러리. `String(localized: "…", bundle: .module)` |
| `PilgrimJournal/PilgrimJournal/InfoPlist.xcstrings` | 권한 설명 문구 |

- 새 사용자 문구는 `Text("…")` 같은 `LocalizedStringKey` 리터럴이나
  `String(localized:)`로 쓴다.
- 저장·동기화되는 데이터는 번역하지 않는다(Day One 매칭, import 감사 기록, 카탈로그의
  유형 이름). 기본 유형 이름은 한국어로 저장하고 화면에서만 번역한다
  (`KindDefinition.displayName` / `storedName(for:)`).
- 명령줄 SwiftPM은 catalog를 컴파일하지 않고 복사만 하므로 `swift test`는 한국어를
  본다. Xcode 빌드는 컴파일하므로 iOS Simulator 테스트는 `-testLanguage ko`로 고정한다.
- 문구를 추가한 뒤 키를 갱신하고 빠진 `en` 값을 채운다.

  ```sh
  xcodebuild -exportLocalizations -project PilgrimJournal/PilgrimJournal.xcodeproj \
    -localizationPath <dir> -exportLanguage en   # 앱
  xcodebuild -exportLocalizations -localizationPath <dir> -exportLanguage en   # 패키지 루트에서, 라이브러리
  ```

## CloudKit 운영 도구

Debug 빌드는 아래 환경 변수로 앱 대신 관리 작업을 수행한다. 스키마 배포·삭제
변수는 작업 뒤 종료하고, `PILGRIM_DEV_APPLE_USER`는 로그인 게이트만 건너뛴 채 앱을
연다. 모두 **Apple 로그인 앞에서** 돌기 때문에 Touch ID를 쓸 수 없는 원격 세션에서도 쓸 수
있다. 실행 파일을 직접 부른다 — `open`은 환경 변수를 전달하지 않는다.

```bash
DD=/tmp/pilgrim-dd   # iCloud 동기화 밖 경로여야 한다. 아래 "릴리스 아카이브" 참고
xcodebuild -project PilgrimJournal/PilgrimJournal.xcodeproj \
  -scheme PilgrimJournalApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" build
# macOS 제품명에 공백이 있으므로 이름을 박아 쓰지 말고 glob 으로 찾는다.
APP=$(ls -d "$DD/Build/Products/Debug/"*.app)
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
PILGRIM_DEPLOY_CLOUDKIT_SCHEMA=1 "$BIN"
```

| 변수 | 하는 일 |
| --- | --- |
| `PILGRIM_DEPLOY_CLOUDKIT_SCHEMA=1` | 모델에서 레코드 타입·필드·인덱스를 만든다. 자세한 배경은 `docs/known-issues.md` |
| `PILGRIM_WIPE_JOURNAL_DATA=1` | 미러링 존을 지워 기록을 전부 없앤다. **스키마는 남는다** |
| `PILGRIM_WIPE_LOCAL_DATA=1` | 위와 함께 쓰면 이 기기의 저장소·검색 인덱스도 지운다 |
| `PILGRIM_DEV_APPLE_USER=<id>` | 로그인 게이트를 건너뛰고 실제 저장소·CloudKit으로 앱을 연다 |

**CloudKit 환경은 서명이 정한다.** Debug 빌드는 Development만 건드린다.
Production 데이터를 지우려면 CloudKit Console → Data → Zones에서
`com.apple.coredata.cloudkit.zone`을 직접 삭제하거나, TestFlight 앱에서 빈 백업을
replace 모드로 복원한다.

존을 지워도 **로컬 사본을 가진 기기는 다음 실행에서 존을 다시 만들고 전부
재업로드한다.** 정말로 비우려면 모든 기기의 로컬 데이터도 같이 지워야 한다.

## 공유 노트북 실기기 확인

공유 노트북(`docs/implementation-todo.md` "가족 공유 노트북")은 iCloud 공유라 실기기 두
대로만 확인할 수 있다. 사이드바 노트북을 길게 누르거나 우클릭 → **공유…**, 기록 하나는
목록에서 길게 누르기 → **공유…**. 공유한 것과 받은 것은 사이드바 **공유됨**에 나온다.
iCloud에 연결된 상태에서만 메뉴가 보인다.

준비물: **서로 다른 Apple ID로 iCloud에 로그인한 iPhone 2대**(A = 소유자, B = 초대받는 사람).
둘 다 Xcode에서 서명한 빌드를 설치한다. Debug 빌드는 CloudKit Development 환경을 쓴다.
시뮬레이터나 서명 없는 빌드는 iCloud entitlement가 없어 시작하자마자 멈춘다. Mac은 초대는
보낼 수 있지만 초대 수락 경로(`CKSharingSupported`)가 아직 없다.

| # | 할 일 | 확인할 것 |
| --- | --- | --- |
| 1 | A: 기록이 몇 개 든 노트북 → 공유… → 공유하고 초대하기 → 시스템 공유 화면에서 B에게 메시지로 초대 | 노트북이 "노트북"에서 빠지고 "공유됨"에 나타남. 기록이 그대로 보임 |
| 2 | B: 메시지의 링크를 연다. 앱이 꺼져 있을 때와 잠금 화면 상태에서 각각 한 번 | B의 "공유됨"에 노트북과 기록이 나타남 |
| 3 | A: 공유 노트북에서 새 노트 작성 | B 화면에 뜨기까지 걸린 시간. 공유 노트북을 열어 두면 8초마다 가져온다 |
| 4 | B: 같은 노트의 다른 줄 수정, A는 그 노트를 연 채로 대기 | A의 편집기에 두 수정이 모두 보임 |
| 5 | A·B 모두 비행기 모드에서 같은 노트의 **다른 줄** 수정 → 비행기 모드 해제 | 양쪽 결과가 같고 두 수정이 모두 남음 |
| 6 | 5번을 **같은 줄**로 반복 | 나중에 고친 쪽이 본문에 남고, 진 쪽은 이력에 있음 |
| 7 | A: 타이핑 중에 B가 같은 노트를 고침 (30초 이상 빠른 한영 혼용) | 입력이 사라지지 않음 ([에디터 입력 릴리스 게이트](known-issues.md#에디터-입력-릴리스-게이트)) |
| 8 | A: 앱을 껐다 켜고, A의 두 번째 기기(같은 Apple ID)에서도 열기 | 공유와 노트가 다시 나타남 |
| 9 | B: 나가기… → 내 기록장에 복사하고 나가기 | B의 노트북에 사본이 생기고 "공유됨"에서 사라짐. A는 그대로 |
| 10 | A: 공유 끝내기… | A의 노트북으로 기록이 돌아오고(이력 포함), 다른 사람 화면에서 사라짐 |

알려진 한계:
- 사진이 든 기록은 아직 공유할 수 없고, 공유 노트북에 사진을 넣을 수 없다.
- 공유 노트북의 휴지통은 아직 없다. 공유 노트를 삭제하면 휴지통 화면에 나오지 않는다.
- 공유 노트는 검색 색인에 들어가지 않는다. 공유 노트북을 연 상태에서는 제목·본문 단순 필터로 찾는다.
- 백업에는 공유 노트가 들어가지 않는다.
- 소유자의 공유는 private DB의 `pilgrim-share-<uuid>` 존에 있다. 개인 기록의
  `com.apple.coredata.cloudkit.zone`은 공유 엔진이 가져오지 않는다
  (`SharedSyncEngineHost.fetchOptions`). CloudKit Console에서 두 존이 따로 보이는지
  확인한다.
- 새 레코드 타입 `SharedEntry`, `SharedRevision`은 Development에서 처음 저장할 때
  만들어진다. Production 배포 전에 Console에서 배포해야 한다.
- 메타데이터(`Shared/SharedSync.json`)는 변경마다 통째로 다시 쓴다. 노트가 수백 개면
  느려질 수 있다.
- 결과는 `docs/pre-release-checklist.md`에 남긴다.

## 공유 카드 추출 평가 (온디바이스 모델)

`docs/roadmap.md`의 공유 카드(기도제목·간증·독후감) 추출을 Apple 온디바이스 모델로
돌려 보고 점수를 매기는 실행 파일이다. 프롬프트를 바꿀 때마다 같은 기록으로 다시 돌려
비교한다.

```sh
swift run ShareCardEval                      # 전체 23개 기록 (약 2~3분)
swift run ShareCardEval --skip-prose         # 카드 문장 생성 생략. 점수는 같고 더 빠르다
swift run ShareCardEval --only next-month-day,long-no-prayer --verbose
swift run ShareCardEval --list               # 기록 id 목록
swift run ShareCardEval --json /tmp/share-card-run.json
```

- **필요 조건:** macOS 26 이상, Apple Intelligence 지원 Mac에서 Apple Intelligence가
  켜져 있어야 한다. 모델을 쓸 수 없으면 이유를 출력하고 종료 코드 69로 끝난다.
  `swift build`는 어디서나 통과하도록 모델 코드를 `canImport(FoundationModels)`와
  macOS 26 확인 뒤에 두었다. 하드웨어가 필요하므로 `scripts/check.sh`와 CI에서는
  **돌리지 않는다.** (채점 같은 순수 로직은 `ShareCardEvalTests`로 `swift test`에 들어
  있다. 날짜 해석기 `DatePhraseResolver`는 이제 `JournalShareDrafts`에 있고 실험실은 그것을
  가져다 쓴다. 해석기 테스트 `DatePhraseResolverTests`는 아직 `Tests/ShareCardEvalTests`에 있다.)
- **기록은 전부 지어낸 것이다** (`Sources/ShareCardEval/EvalFixtures.swift`). 실제
  기록이나 Day One 내용을 넣지 않는다. 기록을 추가할 때 `expected` 라벨(기도제목
  여부, 간증 여부, 제3자 사정, 데드라인)을 함께 적는다. 데드라인은 `phrase`가 본문에
  그대로 있어야 하고, 테스트가 그 표현을 코드로 해석해 라벨 날짜와 맞는지 확인한다.
- **파이프라인**(`SharePipeline.swift`): ① 짧은 예시를 넣은 예/아니오 분류 3개(기도제목
  있음, 간증, 제3자 사정) ② 기도제목이 있으면 `@Generable`로 짧은 값(요약·날짜 표현·
  날짜)만 뽑고 ③ 카드 문장은 자유 텍스트로 따로 받는다 ④ 작성일 기준 달력 힌트(내일,
  이번/다음 주 요일별 날짜, 이번/다음 달 말)를 코드가 계산해 넣고, 모델이 뽑은 날짜
  표현은 `DatePhraseResolver`가 먼저 해석한다 — 해석 못 하면 모델 날짜를 쓴다. 해석기는
  2026-11-14에 `ShareCardEval`에서 `JournalShareDrafts`(`DeadlinePhraseResolver.swift`,
  `Calendar`를 주입받는 `DeadlineCalendar`)로 옮겼다. 앱은 같은 해석기로 그룹에 올리는
  기도제목의 데드라인을 제안하고(`DeadlineSuggester`: 선택한 줄에서 먼저, 없으면 기록 본문
  문장에서, 오늘~365일 안의 가장 늦은 날, "매주" 같은 반복은 건너뜀), 실험실은 서울 달력으로
  부른다(`EvalCalendar.swift`). 해석 규칙을 바꾸면 `DatePhraseResolverTests`
  (`Tests/ShareCardEvalTests`)와 `DeadlineSuggesterTests`(`Tests/JournalShareDraftsTests`)를
  함께 돌린다 ⑤
  `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, greedy
  샘플링, `guardrailViolation`은 "추천 건너뜀"으로 기록한다.
- **출력:** 기록별 PASS/FAIL과 검사 항목, 호출 수·지연 시간, 마지막에 요약 점수
  (검사 통과 수/전체), 항목별 정확도, 지연 중앙값·p90·첫 호출, guardrail 건너뜀 수.
  "데드라인(모델 날짜만)"과 "카드에 남은 제3자 이름"은 참고용으로 점수에서 뺀다.
- **일기 → 기도제목 검토 (`--prayer-requests`)**: 채점 대신, 한 페이지 분량의 지어낸 일기
  21개(`PrayerDiaryFixtures.swift`)를 새 기도제목 프롬프트와 이전 기도 카드 프롬프트로 각각
  돌려 나란히 출력한다. 사람이 읽고 판단하는 용도라 점수는 없다. `--json`으로 저장하면
  검토 페이지에 그대로 넣을 수 있다.

  ```sh
  swift run ShareCardEval --prayer-requests                 # 전체 21개 (약 1분)
  swift run ShareCardEval --prayer-requests --only camping,friend-depression
  swift run ShareCardEval --prayer-requests --json /tmp/prayer-run.json
  ```

- **프롬프트 실험실 (`--serve`)**: 기도제목 프롬프트를 브라우저에서 직접 고쳐 돌려 보는
  페이지. 이 Mac의 loopback(localhost)에서만 열리고, 모델도 이 Mac에서 돈다. Claude
  데스크톱 앱에서는 `.claude/launch.json`의 `prompt-lab`으로 브라우저 패널에 연다.

  ```sh
  swift run ShareCardEval --serve                     # http://localhost:8765
  swift run ShareCardEval --serve --log-dir /tmp/lab  # 지어낸 일기 실행 기록을 lab-runs.jsonl로
  ```

  - 지시문과 요청 템플릿(`{날짜}` `{제목}` `{본문}`)을 고치고 일기를 골라 돌리면 직전
    실행과 나란히 나온다. 실행 기록·편집 중인 프롬프트는 브라우저 localStorage에 남는다.
  - 결과를 "고치기"로 고쳐 저장하면 **내 말투 예시**로 쌓이고(최근 6줄), 다음 실행부터
    지시문 끝에 "이 사용자가 직접 고친 기도제목" 블록으로 자동으로 붙는다. 앱에서 "사람이
    고친 초안으로 프롬프트를 개인화"하는 방식을 미리 시험하는 용도.
  - 직접 붙여 넣은 일기는 브라우저 저장소와 `--log-dir` 기록 어디에도 내용을 남기지
    않는다. 다른 사이트에서 온 요청(`Origin`이 다른 요청)은 거부한다.

- **실험실과 앱은 같은 `JournalShareDrafts`를 쓴다.** 기도제목 언어 감지·프롬프트·
  파이프라인(예/아니오 거름 → 초안 → 반복 제거·최대 3줄 → 한국어는 "기도해 주세요"
  꼬리 자르기)은 `Sources/JournalShareDrafts/`에 하나만 있고, 앱의 `기도제목 나누기`
  시트와 `--serve` 실험실, `--prayer-requests`가 모두 이것을 부른다. 그래서 프롬프트
  문구를 바꾸면 `PrayerRequestPrompts.version`을 올리고 21개
  일기를 다시 돌려 결과를 확인한 뒤 내보낸다. 앱 쪽 출시 기준은
  `docs/pre-release-checklist.md`.
- **프롬프트를 바꾸면 `SharePrompts.version`을 올린다.** 기도제목 프롬프트는
  `PrayerRequestPrompts.version`을 따로 올린다. 요약과 JSON에 찍혀서 어떤
  프롬프트의 점수인지 구분된다. 의미 있는 결과는 `docs/roadmap.md`의 성능 테스트 표에
  적는다. JSON 결과는 저장소 밖에 둔다.

## 관리 콘솔 (`web/admin`)

`pilgrim.delight-house.org/admin`에서 대시보드(출시 게이트·남은 일·최근 커밋·바로가기),
데이터베이스(SwiftData 스키마), 아키텍처(SwiftPM 타깃 그래프·모듈 설명·저장 위치),
앱 플로우(Mermaid 흐름도)를 보는 개발자 전용 콘솔이다. 기록장 기록·이메일·iCloud 정보는
받지 않는다. 예외는 그룹 기능의 **신고** 페이지로, 그룹 서버의 운영자 API에서 신고 스냅샷·
원본·사진을 그때그때 받아 보여 주고 삭제·정지·처리 완료를 보낸다(저장하지 않음,
`docs/privacy.md` "운영자 콘솔과 신고", 아래 "그룹 서버" › "관리 콘솔 연결"). 설계는
`docs/archive/superpowers/specs/2026-11-06-admin-console-design.md`.

### 스냅샷

Linux 컨테이너는 SwiftData를 돌릴 수 없어서, 스키마와 패키지 구조는 macOS에서 만든 JSON을
커밋해 둔다.

```sh
./scripts/admin-snapshot.sh   # web/admin/snapshot/{schema,architecture,commits}.json
```

SwiftData 모델(`canonicalModels`/`localModels`)이나 `Package.swift`를 바꾸면 실행하고 결과를
커밋한다. `scripts/check.sh`가 `schema.json`·`architecture.json`이 오래됐으면 실패한다.
`commits.json`은 비교하지 않으므로 배포 전에 한 번 다시 만들면 대시보드의 최근 커밋이 맞는다.

### 로컬 실행

```sh
cd web/admin && npm ci
ADMIN_ORIGIN=http://localhost:8420 ADMIN_COOKIE_SECURE=false \
  ADMIN_BOOTSTRAP_USERNAME=admin ADMIN_BOOTSTRAP_PASSWORD=admin npm start
npm test && npm run typecheck
```

로컬 Node는 22.18 이상(`.ts`를 타입 제거로 바로 실행), Docker와 CI는 Node 24.

### Mac mini 배포 (Docker + Cloudflare Tunnel)

**admin/admin은 공개 문서(`.env.example`)에 있는 값이다.** 첫 로그인 전에 터널을 열면 누구든
먼저 로그인해 비밀번호를 정하고 콘솔을 가져갈 수 있다. 그래서 첫 로그인(비밀번호 변경)은 터널을
열기 **전에** Mac mini 로컬에서 끝낸다. bootstrap 비밀번호가 12자 미만이거나 아이디와 같으면
서버가 시작 로그에 `WARNING`을 남긴다.

1. 저장소를 받고 `cp web/admin/.env.example web/admin/.env`. 첫 로그인용으로 잠시
   `ADMIN_ORIGIN=http://localhost:8420`, `ADMIN_COOKIE_SECURE=false`, `TRUST_PROXY=false`로 둔다.
2. 실행: `docker compose -f web/admin/docker-compose.yml up -d --build`. 컨테이너는
   `127.0.0.1:8420`에만 열린다. 계정 DB는 `admin-data` 볼륨(`/data/admin.sqlite`).
3. Mac mini에서(원격이면 `ssh -L 8420:localhost:8420 <mac-mini>` 후 내 브라우저에서)
   `http://localhost:8420/admin`을 열고 bootstrap 계정(기본 admin/admin)으로 로그인한다.
   비밀번호 변경 화면에서 12자 이상으로 바꾼다. 계정이 생긴 뒤에는 bootstrap 값을 무시하므로
   재시작해도 비밀번호가 되돌아가지 않는다.
4. `.env`를 운영 값으로 바꾼다: `ADMIN_ORIGIN=https://pilgrim.delight-house.org`,
   `ADMIN_COOKIE_SECURE=true`, `TRUST_PROXY=true`. `ADMIN_BOOTSTRAP_*` 두 줄은 지운다. 계정이 이미
   있어 쓰이지 않고, 볼륨을 잃었을 때 admin/admin이 인터넷에 다시 열리는 대신 서버가 시작을
   거부하게 된다. `docker compose -f web/admin/docker-compose.yml up -d`로 다시 만든다(볼륨의 계정은
   유지된다).
5. 터널 연결 — 셋 중 하나:
   - Mac mini의 cloudflared가 `~/.cloudflared/config.yml`로 관리되면(지금 Mac mini가 이렇다)
     `config.yml`을 백업하고 `ingress`의 마지막 `- service: http_status:404` 바로 위에
     `- hostname: pilgrim.delight-house.org` / `service: http://localhost:8420`을 넣는다.
     `cloudflared tunnel --config ~/.cloudflared/config.yml ingress validate`로 확인하고,
     `cloudflared tunnel route dns <tunnel-id> pilgrim.delight-house.org`로 DNS를 만든 뒤
     `launchctl kickstart -k gui/$(id -u)/com.cloudflare.cloudflared`로 재시작한다. 재시작하는 몇 초
     동안 같은 터널을 쓰는 SSH(`ssh.delight-house.org`)와 noldam API도 끊긴다. SSH로 작업 중이면
     `nohup`으로 띄워 재시작이 끝까지 실행되게 한다.
   - 대시보드에서 관리하는 터널이면 Zero Trust › Networks › Tunnels에서 public hostname
     `pilgrim.delight-house.org` → `http://localhost:8420`을 추가한다.
   - compose에 포함된 cloudflared를 쓰려면 새 터널의 토큰을 `.env`의 `TUNNEL_TOKEN`에 넣고
     `--profile tunnel`로 올린 뒤 public hostname 서비스를 `http://admin:8420`으로 둔다.
   그 뒤 `https://pilgrim.delight-house.org/admin`에서 바꾼 비밀번호로 로그인된다.
6. 업데이트: 스냅샷(`./scripts/admin-snapshot.sh`)은 개발 Mac에서 만들어 `main`에 커밋해 둔다.
   Mac mini에서는 `git pull --ff-only` 후
   `docker compose -f web/admin/docker-compose.yml up -d --build --force-recreate`.
   Mac mini의 Docker Compose는 `--build`만으로는 새 이미지를 빌드하고도 컨테이너를 다시 만들지
   않은 적이 있다(2026-11-07). 반영됐는지는 컨테이너 안 스냅샷의 첫 커밋
   (`docker compose -f web/admin/docker-compose.yml exec admin node -e "console.log(require('/app/web/admin/snapshot/commits.json').commits[0].hash)"`)이
   저장소의 `web/admin/snapshot/commits.json` 첫 커밋과 같은지로 확인한다.

비밀번호를 잊으면 `.env`에 `ADMIN_BOOTSTRAP_USERNAME`/`ADMIN_BOOTSTRAP_PASSWORD`를 다시 넣고
`docker compose -f web/admin/docker-compose.yml exec admin node -e "const {DatabaseSync}=require('node:sqlite');new DatabaseSync('/data/admin.sqlite').exec('PRAGMA foreign_keys=ON; DELETE FROM admins')"`
후 재시작하면 bootstrap 값으로 다시 시드된다(세션도 함께 지워진다). 이때도 계정이 다시 admin/admin이
되므로, 터널 hostname을 잠시 끄거나 1–4단계처럼 로컬에서 먼저 비밀번호를 바꾸고 bootstrap 줄을 다시
지운다. `admin-data` 볼륨을 지운 경우(`down -v`)도 마찬가지다.

### 고칠 때 같이 고칠 것

- 앱 흐름이 바뀌면 `web/admin/src/content/flows.ts`의 흐름도를 고친다.
- 타깃이 생기거나 역할이 바뀌면 `web/admin/src/content/modules.ts`의 설명을 고친다. 설명이 없는
  타깃은 아키텍처 화면에 "설명 없음"으로 뜬다.
- 대시보드는 `docs/pre-release-checklist.md`의 최상위 `- [ ]`/`- [x]` 줄과
  `docs/implementation-todo.md` "## 대기 중" 절의 `- **제목**` 줄을 읽는다. 형식을 바꾸면 화면에
  "파싱 실패"가 뜬다.

## 그룹 서버 (`server/`)

비공개 그룹의 서버다. 설계와 운영 결정은 `docs/group-server.md`, API·스키마·worker·제한의
원본은 `openspec/changes/add-private-groups/design.md`. 앱의 루트 `Package.swift`와 분리된
패키지라 `swift build`/`scripts/check.sh`는 Vapor를 컴파일하지 않는다.

| 위치 | 내용 |
| --- | --- |
| `server/PilgrimAPI/` | Foundation만 쓰는 계약 패키지(DTO, `APIErrorCode`, `PostExpiryPolicy`·`AdminVoteRules`·`PhotoLimits`·`InviteCode`). 앱(`JournalGroups`)과 서버가 함께 쓴다 |
| `server/Sources/PilgrimServerCore/` | Vapor 앱 로직(모듈별 폴더, 마이그레이션, worker 루프) |
| `server/Sources/PilgrimServer/` | 진입점: `serve` / `worker` / `migrate` |
| `server/Tests/PilgrimServerTests/` | 서버 테스트. Postgres 테스트는 `TEST_DATABASE_URL`이 있을 때만 돈다 |
| `server/Makefile`, `docker-compose*.yml`, `Dockerfile` | 로컬·운영 실행(arm64 이미지 하나로 api·worker·migrate) |
| `server/scripts/` | 백업·복원(restic → R2)과 launchd 설치 |

### 테스트

```sh
swift test --package-path server/PilgrimAPI     # 계약 패키지 (scripts/check.sh도 돌린다)
make -C server test                             # 계약 + 서버 테스트, Postgres는 Docker
swift test --package-path server                # Postgres 없이: DB 테스트는 건너뛴다
```

- `make -C server test`는 dev Postgres 컨테이너(`127.0.0.1:5433`)만 띄우고 `pilgrim_test` DB를
  만든 뒤 `TEST_DATABASE_URL=postgres://pilgrim:pilgrim@127.0.0.1:5433/pilgrim_test?sslmode=disable`로
  돌린다. 다른 Postgres를 쓰려면 `TEST_DATABASE_URL`을 직접 준다. 하네스는 프로세스마다 스키마를
  지웠다 다시 만들고 테스트마다 TRUNCATE하므로, 이름에 `test`가 없는 DB는 거부한다.
- CI의 `server` job(Linux `swift:6.2-noble`, Postgres 17 서비스)은 `TEST_DATABASE_URL`을 넣어 DB
  테스트를 필수로 돌린다. Phase 1 작업 때는 로컬 Docker가 응답하지 않아 Postgres 테스트 상당수
  (T0.4·S2·S5·S7·S8)를 컴파일만 확인했다 — 실제 통과는 이 job이나 `make -C server test`로 확인한다
  (openspec tasks 3.3).
- `scripts/check.sh`는 `server/`(PilgrimAPI 포함) 소스에도 `swift format lint --strict`를 돌고
  `swift test --package-path server/PilgrimAPI`를 돌린다. Vapor 서버 빌드·테스트는 하지 않는다.

### 로컬 개발 (`make dev`)

```sh
make -C server dev        # .env.dev가 없으면 .env.dev.example을 복사, 이미지 빌드, 마이그레이션, api·worker
make -C server dev-logs   # api·worker 로그
make -C server dev-down
curl -s http://127.0.0.1:3100/api/health
```

- compose 프로젝트 `pilgrim-dev`. api는 `127.0.0.1:3100`, Postgres는 `127.0.0.1:5433`.
  `dev`·`test`·`prod`는 먼저 공유 네트워크 `pilgrim-edge`를 만든다(`make -C server edge-network`,
  멱등).
- `.env.dev`(gitignore)는 버리는 개발 값뿐이다. `DEV_LOGIN_ENABLED=true`라 `POST /api/v1/auth/dev`가
  열린다 — Debug 앱을 `PILGRIM_DEV_APPLE_USER=<아무 이름>`으로 직접 실행하면 Apple 인증 대신
  이것으로 그룹에 로그인한다(`apple_sub = dev:<이름>`). Apple 키는 비워 두면 된다. 실제 Apple
  로그인·푸시·App Store를 로컬에서 시험할 때만 아래 키를 넣는다.
- `TIME_SCALE_DAY_SECONDS`를 줄이면(예 `10`) 기한·투표·유예·초대 만료의 "하루"가 그 초가 된다
  (7일 글이 70초 뒤 사라진다). 운영 설정에서는 서버가 시작을 거부한다.
- 앱 쪽: 그룹이 켜진 빌드(Debug)의 세션은 실제 클라이언트(`URLSessionGroupAPI`)로
  `https://pilgrim.delight-house.org`에 붙는다(`GroupsFeature.defaultAPIFactory`). 그룹 세션
  토큰과 설치 ID는 Keychain `com.dhouse.PilgrimJournal.group-session`
  (`GroupKeychainCredentialStore`)에 기록장 Apple 사용자별로 둔다. 직접 실행한 Debug 앱은
  환경 변수로 바꾼다(Release는 둘 다 읽지 않는다):

  | 변수 | 하는 일 |
  | --- | --- |
  | `PILGRIM_GROUP_SERVER_URL=http://localhost:3100` | 로컬 `make -C server dev` 서버에 붙는다(`/api/v1`은 붙여도 된다) |
  | `PILGRIM_GROUP_API=preview` | 서버 없이 `PreviewGroupAPI`(메모리 안 가짜 서버)로 화면을 본다 |
  | `PILGRIM_GROUPS=0` | 그룹을 끈다 |

  단위 테스트와 SwiftUI 미리보기는 늘 `PreviewGroupAPI`를 쓴다. iOS 시뮬레이터에서 로컬 서버에
  붙으려면 `localhost`가 그대로 Mac을 가리키고, 실기기는 Mac의 LAN 주소를 쓴다.

### 운영 배포 (맥미니)

```sh
make -C server deploy     # 개발 Mac에서: rsync → 맥미니에서 make prod health → 터널 너머 /api/health
make -C server prod       # 맥미니에서: Postgres → 이미지 빌드 → migrate → api·worker 재생성
make -C server prod-logs | prod-ps | prod-down | health
```

- 맥미니는 `~/.ssh/config`의 `delight`(`DEPLOY_HOST`), 배포 폴더는 `~/Developments/pilgrim-server`
  (`DEPLOY_DIR`, git checkout 아님, `~/Documents` 밖). `rsync --delete`가 폴더를 관리하고
  `.env.*`는 어느 쪽에서도 복사·삭제하지 않는다.
- compose 프로젝트 `pilgrim-prod`(놀담 `noldam-prod`과 프로젝트·Postgres·볼륨·`.env.prod`·백업·
  launchd 작업 모두 분리). api만 `127.0.0.1:3100`에 열고 Postgres는 포트를 열지 않는다. 사진은
  `media` 볼륨(`/data/media`).
- `make prod`는 마이그레이션이 실패하면 거기서 멈춰 옛 api가 계속 돈다. 맥미니 compose가 새 빌드
  뒤에도 옛 컨테이너를 둔 적이 있어 api·worker는 항상 `--force-recreate`한다. Postgres는 다시
  만들지 않는다.
- 터널 경로 규칙을 넣기 전에는 `make -C server deploy DEPLOY_HEALTH_URL=`로 공개 확인을 건너뛴다.

### 운영 설정 (`server/.env.prod`)

맥미니 배포 폴더에서 `cp .env.prod.example .env.prod`, 값을 채우고 `chmod 600 .env.prod`.
**커밋하지 않는다.** 모든 비밀 값은 운영자 암호 관리자에도 둔다(다른 곳에서 복원할 때 필요).
이름은 `server/Sources/PilgrimServerCore/Common/AppConfig.swift`와 같다.

| 변수 | 내용 |
| --- | --- |
| `POSTGRES_USER`·`POSTGRES_PASSWORD`·`POSTGRES_DB` | compose가 `DATABASE_URL`을 만든다(비밀번호는 영문·숫자만) |
| `APP_ENV=production`, `PUBLIC_BASE_URL`, `LOG_LEVEL` | `APP_VERSION`은 `make deploy`가 넣는다 |
| `JWT_SECRET`, `MEDIA_URL_SECRET` | 32바이트 이상. 없으면 운영 설정에서 시작을 거부한다 |
| `ADMIN_API_TOKEN` | 운영자 라우트 `X-Admin-Token`. 비우면 그 라우트가 없다(404). 콘솔 `web/admin/.env`와 같은 값 |
| `DEV_LOGIN_ENABLED=false`, `TIME_SCALE_DAY_SECONDS=86400` | 다르면 운영 설정에서 시작을 거부한다 |
| `SUBSCRIPTION_REQUIRED=false` | 출시 값. 구독을 켤 때만 `true` |
| `MIN_CLIENT_VERSION` | 이보다 낮은 앱은 426. 비우면 제한 없음 |
| `REPORT_WEBHOOK_URL` | 선택. 새 신고를 본문 없이 알린다 |
| `APPLE_TEAM_ID`, `APPLE_SIWA_KEY_ID`, `APPLE_SIWA_PRIVATE_KEY` | Sign in with Apple 키(code 교환·토큰 폐기) |
| `APPLE_TOKEN_ENC_KEY` | 32바이트(`openssl rand -hex 32`). 잃으면 저장된 Apple 토큰을 못 열어 계정 삭제 때 폐기할 수 없다 |
| `APNS_KEY_ID`, `APNS_PRIVATE_KEY` | APNs 인증 키 하나가 sandbox·production, 두 번들을 모두 맡는다 |
| `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID`, `APPSTORE_PRIVATE_KEY` | In-App Purchase 키(App Store Server API 재확인) |
| `RATE_LIMIT_<이름>=<횟수>/<초>` | 비우면 `PilgrimAPI` 기본값 |

비밀 값은 각각 따로 만든다(`openssl rand -hex 32`). `.p8` 내용은 줄바꿈을 `\n`으로 바꿔 한 줄로
넣는다: `awk 'NF {printf "%s\\n", $0}' AuthKey_XXXXXXXXXX.p8`. `server/scripts/set-apple-key.sh`가 이 변환을 하고,
키를 화면에 띄우지 않고 해당 줄만 채운다(키 하나에 Sign in with Apple과 APNs를 함께 켰다면 한 번에):

```sh
ssh delight 'cd Developments/pilgrim-server && ./scripts/set-apple-key.sh siwa,apns <KEY_ID>' \
  < ~/Downloads/AuthKey_<KEY_ID>.p8
```

### Apple 키와 App Store Connect

- **Sign in with Apple 키:** Certificates, Identifiers & Profiles › Keys에서 Sign in with Apple을
  켜고 primary App ID `com.dhouse.PilgrimJournal`에 묶는다(Debug App ID는 같은 그룹에 묶여 있어야
  한다, 위 "식별자"). 서버는 이 키로 ES256 client secret을 만들어 code 교환과 `/auth/revoke`를 한다.
- **APNs 키:** 같은 화면에서 Apple Push Notifications service를 켠 키. topic은 기기 행의 번들 ID,
  환경은 앱이 등록 때 보낸 값(Debug·TestFlight 구분)이다.
- **In-App Purchase 키:** App Store Connect › 사용자 및 액세스 › 통합 › In-App Purchase. Issuer ID도
  같은 화면에 있다.
- **App Store Server Notifications V2:** 앱 정보의 서버 URL(Production·Sandbox 모두)을
  `https://pilgrim.delight-house.org/api/appstore/notifications`로 둔다.
- 구독 상품 `com.dhouse.PilgrimJournal.groups.monthly`(월간, ₩2,000 / $1.99 가격 단계)를 App Store
  Connect에 만든다.
- `.p8` 파일은 저장소에 넣지 않는다. `server/.env.prod`와 운영자 암호 관리자에만 둔다.

### Cloudflare Tunnel

`pilgrim.delight-house.org` 하나를 콘솔과 나눠 쓴다. 터널에 그룹 서버 경로 규칙을 **콘솔 규칙보다
앞에** 넣는다(`docs/group-server.md` "터널").

- 로컬 `~/.cloudflared/config.yml`이면(지금 맥미니) `ingress`의 콘솔 항목 위에:

  ```yaml
  - hostname: pilgrim.delight-house.org
    path: ^/(api/|i/|\.well-known/)
    service: http://localhost:3100
  - hostname: pilgrim.delight-house.org
    service: http://localhost:8420
  ```

  `cloudflared tunnel --config ~/.cloudflared/config.yml ingress validate`로 확인하고 재시작한다
  (재시작 중 같은 터널을 쓰는 SSH와 noldam API도 잠깐 끊긴다, 위 "관리 콘솔" 5단계).
- 대시보드 관리형이거나 콘솔 compose의 `cloudflared`(`--profile tunnel`)를 쓰면 Public Hostname에
  같은 호스트·같은 path로 `http://pilgrim-api:3100` 규칙을 콘솔 규칙 위에 둔다.
- Cloudflare 봇 차단·챌린지 규칙이 `/api`와 `/.well-known`을 막지 않게 예외를 둔다(앱 요청과
  Apple의 AASA 요청).
- `/internal/admin/v1`은 규칙에 없으므로 인터넷에서 오면 콘솔로 가 404가 된다. 서버도 `Cf-Ray`·
  `Cf-Connecting-IP`가 붙은 요청을 403으로 거부한다.
- 확인: `curl -s https://pilgrim.delight-house.org/api/health`, `curl -sI
  https://pilgrim.delight-house.org/.well-known/apple-app-site-association`(JSON, 리디렉트 없음),
  `https://pilgrim.delight-house.org/admin`이 여전히 콘솔인지.

### 백업과 복원 (restic → Cloudflare R2)

맥미니에서 매일 04:00 DB 덤프와 사진 볼륨을 restic 스냅샷 하나로 R2에 올리고 7일 넘은 것을 지운다
(`--keep-within 7d`, 개인정보 처리방침의 "최대 7일"). 로컬 덤프도 `~/backups/pilgrim/db`에 7개 남는다.

1. `brew install restic`.
2. 설정: `mkdir -p ~/.config/pilgrim-backup && cp server/scripts/backup.env.example
   ~/.config/pilgrim-backup/env && chmod 600 ~/.config/pilgrim-backup/env`. `RESTIC_REPOSITORY`
   (R2 S3 엔드포인트), 이 버킷에만 쓰기 권한이 있는 R2 토큰(`AWS_ACCESS_KEY_ID`·
   `AWS_SECRET_ACCESS_KEY`), restic 비밀번호(`RESTIC_PASSWORD_FILE` 또는 `RESTIC_PASSWORD_COMMAND`),
   선택으로 `BACKUP_HEALTHCHECK_URL`. restic 비밀번호는 맥미니 밖에도 보관한다 — 없으면 백업을
   읽을 수 없다.
3. 맥미니 배포 폴더에서:

   ```sh
   make backup-init        # R2에 restic 저장소 만들기 (한 번, 이미 있으면 그대로)
   make backup             # 지금 한 번 백업
   make backup-schedule    # 매일 04:00 launchd 작업 설치 (com.dhouse.pilgrim.backup)
   make backup-snapshots   # 스냅샷 목록
   make backup-unschedule
   ```

4. 복원(`server/scripts/restore.sh --help`):

   ```sh
   make restore ARGS='--into dev'                                   # 최신 스냅샷을 개발 Mac 로컬 스택에
   make restore ARGS='--into prod --confirm pilgrim-prod --snapshot <ID>'
   ```

   `--into dev`는 worker를 멈춘 채 둔다(`--start-worker`로만 켠다) — 복원한 푸시 대기열이나 Apple
   토큰 폐기 대기열이 개발 기기에서 실제 사용자에게 가지 않게. 복원 중 임시 폴더는 개인정보를
   담으므로 끝나면 지운다. 한 달에 한 번 개발 Mac에서 `--into dev`로 복원해 본다.

### 관리 콘솔 연결 (신고 페이지)

- 콘솔(`web/admin`, 프로젝트 `pilgrim-admin`)과 api가 공유 Docker 네트워크 `pilgrim-edge`에 함께
  있고, 콘솔은 `http://pilgrim-api:3100/internal/admin/v1`을 부른다. 네트워크를 먼저 만든다
  (`make -C server edge-network`).
- 콘솔 `web/admin/.env`에 `ADMIN_API_TOKEN`(서버 `.env.prod`와 같은 값, 32바이트 이상)을 넣는다.
  주소가 다르면 `ADMIN_API_URL`(기본 `http://pilgrim-api:3100`). 토큰 없이 주소만 있으면 콘솔이
  시작을 거부한다. 지금 `web/admin/.env.example`에는 이 두 줄이 없다(Phase 2에서 더한다).
- 조치마다 콘솔이 로그인한 관리자 이름을 `X-Admin-Actor`로 보내 서버 `moderation_log`에 남는다.

### StoreKit 테스트 설정

- `PilgrimJournal/PilgrimJournal.storekit`에 구독 그룹과 `com.dhouse.PilgrimJournal.groups.monthly`
  (P1M, ₩2,000)가 있다. 설정 파일 검사는 iOS 시뮬레이터 테스트
  (`GroupSubscriptionStoreKitTests`)에서 돈다. 상품 불러오기와 구매 테스트는 앱이 호스트하는 테스트
  번들이 필요해(`xctest`에는 StoreKit이 상품·거래를 주지 않을 수 있다) 상품이 오지 않으면 건너뛴다 —
  CI의 시뮬레이터에서는 건너뛰고 로컬 시뮬레이터에서는 상품 불러오기가 통과한 적이 있다.
- 앱 scheme(`PilgrimJournalApp.xcscheme`)의 Run이 이 파일을 StoreKit Configuration으로 쓴다.
  세션의 `GroupsController`는 `GroupSubscriptionController.shared`에 붙고(`attach(to:)`,
  `Transaction.updates` 리스너), 구독이 필요하면 `GroupSubscriptionSheet`가 뜬다. Xcode에서 Debug로
  실행하면 로컬 StoreKit으로 구매를 시험하고, 샌드박스 계정 시험은 서명한 기기 빌드에서 한다
  (`docs/device-verification.md` 세션 H). 서버가 `SUBSCRIPTION_REQUIRED=false`(출시 값)인 동안은
  구독 화면이 뜨지 않는다.
- 서버 쪽 검증은 `SUBSCRIPTION_REQUIRED`와 상관없이 돈다. 구독 화면과 402 차단은 `true`일 때만
  보인다.

## 릴리스 아카이브

### iCloud 동기화 폴더에서 archive 하지 않기

iCloud Drive가 동기화하는 폴더(예: "데스크탑 및 문서 폴더" 동기화를 켠 `~/Documents`,
`~/Desktop`)는 file provider가 관리한다. 그 안에서 archive 하면 빌드 산출물에
`com.apple.FinderInfo`와
`com.apple.fileprovider.fpfs#P` 확장 속성이 계속 다시 붙고, codesign은
`resource fork, Finder information, or similar detritus not allowed`로
실패한다. 소스에 `xattr -cr`를 돌려도 빌드 중 다시 붙으므로 근본 해결이 아니다.

**archive와 derived data는 동기화되지 않는 경로(아래처럼 `mktemp -d`)에 만든다.**
저장소는 지금 `~/Developments` 아래라 동기화 밖이지만, 저장소 위치와 상관없이 이렇게
한다. 서명이 끝난 아카이브를 `.release/`로 복사하는 것은 안전하다.

### 절차

0. **`docs/known-issues.md`의 릴리스 게이트를 먼저 통과한다.** 편집기 입력이
   씹히는 문제가 반복해서 되살아나고 있고, 자동화 테스트가 잡지 못한다.
   긴 기록에서 Release 빌드로 타이핑을 확인하지 않은 채 올리지 않는다.
1. 빌드 번호를 올린다. `PilgrimJournal.xcodeproj`의 `CURRENT_PROJECT_VERSION`
   두 곳(Debug·Release)을 함께 바꾸고 `build: bump TestFlight build to N`으로
   커밋한다.
2. `./scripts/check.sh`가 통과하는지 확인한다.
3. 동기화 밖 경로에 두 플랫폼 아카이브를 만든다.

   ```sh
   BUILD_ROOT=$(mktemp -d)
   for platform in iOS macOS; do
     xcodebuild \
       -project PilgrimJournal/PilgrimJournal.xcodeproj \
       -scheme PilgrimJournalApp \
       -configuration Release \
       -destination "generic/platform=$platform" \
       -archivePath "$BUILD_ROOT/PilgrimJournal-$platform.xcarchive" \
       -derivedDataPath "$BUILD_ROOT/DerivedData-$platform" \
       archive
   done
   ```

4. 아카이브의 `CFBundleVersion`이 의도한 빌드 번호인지 확인한 뒤
   `.release/build<N>/`으로 복사한다. `.release/`는 Git에서 무시된다.
5. `PilgrimJournal/AppStoreExportOptions.plist`로 export·upload 한다. **지금 쓰는 경로는
   Xcode 계정 인증이다.** build 28·29를 이 방식으로 올렸다. Xcode → Settings →
   Accounts에 App Store Connect 권한이 있는 Apple 계정이 있어야 한다.

   ```sh
   for platform in iOS macOS; do
     xcodebuild -exportArchive \
       -archivePath "$BUILD_ROOT/PilgrimJournal-$platform.xcarchive" \
       -exportOptionsPlist PilgrimJournal/AppStoreExportOptions.plist \
       -exportPath "$BUILD_ROOT/export-$platform" \
       -allowProvisioningUpdates
   done
   ```

   **대안: App Store Connect API 키.** Xcode에 Apple 계정이 없어도 된다(build 13을 이
   방식으로 올렸다). 위 명령에 다음 세 옵션을 더한다.

   ```sh
       -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
       -authenticationKeyID <KEYID> \
       -authenticationKeyIssuerID "$ASC_ISSUER_ID"
   ```

   Issuer ID는 App Store Connect → 사용자 및 액세스 → 통합 →
   App Store Connect API 상단의 UUID다. **저장소에 커밋하지 않는다.**
   `.p8` 키도 `~/.appstoreconnect/private_keys/`에만 둔다.

   #### `Failed to Use Accounts`가 나오면

   이 오류는 원인이 두 가지이고 **로그를 봐야 구분된다.** 오류 메시지 자체는
   같지만 `.xcdistributionlogs/IDEDistribution.standard.log`에 실제 이유가 남는다.

   - `Failed to find an account with App Store Connect access for team ...`
     → **Xcode에 App Store Connect 권한이 있는 Apple 계정이 없다.** Mac 잠금과
     무관하다. `xcodebuild`는 계정을 추가할 수 없으므로 Xcode → Settings →
     Accounts에 계정을 추가하거나 위 API 키 대안을 쓴다.
   - Keychain 접근 거부가 로그에 보이면 → 그때가 Mac 잠금 문제다. 잠금을 풀고
     다시 실행한다.

   서명에는 **Apple Distribution** 인증서가 필요하다. `security find-identity -v
   -p codesigning`에 Development만 있으면 `-allowProvisioningUpdates`와 계정
   접근으로 자동 생성하게 하거나 Xcode에서 만들어야 한다.

6. TestFlight에서 처리 완료를 확인하고 실기기 설치·업데이트·데이터 보존을
   smoke test 한다.
