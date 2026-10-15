# 사용자가 관리하는 기록 유형 — 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 고정 enum인 기록 유형을 사용자가 추가·삭제·이름·색·아이콘·순서 변경·되살리기할 수 있게 하고, 이 편집을 유료 게이트(`FeatureAccess`) 하나 뒤에 둔다.

**Architecture:** `JournalKind`를 문자열 ID 구조체로 바꾸고, 기록은 기존 `kindRaw`에 그 ID를 저장한다. 유형 정의(`KindCatalog`)는 순수 값 타입이다. 저장은 노트북처럼 UserDefaults와 `NSUbiquitousKeyValueStore`에 한다. 삭제는 카탈로그에 이동 대상을 남긴 뒤 기록을 리비전과 함께 옮기고, 다른 기기에서 늦게 온 기록은 `KindReconciler`가 같은 규칙으로 옮긴다.

**Tech Stack:** Swift 6.2 패키지, SwiftUI(iOS 17+, macOS 14+), SwiftData + CloudKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-15-user-managed-kinds-design.md`

## Global Constraints

- CloudKit 스키마 변경 금지: `canonicalModels`의 모델과 필드를 추가하거나 바꾸지 않는다.
- 유형 ID: 기본 유형은 `prayer`, `bibleStudy`, `reading`, `diary`, `memo`, `unclassified`이고, 새 유형은 `"custom-" + UUID().uuidString`이다.
- `JournalKind`의 JSON은 단일 문자열이다. 기존 백업과 리비전 스냅샷의 형태가 바뀌면 안 된다.
- 모르는 유형 ID를 `unclassified`로 바꿔 쓰는 코드가 남으면 안 된다(저장소, 검색 색인, 분류 규칙).
- 이름 규칙: 앞뒤 공백을 제거하고 1~20자(`Character` 기준)다. 활성 유형 사이에서 대소문자를 무시하고 고유해야 한다.
- 미분류: 삭제·이름 변경·순서 변경이 안 되고, 목록 맨 끝에 고정된다.
- KV·UserDefaults 키: `journal-kind-catalog`.
- 모르는 ID의 표시: 이름 "이름 없는 유형", 색 `stone`, 아이콘 `tag`.
- 화면 문구는 한국어다. 코드 주석은 주변 파일의 밀도와 언어를 따른다.
- 새 파일은 `import`를 명시한다. Xcode 프로젝트는 member import visibility를 강제하므로, `swift build`가 통과해도 Xcode 빌드가 실패할 수 있다.
- 매 작업 끝 게이트:
  - `swift build`와 해당 `swift test --filter …`가 통과해야 한다.
  - UI를 건드린 작업은 아래 서명 없는 Xcode 빌드 두 개도 통과해야 한다.

  ```sh
  xcodebuild -project PilgrimJournal/PilgrimJournal.xcodeproj -scheme PilgrimJournalApp -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
  xcodebuild -project PilgrimJournal/PilgrimJournal.xcodeproj -scheme PilgrimJournalApp -destination 'generic/platform=macOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
  ```
- 커밋 메시지 끝에 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`를 붙인다.

### 스펙과 다른 점 하나

- **스펙:** 정리 작업을 "`refresh()`의 끝"에서 돌린다.
- **문제:** `refresh()`는 유형이나 노트북을 고를 때마다 불린다. SwiftData의 `page(kind:)`는 전체를 읽은 뒤 거르므로, 그때마다 전체를 훑으면 대량 기록에서 느려진다.
- **이 계획의 실행 시점:**
  - 앱 모델이 처음 `refresh()`될 때
  - 클라우드 병합으로 카탈로그가 바뀌었을 때
  - CloudKit import가 끝났을 때(`handleCloudSyncStoreEvent`의 `.importing` 완료)
  - 백업 복원 뒤
- **생략 조건:** 카탈로그에 삭제된 정의가 하나도 없으면 아무것도 하지 않는다.
- Task 9에서 스펙 2절의 해당 문장도 고친다.

## Review Focus

1. **손상된 카탈로그 JSON.** UserDefaults나 KV에 해석할 수 없는 값이 들어 있어도 앱은 기본 유형으로 떠야 하고, 클라우드 값을 덮어쓰면 안 된다. → Task 4 `testCorruptStoredCatalogFallsBackWithoutOverwritingCloud`
2. **두 기기가 동시에 같은 이름의 유형을 만듦.** 병합 뒤 ID가 다른 두 활성 유형이 모두 남아야 한다. 어느 쪽도 사라지거나 충돌로 죽으면 안 된다. → Task 2 `testMergeKeepsConcurrentKindsWithSameName`
3. **되살리기 이름 충돌.** 기도노트를 삭제하고 메모 이름을 "기도노트"로 바꾼 뒤 기도노트를 되살리면, 같은 이름의 활성 유형이 둘 생기면 안 된다. 되살리기를 `duplicateName`으로 거부한다. → Task 2 `testRestoreRejectsNameTakenByAnotherActiveKind`
4. **휴지통 기록.** 삭제한 유형의 기록이 휴지통에 있으면 삭제 때는 그대로 두고, 휴지통에서 되돌린 뒤 정리 작업이 옮겨야 한다. → Task 3 `testTrashedEntryIsMovedAfterItIsRestored`
5. **열린 편집기.** 유형을 삭제한 뒤, 이미 열려 있던 편집기가 삭제된 유형으로 저장해도 다음 정리 작업이 그 기록을 옮겨야 한다. → Task 3 `testReconcilerMovesEntrySavedWithDeletedKindAfterDeletion`

---

### Task 1: `JournalKind`를 문자열 ID 구조체로 전환

**Files:**
- Modify: `Sources/JournalDomain/JournalTypes.swift:4-26,57-90,115-119`
- Modify: `Sources/JournalDomain/JournalRecords.swift:55`
- Modify: `Sources/JournalData/SwiftDataJournalRepository.swift:534-553`
- Modify: `Sources/JournalSearch/JournalSearchIndex.swift:371-377`
- Modify (컴파일 수정만): `Sources/PilgrimJournal/{AppModel,ContentView,DesignSystem,EntryViews,OrganizationSettingsViews,SettingsAndImportViews,PilgrimJournalApp}.swift`, `Sources/JournalChecks/main.swift`
- Test: `Tests/JournalDomainTests/JournalDomainTests.swift`, `Tests/JournalDataTests/JournalDataTests.swift`, `Tests/JournalSearchTests/JournalSearchTests.swift`, `Tests/PilgrimJournalTests/NewEntryDefaultsTests.swift`

**Interfaces:**
- Produces:

```swift
public enum BuiltInKind: String, CaseIterable, Sendable {
    case prayer, bibleStudy, reading, diary, memo, unclassified
    public var defaultName: String          // "기도노트" … "미분류" (지금 localizedName 값)
    public var canCreateManually: Bool      // self != .unclassified
}

public struct JournalKind: Hashable, Codable, Identifiable, Sendable {
    public let id: String
    public init(id: String)
    public init?(rawValue: String)          // 빈 문자열만 nil
    public var rawValue: String { id }
    public var builtIn: BuiltInKind? { BuiltInKind(rawValue: id) }
    public var isUnclassified: Bool          // id == "unclassified"
    public static let prayer, bibleStudy, reading, diary, memo, unclassified: JournalKind
    public static var builtIns: [JournalKind] // BuiltInKind.allCases 순서
    public static func custom() -> JournalKind
}
```

- `JournalKind.localizedName`을 지우고 `JournalKind.fallbackName: String`을 둔다. 값은 `builtIn?.defaultName ?? "이름 없는 유형"`이다. Task 7에서 화면은 카탈로그 이름으로 바뀌고, 이 값은 카탈로그 밖(검증 메시지, 체크 스크립트)에서만 쓴다.
- `JournalKind.canCreateManually`를 지운다. `validated(manual:)`는 `kind.isUnclassified`이면 `invalidManualKind`를 던진다.

- [ ] **Step 1: 실패하는 테스트 작성**
  - **`JournalDomainTests`** (기존 테스트 정리 포함):
    - `testInvalidManualKindMessageNamesEveryCreatableKind`를 지운다.
    - `testMemoCanBeCreatedManuallyAndHasNoTypeSpecificDetails`의 `localizedName` 단언은 `BuiltInKind.memo.defaultName == "메모"`로 바꾼다.
    - 새 테스트 추가:

    ```swift
    func testInvalidManualKindMessageIsFixedSentence() {
        XCTAssertEqual(JournalError.invalidManualKind.errorDescription,
                       "미분류로는 새 기록을 만들 수 없습니다. 다른 유형을 골라 주세요.")
    }
    func testJournalKindEncodesAsBareString() throws {
        let data = try JSONEncoder().encode([JournalKind.prayer, JournalKind(id: "custom-A")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["prayer","custom-A"]"#)
    }
    func testUnknownKindIdSurvivesDecoding() throws {
        let draft = try JSONDecoder().decode(JournalEntryDraft.self,
            from: Data(#"{"kind":"custom-X","title":"t","body":"b","occurredAt":0,"tags":[],"isStarred":false,"isPinned":false,"details":{}}"#.utf8))
        XCTAssertEqual(draft.kind.id, "custom-X"); XCTAssertNil(draft.kind.builtIn)
    }
    func testCustomKindIsManualAndClearsAllDetails() throws {
        let draft = JournalEntryDraft(kind: JournalKind(id: "custom-A"), body: "본문",
            details: EntryDetails(prayerStatus: .answered, mood: "평안"))
        XCTAssertEqual(try draft.validated(manual: true).details, EntryDetails())
    }
    ```

  - **`JournalDataTests`**:
    - `testSwiftDataPreservesCustomKindId`: `custom-X`로 저장하고 다시 읽으면 `kind.id == "custom-X"`이다. `list(kind: JournalKind(id: "custom-X"), …)`는 그 기록만 돌려준다.
    - `testRuleWithCustomTargetIsPreserved`: `saveClassificationRule`로 저장한 규칙의 `targetKind`가 `classificationRules()`에서 그대로 나온다.
  - **`JournalSearchTests`**:
    - `testSearchKeepsCustomKindAndFilters`: `custom-X` 기록을 색인한다. `JournalSearchQuery(text:…, kind: JournalKind(id: "custom-X"))`로 검색하면 그 기록이 나오고 `hit.kind.id == "custom-X"`이다.

- [ ] **Step 2: 실패 확인**

  ```sh
  swift test --filter JournalDomainTests
  ```

  Expected: 컴파일 실패(`JournalKind(id:)` 없음).

- [ ] **Step 3: `JournalTypes.swift` 구현**
  - **Codable:** `singleValueContainer`로 문자열 하나를 읽고 쓴다. 빈 문자열이면 디코딩 오류다.
  - **`EntryDetails.validated(for:)`:** `switch kind.builtIn`으로 바꾼다. `nil`과 `.memo`, `.unclassified`는 `EntryDetails()`를 돌려준다.
  - **`JournalError.invalidManualKind` 문구:** 위 테스트의 고정 문장으로 바꾼다.

- [ ] **Step 4: 저장소와 색인에서 ID 보존**
  - `SwiftDataJournalRepository.map`: `JournalKind(id: entity.kindRaw)`를 쓴다. 단, 빈 문자열이면 `.unclassified`다.
  - `mapRule`: 대상은 `JournalKind(rawValue:)`로 읽는다(빈 문자열만 `nil`로 걸러짐).
  - `JournalSearchIndex`: 371-377줄의 `JournalKind(rawValue:)`가 이제 실패하지 않는지만 확인한다.

- [ ] **Step 5: 앱·체크 스크립트 컴파일 수정**
  - **`switch kind`와 `switch draft.kind` / `entry.kind`:** `switch kind.builtIn`으로 바꾸고 `case .prayer?:`, `default:` 형태로 쓴다.
    - 대상: `EntryViews.swift`의 `typeSpecificFields` 두 곳과 `typeDetails`, `ContentView.icon(for:)`, `DesignSystem.categoryColor(for:)`.
    - 사용자 유형은 기본값이다: 메모와 같은 보라색, 아이콘 `tag`.
  - **`localizedName`:** 모두 `fallbackName`으로 바꾼다.
  - **`JournalKind.allCases`:** `JournalKind.builtIns`로 바꾼다.
  - **`.filter(\.canCreateManually)`:** `.filter { !$0.isUnclassified }`로 바꾼다.
  - **`AppModel.defaultKindForNewEntry`:** `guard let selectedKind, !selectedKind.isUnclassified`로 바꾼다.
  - 이 단계에서 화면 동작은 바뀌지 않는다.

- [ ] **Step 6: 통과 확인**
  - 실행:

    ```sh
    swift build
    swift test
    ```

  - Xcode iOS·macOS 빌드도 실행한다.
  - Expected: 전부 PASS. 기존 `NewEntryDefaultsTests` 3개도 수정 없이 통과해야 한다.

- [ ] **Step 7: 커밋**

  ```sh
  git commit -am "refactor(domain): make JournalKind an open string ID and keep unknown kinds intact"
  ```

---

### Task 2: `KindCatalog` 도메인 모델

**Files:**
- Create: `Sources/JournalDomain/KindCatalog.swift` (`KindDefinition`, `KindState`, `KindColorToken`, `KindIconCatalog`, `KindCatalogError`, `KindCatalog`)
- Test: `Tests/JournalDomainTests/KindCatalogTests.swift`

**Interfaces:**
- Consumes: Task 1의 `JournalKind`, `BuiltInKind`
- Produces:

```swift
public enum KindColorToken: String, Codable, CaseIterable, Sendable {
    case amber, sage, slate, clay, iris, stone, teal, rose   // 순서 고정. 앞 6개 = 기본 유형 6개의 현재 색
}
public enum KindIconCatalog {
    public static let symbols: [String]      // 정확히 20개. 아래 목록
    public static func displaySymbol(for token: String) -> String  // 목록에 없으면 "tag"
}
public enum KindState: Codable, Equatable, Sendable {
    case active
    case deleted(moveTarget: JournalKind)
}
public struct KindDefinition: Codable, Equatable, Identifiable, Sendable {
    public var kind: JournalKind; public var name: String
    public var colorToken: KindColorToken; public var iconToken: String
    public var order: Int; public var state: KindState
    public var updatedAt: Date; public var modifiedByDeviceID: String
    public var id: String { kind.id }
    public var isActive: Bool
}
public enum KindCatalogError: LocalizedError, Equatable, Sendable {
    case emptyName, nameTooLong, duplicateName(String), systemKindLocked,
         lastCreatableKind, invalidMoveTarget, notDeleted, customKindCannotBeRestored
}
public struct KindCatalog: Codable, Equatable, Sendable {
    public private(set) var definitions: [KindDefinition]          // 저장된 것만
    public init(definitions: [KindDefinition] = [])
    public static func defaultDefinition(for builtIn: BuiltInKind) -> KindDefinition
    public static func unknownDefinition(for kind: JournalKind) -> KindDefinition
    public var allDefinitions: [KindDefinition]      // 저장된 것 ∪ 저장 안 된 기본 유형의 기본 정의
    public var activeKinds: [KindDefinition]         // order, 그다음 id 순. 미분류는 맨 끝
    public var creatableKinds: [KindDefinition]      // activeKinds - 미분류
    public var deletedBuiltIns: [KindDefinition]
    public var hasDeletedKinds: Bool
    public func isKnown(_ kind: JournalKind) -> Bool
    public func definition(for kind: JournalKind) -> KindDefinition   // 모르면 unknownDefinition
    public mutating func create(name: String, colorToken: KindColorToken, iconToken: String,
                                deviceID: String, at date: Date) throws -> KindDefinition
    public mutating func update(_ kind: JournalKind, name: String, colorToken: KindColorToken,
                                iconToken: String, deviceID: String, at date: Date) throws
    public mutating func reorder(_ ordered: [JournalKind], deviceID: String, at date: Date) throws
    public mutating func delete(_ kind: JournalKind, moveTarget: JournalKind,
                                deviceID: String, at date: Date) throws
    public mutating func restore(_ kind: JournalKind, deviceID: String, at date: Date) throws
    public func merged(with other: KindCatalog) -> KindCatalog
    public func resolvedTarget(for kind: JournalKind) -> JournalKind?
}
```

**값과 규칙:**
- **`KindIconCatalog.symbols`:**
  - 기본 유형 아이콘 6개: `"hands.sparkles", "book.closed", "books.vertical", "pencil.and.scribble", "note.text", "tray"`
  - 추가 14개: `"tag", "heart", "star", "leaf", "sun.max", "moon", "flame", "music.note", "person.2", "house", "briefcase", "graduationcap", "lightbulb", "calendar"`
- **기본 정의:**
  - 이름은 `defaultName`이다.
  - 색은 기본 유형 순서대로 `amber, sage, slate, clay, iris, stone`이다.
  - 아이콘은 위 기본 유형 아이콘 6개를 같은 순서로 쓴다.
  - `order`는 `BuiltInKind.allCases`의 index다.
  - `updatedAt`은 `.distantPast`, `modifiedByDeviceID`는 `""`다. 그래서 어떤 편집이든 병합에서 이긴다.
- **`unknownDefinition`:** 이름 "이름 없는 유형", 색 `.stone`, 아이콘 `"tag"`, 상태 `.active`, `order`는 `Int.max - 1`이다.
- **`create`:**
  - ID는 `JournalKind.custom()`이다.
  - `order`는 활성 유형(미분류 제외) 최대 `order` + 1이다.
- **`update`:**
  - 미분류면 `systemKindLocked`를 던진다.
  - 모르는 ID면 그 ID로 활성 정의를 새로 만든다. 스펙의 "이름 없는 유형 이름 바꾸기"에 해당한다.
- **`reorder`:**
  - 미분류가 포함돼 있으면 `systemKindLocked`를 던진다.
  - 받은 순서대로 `order = index`를 쓰고, 순서가 바뀐 정의만 `updatedAt`을 갱신한다.
- **`delete`:**
  - 미분류면 `systemKindLocked`를 던진다.
  - 대상이 자기 자신이거나 활성 유형이 아니면 `invalidMoveTarget`을 던진다.
  - 삭제 뒤 `creatableKinds`가 비면 `lastCreatableKind`를 던진다.
- **`restore`:**
  - 사용자 유형이면 `customKindCannotBeRestored`를 던진다.
  - 삭제 상태가 아니면 `notDeleted`를 던진다.
  - 같은 이름의 활성 유형이 있으면 `duplicateName`을 던진다.
  - 되살린 정의의 `order`는 활성 유형 최대 `order` + 1이다.
- **`merged(with:)`:**
  - ID별로 하나를 고른다. `updatedAt`이 크면 이기고, 같으면 `modifiedByDeviceID`가 문자열로 큰 쪽이 이긴다.
  - 한쪽에만 있는 정의는 그대로 둔다.
- **`resolvedTarget(for:)`:**
  - 활성 유형이거나 모르는 ID면 `nil`이다.
  - 삭제된 정의면 `moveTarget` 체인을 따라가 처음 만나는 활성 유형을 돌려준다.
  - 방문한 ID를 다시 만나거나 체인이 모르는 ID에 닿으면 `.unclassified`다.
- **`KindCatalogError.errorDescription`:**
  - `emptyName`: "유형 이름을 입력해 주세요."
  - `nameTooLong`: "유형 이름은 20자 이하로 입력해 주세요."
  - `duplicateName(n)`: "‘\(n)’ 유형이 이미 있습니다."
  - `systemKindLocked`: "미분류는 바꿀 수 없습니다."
  - `lastCreatableKind`: "유형이 하나 이상 있어야 합니다."
  - `invalidMoveTarget`: "기록을 옮길 다른 유형을 골라 주세요."
  - `notDeleted`: "삭제된 유형이 아닙니다."
  - `customKindCannotBeRestored`: "직접 만든 유형은 되살릴 수 없습니다."

- [ ] **Step 1: 실패하는 테스트 작성** (`KindCatalogTests`, 날짜는 `Date(timeIntervalSince1970:)`로 고정)
  - `testEmptyCatalogMatchesCurrentKinds`:
    - `activeKinds.map(\.kind)`가 `JournalKind.builtIns`와 같다.
    - `creatableKinds.count == 5`이다.
    - 미분류가 마지막이다.
  - `testCreateValidatesName`:
    - `"  "`이면 `emptyName`이다.
    - 21자이면 `nameTooLong`, 20자이면 성공이다.
    - `"메모"`와 `"MEMO"`가 중복으로 걸린다. `"메모"`는 `duplicateName("메모")`다.
  - `testCreateAppendsBeforeUnclassified`: 새 유형이 `activeKinds`에서 미분류 바로 앞에 있다.
  - `testUnclassifiedIsLocked`: `update`, `delete`, `reorder([.unclassified, .memo])` 모두 `systemKindLocked`다.
  - `testDeleteRequiresActiveOtherTarget`: 자기 자신이나 삭제된 유형을 대상으로 주면 `invalidMoveTarget`이다.
  - `testCannotDeleteLastCreatableKind`: 다섯 개를 지우다 마지막에 `lastCreatableKind`가 난다.
  - `testRestoreBuiltInAndRejectCustom`:
    - 기도노트를 삭제한 뒤 되살리면 활성이고, `order`가 가장 크다(미분류 제외).
    - 사용자 유형을 삭제한 뒤 되살리면 `customKindCannotBeRestored`다.
  - `testRestoreRejectsNameTakenByAnotherActiveKind` (Review Focus 3).
  - `testMergePicksNewerThenDeviceID`:
    - `updatedAt`이 다르면 늦은 쪽이 이긴다.
    - `updatedAt`이 같으면 `"B" > "A"`라서 B가 이긴다.
  - `testMergeKeepsConcurrentKindsWithSameName` (Review Focus 2): 서로 다른 카탈로그에서 "설교노트"를 만들어 병합하면 활성 사용자 유형이 2개다.
  - `testResolvedTargetFollowsChainAndBreaksCycles`:
    - X→Y, Y→활성 Z이면 X는 Z다.
    - A→B, B→A이면 `.unclassified`다.
    - 활성 유형과 모르는 ID는 `nil`이다.
  - `testUnknownKindIsRenamable`: `update(JournalKind(id: "custom-Q"), name: "설교")` 뒤 `isKnown`이 참이고 이름이 "설교"다.
  - `testCatalogJSONRoundTrip`: 삭제 상태를 포함해 인코딩 → 디코딩하면 같은 값이다.
  - `testIconFallback`: `displaySymbol(for: "nope") == "tag"`이고 `symbols.count == 20`이다.

- [ ] **Step 2: 실패 확인**

  ```sh
  swift test --filter JournalDomainTests.KindCatalogTests
  ```

  Expected: 컴파일 실패.

- [ ] **Step 3: 구현** — 위 Interfaces와 규칙대로 작성한다.

- [ ] **Step 4: 통과 확인** — 같은 명령. Expected: PASS.

- [ ] **Step 5: 커밋**

  ```sh
  git commit -m "feat(domain): add KindCatalog for user-managed kinds"
  ```

---

### Task 3: 삭제 이동, 전용 필드 텍스트, 정리 작업

**Files:**
- Modify: `Sources/JournalDomain/JournalTypes.swift` (`EntryDetails.carryOverLines`)
- Create: `Sources/JournalDomain/KindDeletionService.swift` (`KindDeletionService`, `KindReconciler`)
- Test: `Tests/JournalDomainTests/JournalDomainTests.swift` (`carryOverLines`)
- Test: `Tests/JournalDataTests/KindDeletionServiceTests.swift`
  - 이 파일은 `#if canImport(XCTest)`만 쓴다. `InMemoryJournalRepository`를 쓰므로 SwiftData 조건이 필요 없다.

**Interfaces:**
- Consumes: Task 1 `JournalKind`, Task 2 `KindCatalog.resolvedTarget(for:)`, `hasDeletedKinds`
- Produces:

```swift
extension EntryDetails {
    /// 버려질 전용 필드를 사람이 읽는 줄로. 붙일 것이 없으면 nil.
    public func carryOverLines(from kind: BuiltInKind, timeZoneIdentifier: String?) -> String?
}

@MainActor public struct KindDeletionService {
    public init()
    public static func body(_ body: String, appending carryOver: String?) -> String
    /// 휴지통이 아닌 `kind` 기록을 모두 `target`으로 옮기고 갱신된 레코드를 돌려준다.
    public func moveEntries(from kind: JournalKind, to target: JournalKind,
                            repository: any JournalRepository,
                            deviceID: String, at date: Date) throws -> [JournalEntryRecord]
    /// 대상이 `kind`인 규칙을 `target`으로 바꾼다. 바꾼 개수를 돌려준다.
    public func retargetRules(from kind: JournalKind, to target: JournalKind,
                              repository: any JournalRepository, at date: Date) throws -> Int
}

@MainActor public struct KindReconciler {
    public init()
    /// `catalog.resolvedTarget`이 nil이 아닌 기록과 규칙만 옮긴다. 모르는 ID는 건드리지 않는다.
    public func reconcile(catalog: KindCatalog, repository: any JournalRepository,
                          deviceID: String, at date: Date) throws -> [JournalEntryRecord]
}
```

**규칙:**
- **`carryOverLines`의 줄 형식** (스펙 1절 표):
  - 기도노트: `기도 상태: 기도 중`, 또는 `기도 상태: 응답됨 (yyyy-MM-dd)`. 응답일이 없으면 `기도 상태: 응답됨`이다. `prayerStatus`와 `answeredAt`이 둘 다 `nil`이면 `nil`이다.
  - 성경공부: `본문: <구절>`
  - 독서노트: `책: <제목> / 저자: <저자>`. 하나만 있으면 `책: <제목>` 또는 `저자: <저자>`다.
  - 일기: `기분: <기분>`
  - 메모·미분류: `nil`이다.
  - 공백만 있는 값은 없는 값으로 본다. 여러 줄이면 `\n`으로 잇는다.
- **날짜:** `Calendar(identifier: .gregorian)`, `Locale(identifier: "en_US_POSIX")`를 쓰고, 시간대는 `timeZoneIdentifier`다. 없거나 잘못된 값이면 `TimeZone.current`다.
- **`body(_:appending:)`:**
  - `carryOver`가 `nil`이면 본문 그대로다.
  - 본문이 공백뿐이면 `carryOver`만 넣는다.
  - 그 밖에는 `body + "\n\n---\n" + carryOver`다.
- **`moveEntries`:**
  - `page(kind: kind, includeDeleted: false, after:, limit: 500)`로 끝까지 읽는다.
  - 기록마다 `carryOverLines(from: kind.builtIn, …)`를 만든다. 사용자 유형이면 줄을 만들지 않는다.
  - `draft.body = body(…)`, `draft.kind = target`으로 바꾸고 `repository.save(draft, deviceID:, at:)`로 저장한다.
  - `save`는 페이지를 다 읽은 뒤에 한다. 저장이 커서 순서를 흔들지 않게 한다.
- **`KindReconciler.reconcile`:**
  - `catalog.hasDeletedKinds == false`이면 바로 `[]`다.
  - 그 밖에는 `page(kind: nil, includeDeleted: false, …)` 전체에서 `resolvedTarget(for: entry.kind)`가 있는 기록을 모은다.
  - 모은 기록은 `moveEntries`와 같은 기록별 변환으로 옮긴다. 이 변환은 private 함수 하나로 두 곳이 공유한다.
  - 규칙도 같은 방식으로 다시 지정한다.

- [ ] **Step 1: 실패하는 테스트 작성**
  - **`JournalDomainTests`**:
    - `testCarryOverLinesPerKind`:
      - 기도 응답됨 + `answeredAt = 2026-05-01T15:00Z` + `"Asia/Seoul"`이면 `"기도 상태: 응답됨 (2026-05-02)"`다.
      - 기도 중이면 `"기도 상태: 기도 중"`이다.
      - 성경공부 `"요 3:16"`이면 `"본문: 요 3:16"`이다.
      - 독서는 `"책: 고백록 / 저자: 아우구스티누스"`, `"책: 고백록"`, `"저자: 아우구스티누스"`가 각각 나온다.
      - 일기 `"평안"`이면 `"기분: 평안"`이다.
      - 메모이거나 값이 모두 비면 `nil`이다. 독서 제목이 `"  "`이면 그 줄을 빼고, 저자도 없으면 `nil`이다.
  - **`KindDeletionServiceTests`** (`@MainActor`, `InMemoryJournalRepository()`):
    - `testBodyAppendingCarryOver`:
      - `("본문", "기분: 평안")`이면 `"본문\n\n---\n기분: 평안"`이다.
      - `("", "기분: 평안")`이면 `"기분: 평안"`이다.
      - `("본문", nil)`이면 `"본문"`이다.
    - `testMovePrayerEntriesToDiaryAppendsDetailsAndKeepsRevision`:
      - 기도 응답 기록 1개, 일기 기록 1개를 둔다.
      - 이동 뒤 기도 기록은 `kind == .diary`이고, 본문 끝이 `"---\n기도 상태: 응답됨 (…)"`이고, `details == EntryDetails()`다.
      - `revisions(entryID:)`가 2개이고, 첫 스냅샷의 `kind == .prayer`이다.
      - 원래 일기 기록은 그대로다.
      - 돌려받은 레코드는 1개다.
    - `testMoveSkipsTrashedEntries`: 휴지통 기록은 `kind`가 그대로다.
    - `testRetargetRules`: `.prayer` 규칙 2개와 `.memo` 규칙 1개 중 2개만 바뀌고 반환값이 `2`다.
    - `testReconcilerMovesOnlyDeletedKindsAndLeavesUnknownIds`:
      - 카탈로그에 기도노트를 삭제(대상 메모)로 둔다.
      - 기록은 `.prayer`, `custom-UNKNOWN`, `.diary` 각 1개다.
      - 정리 뒤 기도 → 메모가 되고, 나머지 둘은 그대로다.
    - `testReconcilerIsNoOpWithoutDeletedKinds`: 빈 카탈로그로 정리하면 `[]`이고 리비전 수가 그대로다.
    - `testReconcilerMovesEntrySavedWithDeletedKindAfterDeletion` (Review Focus 5):
      - 이동한 뒤 `.prayer`로 새로 저장한다.
      - 정리하면 그 기록이 메모가 된다.
    - `testTrashedEntryIsMovedAfterItIsRestored` (Review Focus 4):
      - 휴지통 기록이 이동에서는 빠진다.
      - `restoreFromTrash` 뒤 정리하면 옮겨진다.

- [ ] **Step 2: 실패 확인**

  ```sh
  swift test --filter KindDeletionServiceTests
  swift test --filter JournalDomainTests.JournalDomainTests/testCarryOverLinesPerKind
  ```

  Expected: 컴파일 실패.

- [ ] **Step 3: 구현** — 위 시그니처와 규칙대로 작성한다.

- [ ] **Step 4: 통과 확인** — 같은 명령과 `swift test`. Expected: PASS.

- [ ] **Step 5: 커밋**

  ```sh
  git commit -m "feat(domain): move entries out of deleted kinds and reconcile late arrivals"
  ```

---

### Task 4: `KindCatalogStore` (UserDefaults + iCloud KV)

**Files:**
- Create: `Sources/JournalData/KindCatalogStore.swift`
- Test: `Tests/JournalDataTests/KindCatalogStoreTests.swift` (`#if canImport(XCTest)`)

**Interfaces:**
- Consumes: Task 2 `KindCatalog`, `merged(with:)`
- Produces:

```swift
/// KV 저장소 대신 테스트에서 주입할 수 있는 최소 표면.
public protocol KindCatalogCloudStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
    @discardableResult func synchronize() -> Bool
}
extension NSUbiquitousKeyValueStore: KindCatalogCloudStore {}
// data(forKey:), set(_: Data?, forKey:), synchronize()가 이미 있으므로 본문은 비어 있다.

@MainActor public final class KindCatalogStore {
    public static let key = "journal-kind-catalog"
    public private(set) var catalog: KindCatalog
    public init(defaults: UserDefaults, cloudStore: (any KindCatalogCloudStore)?)
    /// 로컬 값과 클라우드 값을 병합. 결과가 바뀌었으면 두 곳에 다시 쓰고 true를 돌려준다.
    @discardableResult public func mergeFromCloud() -> Bool
    public func save(_ catalog: KindCatalog)
}
```

**규칙:**
- **`init`:** 로컬 값을 디코딩하고, 클라우드가 있으면 `mergeFromCloud()`를 부른다.
- **해석할 수 없는 값:** 그 쪽은 `nil`로 취급한다.
  - 로컬이 깨졌으면 빈 카탈로그에서 시작한다.
  - 클라우드가 깨졌으면 무시한다.
  - 깨진 값만 있고 병합 결과가 빈 카탈로그와 같으면 아무 데도 쓰지 않는다. 그래서 깨진 클라우드 값을 기본값으로 덮지 않는다.
- **`save`:** `JSONEncoder`(`.sortedKeys`, 날짜 `.iso8601`)로 두 곳에 쓰고 `synchronize()`를 부른다.

- [ ] **Step 1: 실패하는 테스트 작성**
  - 공통 준비:
    - `UserDefaults(suiteName: "pilgrim-kinds-\(UUID().uuidString)")!`
    - 테스트 파일 안의 `final class FakeCloudStore: KindCatalogCloudStore`(딕셔너리 기반)
  - `testSaveWritesBothStoresAndReloads`: 저장한 뒤 새 `KindCatalogStore`의 `catalog`가 같다.
  - `testMergeFromCloudAdoptsNewerRemoteEdit`:
    - 클라우드에 더 늦은 "메모" 이름 변경이 있다.
    - `mergeFromCloud() == true`이고 이름이 바뀌어 있다.
    - 로컬 defaults에도 기록돼 있다.
  - `testMergeFromCloudReturnsFalseWhenUnchanged`
  - `testCorruptStoredCatalogFallsBackWithoutOverwritingCloud` (Review Focus 1):
    - defaults와 클라우드에 `Data("not json".utf8)`를 넣는다.
    - init 뒤 `catalog == KindCatalog()`이다.
    - 클라우드 값은 원래 바이트 그대로다.
  - `testWorksWithoutCloudStore`: `cloudStore: nil`로 저장과 재로드가 된다.

- [ ] **Step 2: 실패 확인**

  ```sh
  swift test --filter KindCatalogStoreTests
  ```

  Expected: 컴파일 실패.

- [ ] **Step 3: 구현.**

- [ ] **Step 4: 통과 확인.** Expected: PASS.

- [ ] **Step 5: 커밋**

  ```sh
  git commit -m "feat(data): persist the kind catalog in defaults and iCloud KV"
  ```

---

### Task 5: 백업에 `kinds.json` 포함

**Files:**
- Modify: `Sources/JournalBackup/BackupModels.swift:4-26,48-71`
- Modify: `Sources/JournalBackup/JournalBackupService.swift:17-50,96-124`
- Test: `Tests/JournalBackupTests/JournalBackupTests.swift`

**Interfaces:**
- Consumes: Task 2 `KindCatalog`
- Produces:
  - **`BackupManifest.includesKindCatalog: Bool`:**
    - init 매개변수 기본값은 `false`다.
    - 직접 쓴 `init(from:)`에서 `decodeIfPresent ?? false`로 읽는다.
    - `formatVersion`은 1 그대로 둔다.
  - **`BackupContents.kindCatalog: KindCatalog?`:** init 매개변수 기본값은 `nil`이고, 마지막 매개변수로 둔다.
  - **`JournalBackupService.create(…, sourceSnapshots:, kindCatalog: KindCatalog? = nil)`:**
    - `kindCatalog`가 있으면 `files["kinds.json"]`에 카탈로그 JSON을 쓴다.
    - `includesKindCatalog = true`로 한다.
  - **`readAndValidate`:** `validated["kinds.json"]`이 있으면 디코딩해 `kindCatalog`에 넣는다.

- [ ] **Step 1: 실패하는 테스트 작성**
  - `testBackupRoundTripsKindCatalogAndCustomKindEntries`:
    - 카탈로그는 사용자 유형 "설교노트" 1개와 기도노트 삭제(대상 메모)를 담는다.
    - 기록은 그 사용자 유형 ID를 가진다.
    - 읽은 `contents.kindCatalog`가 원본과 같다.
    - `manifest.includesKindCatalog == true`이다.
    - `contents.entries[0].kind`가 원본과 같다.
  - `testBackupWithoutKindCatalogStillReads`:
    - `kindCatalog` 없이 만든 백업을 읽으면 `kindCatalog == nil`, `includesKindCatalog == false`다.
  - `testManifestWithoutKindCatalogKeyDecodes`:
    - `{"formatVersion":1,"schemaVersion":1,"createdAt":"2026-01-01T00:00:00Z","files":{},"includesSourceSnapshots":false}`를 `.iso8601` 디코더로 읽으면 `includesKindCatalog == false`다.

- [ ] **Step 2: 실패 확인**

  ```sh
  swift test --filter JournalBackupTests
  ```

  Expected: 컴파일 실패.

- [ ] **Step 3: 구현.**

- [ ] **Step 4: 통과 확인.** Expected: PASS.

- [ ] **Step 5: 커밋**

  ```sh
  git commit -m "feat(backup): include the kind catalog as kinds.json"
  ```

---

### Task 6: `AppModel` 연결과 `FeatureAccess`

**Files:**
- Create: `Sources/PilgrimJournal/FeatureAccess.swift`
- Modify: `Sources/PilgrimJournal/AppModel.swift`
  - 대상: 프로퍼티(46-89), `defaultKindForNewEntry`(95-100), `init`(132-174), `handleCloudSyncStoreEvent`(`.importing` 완료 분기), `refresh`(280-323), `restoreBackup`(1463-1482), `writeCurrentBackup`(1553-1560)
- Test: `Tests/PilgrimJournalTests/KindManagementModelTests.swift`
  - `NewEntryDefaultsTests.makeModel()`과 같은 하네스를 쓴다.
- Test: `Tests/PilgrimJournalTests/NewEntryDefaultsTests.swift`

**Interfaces:**
- Consumes: Task 2 `KindCatalog`, Task 3 `KindDeletionService`, `KindReconciler`, Task 4 `KindCatalogStore`, Task 5 `create(kindCatalog:)`, `contents.kindCatalog`
- Produces (Task 7·8이 쓰는 이름):

```swift
@MainActor protocol FeatureAccess: AnyObject { var canManageKinds: Bool { get } }
@MainActor final class UnlockedFeatureAccess: FeatureAccess {
    static let simulateLockedKey = "debug-simulate-premium-locked"
    init(defaults: UserDefaults = .standard)
    var canManageKinds: Bool  // DEBUG 빌드에서만 simulateLockedKey가 참이면 false, 그 밖엔 항상 true
}

// AppModel
@Published private(set) var kindCatalog: KindCatalog
@Published private(set) var unknownKinds: [JournalKind]      // 불러온 기록에서 발견한, 카탈로그에 없는 ID
@Published var isPresentingKindManagement = false
@Published var isPresentingPremiumNotice = false
let featureAccess: any FeatureAccess
init(…기존 매개변수…, featureAccess: (any FeatureAccess)? = nil)   // nil이면 UnlockedFeatureAccess()
var sidebarKinds: [KindDefinition]        // activeKinds에서 미분류 앞에 unknownKinds의 unknownDefinition을 끼움
func kindDefinition(for kind: JournalKind) -> KindDefinition
func openKindManagement()                  // 게이트가 열려 있으면 isPresentingKindManagement, 아니면 isPresentingPremiumNotice
func entryCount(for kind: JournalKind) throws -> Int
func createKind(name: String, colorToken: KindColorToken, iconToken: String) throws -> JournalKind
func updateKind(_ kind: JournalKind, name: String, colorToken: KindColorToken, iconToken: String) throws
func reorderKinds(_ ordered: [JournalKind]) throws
func deleteKind(_ kind: JournalKind, moveTo target: JournalKind) throws
func restoreKind(_ kind: JournalKind) throws
```

**규칙:**
- **카탈로그 저장소:** `AppModel`이 `KindCatalogStore(defaults: notebookDefaults, cloudStore: notebookCloudStore)`를 직접 만든다. 노트북과 같은 저장소와 같은 주입 경로다.
- **변경 메서드 공통:**
  - 복사본에 연산을 적용한다(실패하면 그대로 throw).
  - 성공하면 `store.save`하고 `kindCatalog`를 갱신한 뒤 `markLocalMutation()`을 부른다.
  - `deviceID`와 `.now`를 쓴다.
- **`deleteKind` 순서:**
  1. 카탈로그를 바꾸고 저장한다.
  2. `KindDeletionService.moveEntries`로 옮기고, 결과마다 `searchIndex.upsert`를 부른다.
  3. `retargetRules`를 부른다.
  4. `selectedKind == kind`이면 `selectKind(nil)`을 부르고, 아니면 `refresh()`를 부른다.
  - 2·3에서 실패하면 throw한다. 카탈로그는 이미 저장됐으므로 다음 정리 작업이 나머지를 옮긴다.
- **`defaultKindForNewEntry`:**
  - 선택된 유형이 `creatableKinds`에 있으면 그 유형이다.
  - 아니면 `.diary`가 작성 가능할 때 `.diary`다.
  - 그것도 아니면 `creatableKinds.first!.kind`다. `lastCreatableKind` 규칙 덕분에 항상 존재한다.
- **`refresh()`:** 기존 노트북 병합 옆에서 `store.mergeFromCloud()`를 부른다. 결과가 `true`이면 다음을 한다.
  - `kindCatalog`를 갱신한다.
  - `reconcileKinds()`를 부른다.
  - `selectedKind`가 더는 활성이 아니면 `selectedKind = nil`로 바꾼다(재귀 refresh 없이 같은 호출 안에서).
- **`unknownKinds`:** `refresh()`에서 `entries`를 다 읽은 뒤 `entries`의 `kind` 중 `!kindCatalog.isKnown`인 것을 순서 유지·중복 제거해 넣는다.
- **`reconcileKinds()` (private):**
  - `KindReconciler().reconcile`을 부르고, 결과를 `searchIndex.upsert`한다.
  - 결과가 비어 있지 않으면 `markLocalMutation()`을 부른다.
  - 실행 시점은 위 "스펙과 다른 점"의 네 곳이다.
  - 첫 refresh 여부는 `private var hasReconciledKinds = false`로 추적한다.
- **백업 쓰기:** `writeCurrentBackup`이 `kindCatalog: kindCatalog`를 넘긴다.
- **백업 복원:**
  - `contents.kindCatalog`가 있으면 `store.save(kindCatalog.merged(with: backup))`로 저장하고 `kindCatalog`를 갱신한다.
  - 그 뒤 기존 rebuild/refresh 전에 `reconcileKinds()`를 부른다.

- [ ] **Step 1: 실패하는 테스트 작성** (`KindManagementModelTests`, `@MainActor`)
  - `testCreateKindAppearsInSidebarAndPersistsAcrossModels`:
    - 같은 defaults로 만든 두 번째 `AppModel`의 `kindCatalog.creatableKinds`에 "설교노트"가 있다.
    - `sidebarKinds.last?.kind == .unclassified`이다.
  - `testDeleteKindMovesEntriesUpdatesSearchAndClearsSelection`:
    - 기도 기록 2개를 둔다. `selectKind(.prayer)` 뒤 `deleteKind(.prayer, moveTo: .memo)`를 부른다.
    - `selectedKind == nil`이다.
    - `repository.list(kind: .memo…)`가 2개다.
    - `searchIndex.search(JournalSearchQuery(text: …, kind: .memo))`가 그 기록을 돌려준다.
  - `testDeleteKindRetargetsClassificationRules`
  - `testUnknownKindIdsShowInSidebarBeforeUnclassified`:
    - `custom-ZZZ` 기록을 저장하고 `refresh()`를 부른다.
    - `unknownKinds == [JournalKind(id: "custom-ZZZ")]`이다.
    - `sidebarKinds`에서 그 항목이 "이름 없는 유형"이고, 미분류 바로 앞이다.
    - 기록의 `kind`는 그대로다.
  - `testLockedAccessShowsPremiumNoticeInsteadOfEditor`:
    - `canManageKinds == false`인 테스트 더블을 쓴다.
    - `openKindManagement()` 뒤 `isPresentingPremiumNotice == true`이고 `isPresentingKindManagement == false`이다.
  - `testBackupRoundTripRestoresKindCatalog`:
    - 모델 A에서 유형을 만든다.
    - 백업 데이터는 `await modelA.prepareBackup()` 뒤의 `modelA.backupDocument!.data`다.
    - 새 defaults의 모델 B에서 `restoreBackup(data:mode: .merge)`를 부른다.
    - B의 카탈로그에 그 유형이 있다.
- **`NewEntryDefaultsTests`**에 추가:
  - `testNewEntryFallsBackWhenDiaryIsDeleted`: 일기를 메모로 삭제한 뒤 `selectedKind = nil`이면 `defaultKindForNewEntry`가 `creatableKinds.first`다.
  - `testNewEntryUsesSelectedCustomKind`

- [ ] **Step 2: 실패 확인**

  ```sh
  swift test --filter PilgrimJournalTests.KindManagementModelTests
  ```

  Expected: 컴파일 실패.

- [ ] **Step 3: `FeatureAccess.swift`와 `AppModel` 구현.**

- [ ] **Step 4: 통과 확인**
  - 실행:

    ```sh
    swift test --filter PilgrimJournalTests
    ```

  - Xcode iOS·macOS 빌드도 실행한다.
  - Expected: PASS.

- [ ] **Step 5: 커밋**

  ```sh
  git commit -m "feat(app): wire the kind catalog, deletion and premium gate into AppModel"
  ```

---

### Task 7: 화면이 카탈로그를 쓰도록 바꾸기

**Files:**
- Modify: `Sources/PilgrimJournal/DesignSystem.swift:49-58`
  - `categoryColor(for kind:)`를 `color(for token: KindColorToken)`으로 바꾸고 `categoryColor(for definition: KindDefinition)`를 더한다.
- Modify: `Sources/PilgrimJournal/ContentView.swift:107,568-725,749,759`
- Modify: `Sources/PilgrimJournal/EntryViews.swift:215-224,661,693-704,918,969-971,1991,2006-2026`
- Modify: `Sources/PilgrimJournal/OrganizationSettingsViews.swift:53,148-150`
- Modify: `Sources/PilgrimJournal/SettingsAndImportViews.swift:519-525,665`
- Test: `Tests/PilgrimJournalTests/DesignSystemTests.swift`

**Interfaces:**
- Consumes: Task 6 `model.kindCatalog`, `sidebarKinds`, `kindDefinition(for:)`, `openKindManagement()`, `featureAccess.canManageKinds`
- Produces: `JournalTheme.color(for: KindColorToken) -> Color`, `JournalTheme.categoryColor(for: KindDefinition) -> Color`

**규칙:**
- **색 토큰 → (light, dark):**
  - 앞 6개는 지금 `categoryColor` 값과 같다.
    - `amber`(0x9B6B25, 0xE1B869)
    - `sage`(0x56745B, 0x90B895)
    - `slate`(0x55758C, 0x8DB4CE)
    - `clay`(0x9B5E54, 0xD89A90)
    - `iris`(0x6B668C, 0xAAA4CE)
    - `stone`(0x68716C, 0xAAB3AE)
  - 새 2개:
    - `teal`(0x3F7A78, 0x86C2BF)
    - `rose`(0x9C5574, 0xD99BB8)
- **사이드바:**
  - "전체 기록" 다음에 `Section`을 둔다. 머리는 `HStack { Text("유형"); Spacer(); 편집 버튼 }`이다.
  - 편집 버튼 라벨은 게이트가 열려 있으면 `"편집"`이고, 잠겨 있으면 `Label("편집", systemImage: "lock.fill")`이다. 동작은 `model.openKindManagement()`다.
  - 행은 `model.sidebarKinds`이고, 아이콘은 `KindIconCatalog.displaySymbol(for: def.iconToken)`이다. `icon(for:)`는 지운다.
- **유형 선택 목록:**
  - 편집기 두 곳, 일괄 정리, 분류 규칙: `model.kindCatalog.creatableKinds`, 표시 이름은 `def.name`이다.
  - 편집 중인 기록의 현재 유형이 목록에 없으면(삭제됐거나 모르는 ID) 그 유형을 `kindDefinition(for:)`로 목록 맨 앞에 끼운다. 선택값이 사라지지 않게 하기 위해서다.
  - Day One 미리보기: `activeKinds`를 쓴다.
- **이름 표시:** `fallbackName`을 쓰던 화면 표시는 `model.kindDefinition(for: kind).name`으로 바꾼다. 위치: `ContentView:107,759`, `EntryViews:661,694,918,1991`, `OrganizationSettingsViews:53`, `SettingsAndImportViews:665`.
- **배지 색:** `categoryColor(for: model.kindDefinition(for: entry.kind))`를 쓴다.
- **이 작업에서는 편집 시트를 만들지 않는다.** `isPresentingKindManagement`·`isPresentingPremiumNotice`의 `.sheet` 연결은 Task 8에서 한다.

- [ ] **Step 1: 실패하는 테스트 작성** (`DesignSystemTests`)

  ```swift
  func testEveryColorTokenMapsAndBuiltInsKeepTheirColors() {
      XCTAssertEqual(KindColorToken.allCases.count, 8)
      XCTAssertEqual(KindCatalog.defaultDefinition(for: .prayer).colorToken, .amber)
      XCTAssertEqual(KindCatalog.defaultDefinition(for: .unclassified).colorToken, .stone)
  }
  ```

  - `import JournalDomain`을 추가한다.
  - Xcode 빌드가 `categoryColor(for: JournalKind)` 제거로 실패하는 것도 이 단계의 "실패"에 포함한다.

- [ ] **Step 2: 구현** — 위 규칙대로 각 파일을 바꾼다. 남은 `JournalKind.builtIns`와 `fallbackName` 화면 사용처를 아래 명령으로 찾는다.

  ```sh
  git grep -n "builtIns\|fallbackName" -- Sources/PilgrimJournal
  ```

  Expected: `PilgrimJournalApp.swift` 픽스처 외 0건.

- [ ] **Step 3: 통과 확인**
  - 실행:

    ```sh
    swift test --filter PilgrimJournalTests
    ```

  - Xcode iOS·macOS 빌드도 실행한다.
  - Expected: PASS.

- [ ] **Step 4: 커밋**

  ```sh
  git commit -m "feat(ui): read kind names, colours and order from the catalog"
  ```

---

### Task 8: "유형 편집" 시트, 유료 안내, Debug 잠금 스위치

**Files:**
- Create: `Sources/PilgrimJournal/KindManagementViews.swift`
  - `KindManagementSheet`
  - `KindDetailEditor`
  - `KindDeletionDialog` 상태
  - `PremiumFeatureNoticeSheet`
- Modify: `Sources/PilgrimJournal/ContentView.swift`: 두 `.sheet` 연결
- Modify: `Sources/PilgrimJournal/SettingsAndImportViews.swift`: `#if DEBUG` 구역에 `Toggle("유료 기능 잠금 시뮬레이션", isOn: $simulateLocked)`를 둔다. `@AppStorage(UnlockedFeatureAccess.simulateLockedKey)`에 묶는다.

**Interfaces:**
- Consumes: Task 6의 모든 `AppModel` 유형 메서드, Task 2 `KindIconCatalog.symbols`, `KindColorToken.allCases`, `KindCatalogError.errorDescription`, Task 7 `JournalTheme.color(for:)`
- Produces: 없음(최종 화면)

**화면 규칙** (스펙 4절):
- **`KindManagementSheet`:** `NavigationStack` 안의 `List`이고, 제목은 "유형 편집", 툴바에 "완료"가 있다.
  - **첫 섹션:** `model.kindCatalog.creatableKinds`(+ `unknownKinds`)를 보여 준다.
    - 순서 변경: `.onMove` → `model.reorderKinds`
    - 삭제: `.onDelete` 또는 스와이프 → 삭제 확인
    - 행 탭: `KindDetailEditor` 푸시
    - iOS는 `.environment(\.editMode, .constant(.active))`로 항상 편집 상태다. macOS는 `onMove`·`onDelete` 기본 동작을 쓴다.
  - **같은 섹션 끝:** 회색 미분류 행(`.disabled(true)`, 이동·삭제 불가)과 "+ 유형 추가" 행.
  - **두 번째 섹션 "삭제한 기본 유형":** `deletedBuiltIns`가 있을 때만 보인다. 행마다 "되살리기" 버튼 → `model.restoreKind`.
- **삭제 확인:**
  - 먼저 `model.entryCount(for:)`를 부른다.
  - 0개면 `deleteKind(kind, moveTo: .unclassified)`를 바로 부른다.
  - 1개 이상이면 `confirmationDialog`를 띄운다.
    - 제목: "‘\(name)’을(를) 삭제할까요?"
    - 메시지: "기록 \(count)개를 어디로 옮길까요?"
    - 버튼: 이동 대상(자기 자신을 뺀 활성 유형 + 미분류)마다 "\(name)(으)로 옮기고 삭제"를 둔다. 미분류가 첫 버튼이다.
    - 취소 버튼이 있다.
  - 오류는 시트 상단에 빨간 텍스트로 보여 준다.
- **`KindDetailEditor`:**
  - `TextField("유형 이름")`, 색 8개 원형 격자, 아이콘 20개 격자(`LazyVGrid`, 선택은 테두리로 표시), 미리보기 행(사이드바 행과 같은 모양)이 있다.
  - "저장"은 `createKind` 또는 `updateKind`를 부른다. `KindCatalogError`는 이름 필드 아래에 인라인으로 보여 준다.
  - 새 유형의 초기 색과 아이콘: 활성 유형이 쓰지 않는 첫 `KindColorToken`과 `"tag"`. 모두 쓰였으면 `.teal`이다.
- **`PremiumFeatureNoticeSheet`:**
  - 제목: "유료 기능"
  - 본문: "유형 추가·삭제·편집은 유료 버전에서 쓸 수 있습니다. 지금 있는 유형으로 기록을 쓰고 옮기는 것은 계속 할 수 있습니다."
  - 버튼: "닫기"

- [ ] **Step 1: 구현**
  - 화면만 있는 작업이라 단위 테스트 대신 아래 빌드와 실행 확인으로 검증한다. 로직은 Task 6 테스트가 덮는다.

- [ ] **Step 2: 빌드 확인** — Xcode iOS·macOS 빌드. Expected: `BUILD SUCCEEDED` 두 번.

- [ ] **Step 3: 시뮬레이터 실행 확인** (iOS 시뮬레이터, `LOCAL_ONLY` 또는 Debug 로그인 우회는 `docs/development.md` 참고)
  1. 편집 → "설교노트" 추가(teal, `book.closed`) → 사이드바 미분류 앞에 나온다.
  2. 기도노트 기록 1개 작성 → 기도노트 삭제 → 확인 창에서 "일기로 옮기고 삭제" → 그 기록이 일기에 있고 본문 끝에 `기도 상태:` 줄이 있다.
  3. "삭제한 기본 유형"에서 기도노트 되살리기 → 사이드바에 다시 나온다.
  4. 설정에서 잠금 시뮬레이션을 켜고 편집을 누르면 유료 안내가 뜬다. 이미 만든 "설교노트"로 새 기록을 쓸 수 있다.

  각 단계의 스크린샷을 남긴다.

- [ ] **Step 4: 커밋**

  ```sh
  git commit -m "feat(ui): add the kind editing sheet and premium notice"
  ```

---

### Task 9: 런타임 체크, 문서, 전체 게이트

**Files:**
- Modify: `Sources/JournalChecks/main.swift`: 체크 블록 하나 추가
- Modify: `docs/superpowers/specs/2026-10-15-user-managed-kinds-design.md`: 2절 정리 작업 실행 시점을 이 계획의 "스펙과 다른 점"대로 고친다.
- Modify: `CLAUDE.md`: Project 단락의 "organizes them into kinds …"를 "organizes them into user-manageable kinds (defaults: …)"로 바꾼다. `JournalDomain` 설명에 `KindCatalog`를 한 줄 추가한다.
- Modify: `docs/user-guide.md`: 유형 편집 사용법 한 절을 추가한다.
- Modify: `docs/implementation-todo.md`: "2단계: StoreKit 결제·구매 복원, `FeatureAccess` 기본값을 잠김으로"를 추가한다.
- Modify: `docs/pre-release-checklist.md`: "미룬 항목"에 스펙 6·7절 실기기 확인 3개와 "유형 편집 전 모든 기기 업데이트"를 추가한다.

- [ ] **Step 1: `JournalChecks`에 체크 추가** — `InMemoryJournalRepository`로 다음을 확인한다.
  1. `KindCatalog().create("설교노트")`
  2. 그 유형으로 저장
  3. `list(kind:)`로 1개 확인
  4. 카탈로그에서 삭제(대상 메모)
  5. `KindDeletionService.moveEntries`
  6. `kind == .memo` 확인

  실패 메시지: "사용자 유형 저장·이동 확인이 실패했습니다."

- [ ] **Step 2: 체크 실행**

  ```sh
  swift run JournalChecks
  ```

  Expected: 실패 메시지 없이 종료 코드 0.

- [ ] **Step 3: 문서 수정** — 위 Files 목록대로.

- [ ] **Step 4: 전체 게이트**

  ```sh
  ./scripts/check.sh
  ```

  Xcode iOS·macOS 빌드도 실행한다. Expected: lint·build·test·checks·개인 데이터 스캔 모두 통과, `BUILD SUCCEEDED` 두 번.

  lint가 실패하면 아래 명령으로 고친 뒤 다시 실행한다.

  ```sh
  swift format format -i --recursive Sources Tests
  ```

- [ ] **Step 5: 커밋**

  ```sh
  git commit -am "docs: document user-managed kinds and add the runtime check"
  ```
