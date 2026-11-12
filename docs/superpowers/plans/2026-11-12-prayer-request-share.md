# 일기 → 기도제목 나누기 (1차) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 기록 하나에서 온디바이스 모델이 기도제목 1~3개를 제안하고, 사용자가 확인·수정하고 공유 언어(한국어/영어)를 골라 시스템 공유 시트나 복사로 글을 내보낸다.

**Architecture:** 실험실(`ShareCardEval`)에서 검증한 순수 로직(언어 감지, 프롬프트, 줄 정리, 이름표 변환)을 새 라이브러리 `JournalShareDrafts`로 옮기고, 모델과 번역기는 프로토콜 뒤에 둔다. 앱은 `PrayerRequestShareModel`(상태) + 시트 하나만 더한다. 아무것도 저장·동기화·업로드하지 않는다.

**Tech Stack:** Swift 6.2 패키지, SwiftUI, FoundationModels(iOS/macOS 26, 약한 연결), Translation(`.translationTask`, iOS 18/macOS 15), XCTest.

**Spec:** `docs/roadmap.md`의 2026-11-11~12 절(프롬프트 비교, 양질의 기도제목 기준, 일기 언어와 공유 언어)과 PR #22 `openspec/changes/add-share-card-phase1/`(design.md §2 가용성, §3 파이프라인, §7 저장 규칙). 둘이 다르면 로드맵이 이긴다 — 아래 "설계 문서와 달라진 점" 참고.

## Global Constraints

- 배포 대상은 그대로 iOS 17 / macOS 14. FoundationModels·Translation 없는 기기에서도 앱이 실행돼야 한다.
- 일기 원문, 초안, 모델 응답, 번역 결과, 공유 이력을 저장·동기화·업로드·로그하지 않는다(`os_log` 포함). SwiftData 모델, CloudKit 스키마, 백업 형식 변경 없음.
- 일기는 쓰인 언어로 처리한다: `RequestLanguage.detect`(한글 글자 ≥ 1/3 → 한국어). 한국어 일기를 영어로 돌려 처리하지 않는다.
- 모델 호출: 호출마다 새 세션, greedy, 관문 8토큰·추출 600토큰, 본문은 앞 3,000자까지, 결과는 최대 3줄.
- 프롬프트 문구는 `2026-11-11.1` 그대로 옮긴다. 바꾸면 버전을 올리고 실험실 21개 일기로 다시 본다.
- 이름은 막지 않는다(비공개 그룹, 2026-11-12 결정). 시트가 확인 단계이고, 카드는 기본으로 선택된 상태다.
- 새 화면 문구는 한국어 키 + `Sources/PilgrimJournal/Localizable.xcstrings`의 `en` 값. 프롬프트와 주제 이름은 현지화 대상이 아니다.
- 커밋 전 `./scripts/check.sh`, import를 바꾼 뒤에는 서명 없는 Xcode 빌드(CLAUDE.md의 명령).

## 설계 문서(PR #22)와 달라진 점

| 설계 문서 | 이 계획 |
|---|---|
| 카드 3종(기도제목·간증·독후감), 이미지/글 | 기도제목만, 글만 |
| 한국어 프롬프트 하나 | 한국어·영어 프롬프트, 공유 언어 선택(번역) |
| 제3자 판정 모델 호출, 경고, 선택 해제로 시작 | 판정 없음, 선택된 상태로 시작, 안내 문구 한 줄 |
| 타깃 이름 `JournalShare` | `JournalShareDrafts` (`JournalSharing`과 혼동 방지) |
| 데드라인 추출·시트 | 1차에서 제외 |

## Review Focus

1. **아주 긴 기록(3,000자 초과, 10,000자 이상)** → 앞 3,000자만 모델에 보내고 정상적으로 제안이 나온다. (Task 2)
2. **모델이 형식을 안 지킨 답**(불릿 없음, 중간에 끊긴 줄, 같은 줄 40번) → 쓸 줄만 남기고, 하나도 없으면 직접 쓰기로 넘어간다. 오류 화면 없음. (Task 2)
3. **사용자가 고친 뒤 늦게 도착한 결과**(초안·번역) → 사용자가 손댄 줄은 덮어쓰지 않는다. (Task 5)
4. **번역 언어 팩 없음·번역 실패·iOS 17** → 원문 언어 그대로 두고 한 줄로 알린다. 공유는 계속 가능하다. (Task 5)
5. **모델을 못 쓰는 기기**(OS 낮음, Apple Intelligence 꺼짐, 모델 내려받는 중) → 같은 시트가 빈 직접 쓰기로 열린다. iOS 17 기기에서 앱이 실행된다. (Task 3, 7)

---

### Task 0: 실험실 변경을 main에 올리기

**Files:** 없음(브랜치 작업). 워크트리 `.claude/worktrees/prompt-lab`, 브랜치 `feat/prayer-request-prompt-lab`(PR #21).

- [ ] **Step 1:** 워크트리의 미커밋 변경(관문, 후처리, `RequestLanguage.swift`, `RequestTranslator.swift`, 영어 일기, 로드맵, 이 계획)을 커밋한다. 메시지: `feat(eval): gate, tidy, per-language prompts and share-language translation in the prompt lab`.
- [ ] **Step 2:** `git merge origin/main`(16커밋 뒤처짐). `Package.swift`와 `docs/roadmap.md` 충돌은 양쪽을 모두 살린다.
- [ ] **Step 3:** `./scripts/check.sh` → 통과. `swift run ShareCardEval --serve`로 페이지가 열리고 일기 25개가 보이는지 확인.
- [ ] **Step 4:** PR #21을 푸시하고 머지한다(사용자 승인 필요). 이후 작업 브랜치 `feat/prayer-request-share`를 main에서 만든다.

### Task 1: `JournalShareDrafts` 타깃과 순수 로직 이동

**Files:**
- Modify: `Package.swift` — `.library(name: "JournalShareDrafts", …)`, 타깃 `JournalShareDrafts`(의존 없음), 테스트 타깃 `JournalShareDraftsTests`; `ShareCardEval`에 의존 추가.
- Create: `Sources/JournalShareDrafts/RequestLanguage.swift` (← `Sources/ShareCardEval/RequestLanguage.swift`의 enum)
- Create: `Sources/JournalShareDrafts/PrayerRequestPrompts.swift` (한·영 지시문/요청문/관문, `version`, `fill`)
- Create: `Sources/JournalShareDrafts/PrayerRequestLines.swift` (`requestLines`, `withoutRepeats`, `sharedEnding`, `splitLabel`, `translatedLabel`, `polishTranslation`, `gateSaysNo`)
- Modify: `Sources/ShareCardEval/SharePrompts.swift`, `RequestLanguage.swift` — 옮긴 것은 지우고 `import JournalShareDrafts`.
- Test: `Tests/JournalShareDraftsTests/PrayerRequestLinesTests.swift`, `RequestLanguageTests.swift` (← `Tests/ShareCardEvalTests/DatePhraseResolverTests.swift`의 해당 테스트 7개 이동)

**Interfaces:**
- Produces (모두 `public`):
  - `enum RequestLanguage: String, Codable, Sendable, CaseIterable { case korean = "ko", english = "en"; static func detect(_ text: String) -> RequestLanguage; var locale: Locale.Language }`
  - `enum PrayerRequestPrompts { static let version = "2026-11-11.1"; static func instructions(_: RequestLanguage) -> String; static func template(_: RequestLanguage) -> String; static func gateInstructions(_: RequestLanguage) -> String; static func gateTemplate(_: RequestLanguage) -> String; static func fill(_ template: String, title: String, date: String, body: String) -> String }`
  - `enum PrayerRequestLines { static func parse(_ answer: String) -> [String]; static func withoutRepeats(_: [String], limit: Int = 3) -> [String]; static func sharedEnding(_: String) -> String; static func splitLabel(_: String) -> (body: String, label: String?); static func translatedLabel(_: String, to: RequestLanguage) -> String; static func polishTranslation(_: String, in: RequestLanguage, cutEnding: Bool) -> String; static func gateSaysNo(_: String?) -> Bool }`

- [ ] **Step 1:** 테스트 파일을 새 타깃으로 옮기고 이름만 새 타입으로 바꾼다(`SharePrompts.tidyRequestLines(x)` → `PrayerRequestLines.withoutRepeats(x).map(PrayerRequestLines.sharedEnding)`). `swift test --filter JournalShareDraftsTests` → 컴파일 실패.
- [ ] **Step 2:** `Package.swift`에 타깃을 더하고 코드를 옮긴다. 문구는 한 글자도 바꾸지 않는다. `fill`은 `{날짜}` `{제목}` `{본문}` 치환.
- [ ] **Step 3:** `ShareCardEval`이 새 타입을 쓰도록 고친다(`SharePrompts`에는 분류기·카드 프롬프트만 남는다).
- [ ] **Step 4:** `swift test --filter JournalShareDraftsTests` → PASS, `swift test --filter ShareCardEvalTests` → PASS, `swift build` → 성공.
- [ ] **Step 5:** Commit `refactor(share): move prayer-request prompts and line handling into JournalShareDrafts`.

### Task 2: 초안 타입과 파이프라인 (가짜 모델로 테스트)

**Files:**
- Create: `Sources/JournalShareDrafts/PrayerRequestDraft.swift`
- Create: `Sources/JournalShareDrafts/PrayerRequestPipeline.swift`
- Test: `Tests/JournalShareDraftsTests/PrayerRequestPipelineTests.swift`

**Interfaces:**
- Consumes: Task 1 전부.
- Produces:
  - `enum PrayerRequestTopic: String, CaseIterable, Sendable { case health, family, work, study, finances, relationships, faith, career; init?(label: String); func name(in: RequestLanguage) -> String }` — 한국어 이름은 건강·가정·직장·학업·재정·관계·신앙·진로.
  - `struct PrayerRequestSource: Sendable { let title: String; let dateText: String; let body: String }`
  - `struct PrayerRequestDraft: Identifiable, Equatable, Sendable { let id: UUID; var text: String; var language: RequestLanguage; var topic: PrayerRequestTopic?; var who: String? }`
  - `protocol ShareLanguageModel: Sendable { func respond(instructions: String, prompt: String, maximumTokens: Int) async throws -> String }`
  - `enum PrayerRequestOutcome: Equatable, Sendable { case drafts([PrayerRequestDraft]); case nothingToPrayFor; case noUsableAnswer }`
  - `struct PrayerRequestPipeline: Sendable { static let bodyLimit = 3_000; init(model: any ShareLanguageModel); func drafts(for: PrayerRequestSource) async -> PrayerRequestOutcome }`

- [ ] **Step 1: 실패하는 테스트 작성** — `FakeModel`(받은 프롬프트를 기록하고 정해 둔 답을 돌려줌)로:

```swift
func testKoreanDiaryBecomesTidiedDraftsWithTopics() async {
    // gate "예", 답 "- 어머니 검사 결과가 좋도록 기도해 주세요 (어머니/건강)\n- 동생과 다시 이야기하도록 기도해 주세요 (나/관계)"
    // → .drafts 2개: text "어머니 검사 결과가 좋도록", topic .health, who "어머니", language .korean
}
func testEnglishDiaryUsesEnglishPromptsAndKeepsPrayThat() async   // instructions == PrayerRequestPrompts.instructions(.english), text "Pray that the surgery goes well"
func testGateNoSkipsTheDraftCall() async                          // 답 "아니오" → .nothingToPrayFor, 호출 1번
func testGateFailureStillDrafts() async                           // gate가 throw → 추출은 진행
func testLongBodyIsCutToTheLimit() async                          // body 10,000자 → 프롬프트에 든 본문 3,000자
func testLoopedAnswerKeepsThreeDistinctLines() async              // 같은 줄 40번 + 다른 줄 2개 → 3개
func testAnswerWithoutBulletsIsNoUsableAnswer() async             // "없음", "", 산문 → .noUsableAnswer
func testTruncatedLastLineIsDropped() async                       // 마지막 줄 "- Pray that I find a" (이름표 없고 다른 줄엔 있음) → 버림
func testUnknownTopicLeavesTopicNil() async                       // "(나/가게)" → topic nil, who "나"
func testDraftCallFailureIsNoUsableAnswer() async                 // draft가 throw → .noUsableAnswer
```

- [ ] **Step 2:** `swift test --filter PrayerRequestPipelineTests` → FAIL (타입 없음).
- [ ] **Step 3: 구현.** 순서: 언어 감지(제목+본문) → 본문 자르기 → 관문(8토큰; `gateSaysNo`면 끝, 오류면 계속) → 추출(600토큰) → `parse` → 끊긴 줄 버리기(이름표 있는 줄이 하나라도 있으면 이름표 없는 마지막 줄 제거) → `withoutRepeats` → 한국어면 `sharedEnding` → `splitLabel`로 `who`/`topic` 분리(본문에는 이름표를 남기지 않는다).
- [ ] **Step 4:** `swift test --filter JournalShareDraftsTests` → PASS.
- [ ] **Step 5:** Commit `feat(share): prayer-request pipeline over an injected language model`.

### Task 3: FoundationModels 연결, 가용성, 실험실을 같은 파이프라인으로

**Files:**
- Create: `Sources/JournalShareDrafts/ShareModelAvailability.swift`
- Create: `Sources/JournalShareDrafts/FoundationModelsShareLanguageModel.swift` (`#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)`)
- Create: `Sources/JournalShareDrafts/ShareDraftFeature.swift`
- Modify: `Sources/ShareCardEval/PromptLabServer.swift`, `SharePipeline.swift` — 기본 프롬프트일 때는 `PrayerRequestPipeline`을 쓴다(지시문을 고친 실행은 지금 경로 유지).
- Test: `Tests/JournalShareDraftsTests/ShareModelAvailabilityTests.swift`

**Interfaces:**
- Produces:
  - `enum ShareModelAvailability: Equatable, Sendable { case available, unsupportedOS, deviceNotEligible, appleIntelligenceOff, modelNotReady, disabled }`
  - `enum ShareDraftFeature { static let onDeviceDraftsEnabled = true; static func availability() -> ShareModelAvailability; static func makeModel() -> (any ShareLanguageModel)? }` — `makeModel`은 `availability() == .available`일 때만 값이 있다.
  - `struct FoundationModelsShareLanguageModel: ShareLanguageModel` — `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, 호출마다 새 `LanguageModelSession`, `GenerationOptions(sampling: .greedy, maximumResponseTokens:)`.

- [ ] **Step 1:** 테스트: `ShareModelAvailability`로의 매핑 함수 `static func map(osSupported: Bool, reason: UnavailableReasonStandIn?) -> ShareModelAvailability`를 순수 함수로 빼고 5개 경우를 단언(`.deviceNotEligible`, `.appleIntelligenceNotEnabled`, `.modelNotReady`, OS 미지원, 스위치 꺼짐).
- [ ] **Step 2:** 구현. `SystemLanguageModel.Availability.UnavailableReason`의 실제 케이스 이름은 Xcode 26.2 SDK에서 확인하고 `@unknown default`는 `.modelNotReady`로 둔다.
- [ ] **Step 3:** 실험실 연결 후 `swift run ShareCardEval --serve`에서 `father-dementia`, `camping`, `en-layoff`를 돌려 이전과 같은 줄이 나오는지 확인(관문·후처리 켠 상태).
- [ ] **Step 4:** 약한 연결 확인: `xcodebuild … -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` 뒤 `otool -l <앱 바이너리> | grep -A2 LC_LOAD_WEAK_DYLIB`에 FoundationModels가 보여야 한다. 안 보이면 `Package.swift` 타깃에 `linkerSettings: [.unsafeFlags(["-weak_framework", "FoundationModels"])]` 대신 Xcode 앱 타깃의 Other Linker Flags에 `-weak_framework FoundationModels`를 넣는다.
- [ ] **Step 5:** Commit `feat(share): on-device model adapter and availability for prayer-request drafts`.

### Task 4: 공유할 글 만들기

**Files:**
- Create: `Sources/JournalShareDrafts/PrayerRequestShareText.swift`
- Test: `Tests/JournalShareDraftsTests/PrayerRequestShareTextTests.swift`

**Interfaces:**
- Produces: `enum PrayerRequestShareText { static func text(for drafts: [PrayerRequestDraft]) -> String }` — 빈 줄(공백만)은 빼고, 한 개면 그 문장만, 여러 개면 줄마다 `"• "`를 붙여 줄바꿈으로 잇는다. 이름표·제목·날짜·앱 이름은 넣지 않는다.

- [ ] **Step 1:** 테스트 3개: 한 개 → 문장 그대로 / 세 개 → `"• a\n• b\n• c"` / 빈 문자열과 공백만 있는 초안은 제외, 모두 비면 `""`.
- [ ] **Step 2:** FAIL 확인 → 구현 → PASS.
- [ ] **Step 3:** Commit `feat(share): plain-text form of selected prayer requests`.

### Task 5: 앱 상태 `PrayerRequestShareModel`

**Files:**
- Create: `Sources/PilgrimJournal/Share/PrayerRequestShareModel.swift`
- Modify: `Package.swift` — `PilgrimJournal`과 `PilgrimJournalTests`에 `JournalShareDrafts` 의존 추가.
- Modify: `PilgrimJournal/PilgrimJournal.xcodeproj/project.pbxproj` — `packageProductDependencies`(L90-97)에 `JournalShareDrafts` 추가.
- Test: `Tests/PilgrimJournalTests/PrayerRequestShareModelTests.swift`

**Interfaces:**
- Consumes: `PrayerRequestPipeline`, `PrayerRequestDraft`, `PrayerRequestShareText`, `ShareModelAvailability`, `PrayerRequestLines.polishTranslation`.
- Produces:
  - `protocol ShareTextTranslating: Sendable { func translate(_ texts: [String], from: RequestLanguage, to: RequestLanguage) async throws -> [String] }`
  - `@MainActor final class PrayerRequestShareModel: ObservableObject`
    - `enum Phase: Equatable { case drafting, ready, manual(reason: ManualReason) }`, `enum ManualReason { case modelUnavailable(ShareModelAvailability), nothingToPrayFor, noUsableAnswer, userChoice }`
    - `struct Row: Identifiable, Equatable { let id: UUID; var text: String; var language: RequestLanguage; var topic: PrayerRequestTopic?; var isSelected: Bool; var isEdited: Bool }`
    - `@Published private(set) var phase: Phase`, `@Published var rows: [Row]`, `@Published private(set) var shareLanguage: RequestLanguage`, `@Published private(set) var notice: String?`
    - `init(source: PrayerRequestSource, pipeline: PrayerRequestPipeline?, availability: ShareModelAvailability)`
    - `func start() async`, `func writeManually()`, `func addRow()`, `func edit(_ id: UUID, text: String)`
    - `func translationRequest(to: RequestLanguage) -> (texts: [String], ids: [UUID], from: RequestLanguage)?` — 대상 언어와 다른 줄만.
    - `func applyTranslation(_ texts: [String], for ids: [UUID], to: RequestLanguage)`, `func translationFailed(_ message: String)`
    - `var shareText: String`, `var canShare: Bool`, `var hasEdits: Bool`

- [ ] **Step 1: 실패하는 테스트**

```swift
func testStartShowsDraftsSelected() async            // pipeline → .drafts 2개 ⇒ phase .ready, rows 2개 모두 isSelected, shareLanguage == 일기 언어
func testUnavailableModelOpensManualWithOneEmptyRow() async  // pipeline nil, .appleIntelligenceOff ⇒ .manual(.modelUnavailable(.appleIntelligenceOff)), rows.count == 1
func testNothingToPrayForOpensManual() async         // ⇒ .manual(.nothingToPrayFor)
func testWriteManuallyDuringDraftingIgnoresLateDrafts() async // start 중 writeManually() ⇒ 늦게 온 초안이 rows를 바꾸지 않는다
func testEditedRowIsNotOverwrittenByTranslation()    // edit 후 applyTranslation ⇒ 그 줄은 그대로, 나머지만 바뀜
func testTranslationRequestSkipsRowsAlreadyInTarget()
func testApplyTranslationPolishesAndSetsLanguage()   // "Please pray that x." → "Pray that x", row.language == .english, shareLanguage == .english
func testTranslationFailureKeepsTextAndSetsNotice()  // notice != nil, rows 불변, shareLanguage 불변
func testShareTextUsesOnlySelectedNonEmptyRows()
func testCanShareIsFalseWithNothingSelected()
```

- [ ] **Step 2:** FAIL 확인 → 구현(늦은 결과는 `start()` 시작 때 잡은 세대 번호가 그대로일 때만 반영) → `swift test --filter PrayerRequestShareModelTests` PASS.
- [ ] **Step 3:** Commit `feat(share): share-sheet state for prayer requests`.

### Task 6: 시트 화면과 진입점

**Files:**
- Create: `Sources/PilgrimJournal/Share/PrayerRequestShareSheet.swift`
- Modify: `Sources/PilgrimJournal/Entry/EntryDetailView.swift:87-96` (`detailActions`에 버튼)
- Modify: `Sources/PilgrimJournal/Entry/MacEntryEditorView.swift:224-234` (`기록 정보` 메뉴에 항목)
- Modify: `Sources/PilgrimJournal/EntryRowViews.swift:79-105` (컨텍스트 메뉴에 항목)
- Modify: `Sources/PilgrimJournal/Localizable.xcstrings`
- Modify: `Sources/PilgrimJournal/AppUsageGuideView.swift` (사용 안내 한 단락)

**Interfaces:**
- Consumes: `PrayerRequestShareModel`, `ShareDraftFeature.availability()`, `ShareDraftFeature.makeModel()`.
- Produces: `struct PrayerRequestShareSheet: View { init(entry: JournalEntry) }` — 엔트리 타입 이름은 `EntryDetailView`가 받는 타입을 그대로 쓴다.

화면 규칙(문구는 이대로):
- 진입점 이름 `기도제목 나누기`. 본문이 비었거나 휴지통에 있는 기록에는 보이지 않는다. macOS는 편집 중인 내용을 먼저 저장(`model.flushOpenEditor()`)하고 연다.
- `.drafting`: `기도제목을 찾는 중…` + `직접 쓰기` 버튼.
- `.ready`/`.manual`: 줄마다 체크박스 + 여러 줄 `TextField` + 주제 칩(있을 때). 아래에 `기도제목 추가`.
- `.manual` 안내: `.nothingToPrayFor` → `이 기록에서는 기도제목을 찾지 못했어요. 직접 적어 보세요.` / `.noUsableAnswer` → 같은 문구 / `.modelUnavailable` → `이 기기에서는 자동 제안을 쓸 수 없어요. 직접 적어 보세요.` / `.userChoice` → 안내 없음.
- 항상 보이는 한 줄: `다른 사람 이야기가 들어 있다면 나누기 전에 한 번 더 확인해 주세요.`
- `나눌 언어` 선택(`한국어` / `English`). `if #available(iOS 18, macOS 15, *)`일 때만 보인다. 바꾸면 `translationRequest(to:)` → `.translationTask(configuration)` 안에서 `session.translations(from:)` → `applyTranslation`; 오류는 `translationFailed("번역하지 못했어요. 원래 언어로 나눕니다.")`. `.translationTask`의 정확한 시그니처와 언어 내려받기 동작은 구현 시 Apple 문서로 확인한다.
- 아래 버튼: `ShareLink(item: model.shareText)`(라벨 `나누기`)와 `복사`. `canShare`가 false면 둘 다 비활성.
- 닫기: `hasEdits`면 `작성한 기도제목을 버릴까요?` 확인. 닫으면 아무것도 남기지 않는다.

- [ ] **Step 1:** 시트 구현, 진입점 세 곳 연결.
- [ ] **Step 2:** `xcodebuild -exportLocalizations …`로 키를 새로 뽑고 `en` 값을 채운다(`Share prayer requests`, `Finding prayer requests…`, `Write my own`, `Add a prayer request`, `Language to share in`, `Share`, `Copy`, 안내 문구들).
- [ ] **Step 3:** `./scripts/check.sh` → 통과. 서명 없는 iOS·macOS Xcode 빌드 → 성공.
- [ ] **Step 4:** iOS 26 시뮬레이터에서 직접 확인(시뮬레이터는 모델이 없을 수 있으므로 직접 쓰기 흐름): 기록 상세 → `기도제목 나누기` → 직접 쓰기로 열림 → 두 줄 입력 → `복사` → 붙여 넣은 글이 `• a\n• b`. iOS 17 시뮬레이터에서 앱 실행과 같은 흐름 확인(언어 선택은 안 보임).
- [ ] **Step 5:** Commit `feat(share): prayer-request share sheet with entry points on iOS and macOS`.

### Task 7: 문서와 출시 관문

**Files:**
- Modify: `docs/privacy.md` (L7 근처에 한 단락), `docs/user-guide.md`, `docs/implementation-todo.md`, `docs/pre-release-checklist.md`, `docs/device-verification.md`, `docs/development.md`("공유 카드 추출 평가"), `docs/roadmap.md`, `CLAUDE.md`(Architecture에 `JournalShareDrafts` 한 줄)

- [ ] **Step 1:** `docs/privacy.md`: "기도제목 제안과 번역은 기기 안에서 이루어진다(Apple 온디바이스 모델, 시스템 번역). 제안·번역 결과와 나눈 이력은 저장하지 않는다. 나누기는 시스템 공유 시트로 사용자가 고른 앱에 글을 넘기는 것이며 앱이 직접 올리지 않는다."
- [ ] **Step 2:** `docs/pre-release-checklist.md`와 `docs/device-verification.md`에 실기기 세션 추가:
  - iPhone(iOS 26, Apple Intelligence 켬): 한국어 일기 3개·영어 일기 1개에서 제안이 10초 안에 나오는가, 기도할 내용 없는 일기에서 직접 쓰기로 넘어가는가.
  - 같은 기기에서 언어 팩 없는 상태로 `English` 선택 → 내려받기 안내 또는 원문 유지 + 알림.
  - Apple Intelligence 끈 기기 / iOS 17 기기: 직접 쓰기로 열리고 앱이 정상 실행.
  - 공유 시트로 메시지·카카오톡에 넘긴 글이 화면과 같은가.
  - 출시 기준: 위가 모두 통과하고, 실험실 21개 일기에서 기도할 내용 없는 일기 2개가 모두 걸러진다. 미달이면 `ShareDraftFeature.onDeviceDraftsEnabled = false`로 내보낸다(직접 쓰기만).
- [ ] **Step 3:** `docs/implementation-todo.md`: 완료 항목으로 옮기고, 남은 것(간증·독후감 카드, 이미지 카드, 데드라인, 기도노트에 저장, 그룹에 올리기, 영어 프롬프트 21개 평가, 한→영 번역의 호칭 오독)을 미룬 항목으로 적는다.
- [ ] **Step 4:** PR #22(설계 문서)에 "1차는 `docs/superpowers/plans/2026-11-12-prayer-request-share.md`로 범위를 줄여 진행" 코멘트를 남긴다(사용자 승인 후).
- [ ] **Step 5:** Commit `docs: prayer-request sharing, privacy note and device-verification gate`.

## 이번에 하지 않는 것

간증·독후감 카드, 이미지 카드, 데드라인 추출, 기도노트 체크리스트에 저장, iCloud 공유 노트북·그룹 서버에 올리기, 저장 후 자동 배너, Private Cloud Compute 모델.
