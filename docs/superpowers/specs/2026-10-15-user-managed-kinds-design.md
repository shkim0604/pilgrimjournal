# 사용자가 관리하는 기록 유형 — 설계

- 날짜: 2026-10-15
- 상태: 설계 승인됨, 구현 계획 대기
- 범위: 1단계(유형 편집). 2단계(StoreKit 결제·구매 복원)는 별도 스펙.

## 배경과 목표

지금 기록 유형(기도노트·성경공부·독서노트·일기·메모·미분류)은
`Sources/JournalDomain/JournalTypes.swift`의 고정 enum `JournalKind`다.
사용자는 유형 목록에 **편집 모드**를 원한다. 원하는 동작은 다음과 같다.

- 기본 유형을 포함한 유형 **삭제**
- 새 유형 **추가**
- 이름·색·아이콘 **변경**과 **순서 변경**
- 삭제한 기본 유형 **되살리기**

이 기능은 **유료 버전과 무료 버전을 나누는 기준**이 된다. 무료 버전은 기본
유형 구성을 그대로 쓴다. 이번 단계는 유료 게이트의 자리만 마련하고, 결제는
2단계에서 붙인다.

### 사용자와 확정한 결정

| 질문 | 결정 |
|---|---|
| 기본 유형 삭제의 의미 | 완전 삭제. 숨기기가 아니다. |
| 삭제한 유형의 기록 | 삭제 확인 창에서 옮길 유형을 고른다. 기본값은 미분류이고, 기록이 0개면 묻지 않는다. |
| 결제 범위 | 두 단계로 나눈다. 이 스펙은 유형 편집과 게이트 자리까지만 다룬다. |
| 유료에서 무료로 바뀌면 | 현재 구성을 유지한다. 만든 유형으로 기록 작성과 이동은 계속 되고, 추가·삭제·변경만 잠긴다. |
| 새 유형의 속성 | 이름, 색, 아이콘. 색과 아이콘은 프리셋에서 고르고, 전용 필드는 없다. |
| 삭제 시 전용 필드 값 | 본문 끝에 텍스트로 붙인다. |
| 편집 모드에서 할 수 있는 것 | 추가, 삭제, 이름·색·아이콘 변경(기본 유형 포함), 순서 변경, 삭제한 기본 유형 되살리기. |
| 저장 방식 | 접근 A. 기록은 기존 `kindRaw`에 유형 ID를 저장하고, 유형 목록은 iCloud 키-값 저장소에 둔다. |

### 검토하고 택하지 않은 접근

- **B. 숨은 태그(노트북 방식):** 이전 빌드와 가장 잘 호환된다. 그러나 유형
  정보가 `kindRaw`와 태그 두 곳에 나뉜다. 유형별 목록을 DB 조건으로 거를 수
  없어 대량 기록에서 느려지고, 기본 유형 삭제에는 결국 `kindRaw` 변경이
  필요하다.
- **C. 유형 목록을 CloudKit 모델로 저장:** 동기화는 가장 견고하다. 대신 CloudKit
  스키마를 수동으로 배포해야 한다(`docs/known-issues.md`의 반복 문제 영역).
  작업량도 늘어난다.

## 1. 도메인 모델 (JournalDomain)

### `JournalKind`: enum에서 문자열 ID 구조체로

```swift
public struct JournalKind: Hashable, Codable, Identifiable, Sendable {
    public let id: String          // "prayer", "diary", …, "custom-<UUID>"
    public var builtIn: BuiltInKind? { BuiltInKind(rawValue: id) }
    public init(id: String)
    public init?(rawValue: String)  // 호환용. 빈 문자열이 아니면 항상 성공한다.
    public var rawValue: String { id }
    public static let prayer, bibleStudy, reading, diary, memo, unclassified: JournalKind
    public static func custom() -> JournalKind  // "custom-" + UUID().uuidString
}

public enum BuiltInKind: String, CaseIterable, Sendable {
    case prayer, bibleStudy, reading, diary, memo, unclassified
}
```

- **Codable:** 단일 문자열로 인코딩한다(`singleValueContainer`). 지금 enum과
  JSON 형태가 같으므로, 기존 백업과 리비전 스냅샷을 그대로 읽는다.
- **모르는 ID 보존:** 모르는 ID도 그대로 디코딩한다. `?? .unclassified`로
  바꾸던 코드(`SwiftDataJournalRepository.map`, `JournalSearchIndex`의
  `JournalKind(rawValue:)`, `mapRule`)는 ID를 보존하도록 고친다.
- **`switch kind` 분기:** `switch kind.builtIn`으로 바꾼다. `nil`(사용자 유형)은
  메모와 같은 동작이다. `EntryDetails.validated(for:)`에서 사용자 유형은 전용
  필드를 모두 비운다.
- **`localizedName`과 `canCreateManually` 이동:** `JournalKind`에서 빼고
  `BuiltInKind.defaultName`과 `BuiltInKind.canCreateManually`로 옮긴다. 화면에
  보이는 이름은 카탈로그에서 가져온다.
- **`JournalError.invalidManualKind` 문구:** 유형 이름을 나열하지 않는 고정 문장으로
  바꾼다. 문구에 유형 이름이 들어 있는지 확인하던
  `JournalDomainTests`의 기존 단언도 함께 고친다.

### `KindDefinition`

```swift
public struct KindDefinition: Codable, Equatable, Sendable {
    public var kind: JournalKind
    public var name: String
    public var colorToken: KindColorToken   // 프리셋 enum, 8개
    public var iconToken: String            // KindIconCatalog에 있는 SF Symbol 이름
    public var order: Int
    public var state: KindState             // .active | .deleted(moveTarget: JournalKind)
    public var updatedAt: Date
    public var modifiedByDeviceID: String
}
```

- **기본값:** 기본 유형 5개와 미분류의 기본 정의(이름·색·아이콘)는 지금 값과
  같다(`DesignSystem.categoryColor`, `ContentView.icon(for:)`).
- **색 프리셋:** 지금 6색에 2색을 더해 8개다. 토큰을 `JournalTheme`에서 라이트·
  다크 색으로 바꾼다.
- **아이콘 프리셋:** 기본 유형 아이콘 6개를 포함해 약 20개다. 저장된 토큰이 목록에
  없으면 `"tag"` 아이콘으로 표시한다.

### `KindCatalog` (순수 값 타입)

- **보관:** 저장된 정의를 담는다. 카탈로그에 없는 기본 유형은 기본 정의가
  `active` 상태로 있는 것으로 본다. 그래서 빈 카탈로그가 곧 지금 구성이다.
- **조회:**
  - `activeKinds`: `order` 순서이고, 미분류는 항상 맨 끝이다.
  - `creatableKinds`: 활성 유형에서 미분류를 뺀 목록이다.
  - `deletedBuiltIns`: 삭제된 기본 유형 목록이다.
  - `definition(for:)`: 모르는 ID면 이름이 "이름 없는 유형"이고 색·아이콘이
    회색 `tag`인 정의를 만들어 돌려준다.
- **변경 연산:** `create`, `update`(이름·색·아이콘), `reorder`, `delete(moveTarget:)`,
  `restore`. 각 연산은 `updatedAt`과 `modifiedByDeviceID`를 기록한다.
- **검증:**
  - 이름은 앞뒤 공백을 제거하고 1~20자여야 한다.
  - 활성 유형 사이에서 대소문자를 무시하고 고유해야 한다.
  - 미분류는 변경할 수 없다.
  - 마지막 남은 작성 가능 유형은 삭제할 수 없다.
  - 이동 대상은 삭제하려는 유형 자신이 아닌 활성 유형이어야 한다.
  - 실패하면 `KindCatalogError`를 던진다. 오류 문구는 한국어다.
- **병합(`merged(with:)`):** 유형 ID별로 `updatedAt`이 늦은 쪽을 택한다. 같으면
  `modifiedByDeviceID`를 문자열로 비교해 큰 쪽을 택한다. `RevisionResolver`의
  규칙과 같은 순서다.
- **이동 대상 해석(`resolvedTarget(for:)`):** `deleted(moveTarget)` 체인을 따라간다.
  활성 유형에 닿으면 그 유형을 돌려준다. 순환하거나 체인 끝이 카탈로그에 없으면
  미분류를 돌려준다. 활성 유형이거나 카탈로그에 없는 ID면 `nil`(옮기지 않음)이다.

### 전용 필드의 본문 변환

`EntryDetails.carryOverText(from: BuiltInKind) -> String?`는 버려질 전용 필드
값을 사람이 읽을 수 있는 줄로 만든다. 값이 없으면 `nil`이다. 예:

```
---
기도 상태: 응답됨 (2026-05-01)
```

| 유형 | 붙이는 줄 |
|---|---|
| 기도노트 | `기도 상태: 기도 중` 또는 `기도 상태: 응답됨 (응답일)` |
| 성경공부 | `본문: <구절>` |
| 독서노트 | `책: <제목> / 저자: <저자>` (있는 것만) |
| 일기 | `기분: <기분>` |

날짜는 `yyyy-MM-dd` 형식이고 기록의 `originalTimeZone`을 따른다.

## 2. 저장과 동기화

- **기록:** 기존 `JournalEntryEntity.kindRaw`에 `JournalKind.id`를 저장한다.
- **분류 규칙:** 기존 `ClassificationRuleEntity.targetKindRaw`에 저장한다.
- **CloudKit 스키마 변경 없음.** `canonicalModels`에 필드를 추가하지 않는다.
- **카탈로그 저장소(`KindCatalogStore`, JournalData):**
  - 카탈로그를 JSON 한 덩어리로 `UserDefaults`와 `NSUbiquitousKeyValueStore`의
    키 `journal-kind-catalog`에 저장한다.
  - 노트북 카탈로그와 같은 시점에 병합한다: 앱 시작, 포그라운드 복귀,
    `didChangeExternallyNotification`(`PilgrimJournalApp.swift`에 이미 구독 있음).
  - 병합은 `KindCatalog.merged(with:)`로 하고, 결과를 두 저장소에 다시 쓴다.
  - iCloud KV 사본은 타임스탬프를 초 단위로 정규화해 저장한다. 병합 결과는 ID 순으로
    정렬해, 두 저장소 중 다른 쪽에 다시 쓴다. 두 기기가 서로의 값을 계속 덮어쓰지
    않게 하려는 것이다.
  - 기록을 로컬 전용에서 iCloud로 옮길 때도 카탈로그를 함께 옮긴다.
    `AppModel.adoptKindCatalog`를 거치며, 백업 복원과 같은 경로다.
  - 테스트를 위해 `UserDefaults`와 KV 저장소는 주입한다(`AppModel`의 노트북
    저장소 주입과 같은 방식).
- **`AppModel`:** `@Published kindCatalog`를 노출한다. `selectedKind`가 삭제되면
  선택을 "전체 기록"으로 되돌린다.

### 정리 작업 (`KindReconciler`, JournalDomain)

다음 시점에 실행한다. 매 `refresh()`마다 돌리지는 않고, 삭제된 유형이 없으면
건너뛴다.

- 모델의 첫 `refresh()`
- 클라우드 병합으로 카탈로그가 바뀐 때
- CloudKit 가져오기가 끝난 때
- 백업 복원과 로컬→iCloud 범위 이전 직후

- **대상:** 기록 중 `catalog.resolvedTarget(for: entry.kind) != nil`인 것.
- **동작:** 해당 기록을 그 대상으로 옮긴다. 옮기는 방식은 아래 삭제 흐름의 3단계와
  같다.
- **카탈로그에 없는 ID는 건드리지 않는다.** 기록은 CloudKit으로 이미 왔지만
  카탈로그가 KV 저장소로 아직 오지 않은 경우일 수 있다.
- 이런 ID는 사이드바에 "이름 없는 유형"으로 보인다. 사용자는 그 유형의 이름을
  바꾸거나 삭제할 수 있다. 이름을 바꾸면 그 ID로 정의가 생긴다.

## 3. 삭제·되살리기 흐름 (`KindDeletionService`, JournalDomain)

`JournalRepository` 프로토콜만 사용하므로 `InMemoryJournalRepository`로 테스트할
수 있다.

> 이미 손으로 쓴 기록을 미분류로 옮기는 것은 허용한다. 새로 쓰는 손글 기록만
> 구체적인 유형이 있어야 한다. 그렇지 않으면 기본 이동 대상이 미분류인 삭제가
> 모두 실패한다.

1. **확인 창:** "‘기도노트’를 삭제할까요? 기록 N개를 어디로 옮길까요?"라고 묻는다.
   선택지는 활성 유형이고, 기본값은 미분류다. 기록이 0개면 이동 대상을 묻지 않고
   미분류로 기록한다.
2. **카탈로그 표시:** `catalog.delete(kind, moveTarget:)`로 바꾸고 저장한다. 카탈로그를
   먼저 저장하므로, 3단계가 중간에 실패해도 다음 정리 작업이 나머지를 옮긴다.
3. **기록 이동:** 해당 유형의 기록을 `repository.page(kind:includeDeleted:false,
   limit: 500)`로 반복해 읽고, 기록마다 다음을 한다.
   - `carryOverText`가 있으면 본문 끝에 붙인다. 본문이 비어 있으면 구분선 없이
     줄만 넣는다.
   - `kind`를 대상으로 바꾸고 `repository.save(_:deviceID:at:)`로 저장한다.
     리비전이 남으므로 이력에서 이전 상태를 볼 수 있다.
   - 돌려받은 레코드로 검색 색인을 갱신한다. 서비스는 갱신된 레코드 목록을
     돌려주고, `AppModel`이 `searchIndex.upsert`를 부른다.
4. **분류 규칙:** `targetKind`가 삭제된 유형인 규칙을 대상 유형으로 바꿔 저장한다.
5. **선택 상태:** 삭제된 유형이 선택돼 있었으면 "전체 기록"으로 이동한다. 새 기록의
   기본 유형이 삭제된 유형이면 `creatableKinds.first`로 바꾼다.

**되살리기:** `catalog.restore(kind)`는 `deleted`를 `active`로 바꾸고 목록 끝(미분류
앞)에 둔다.

- 이미 옮긴 기록과 본문에 붙인 텍스트는 되돌리지 않는다.
- 전용 필드 기능은 그 유형으로 새로 쓰는 기록부터 다시 동작한다.
- 사용자 유형은 삭제하면 "삭제한 기본 유형" 목록에 나오지 않는다. 되살릴 수 없다.

## 4. 화면 (PilgrimJournal)

### 사이드바 (`ContentView.swift`의 `JournalSidebar`)

- "전체 기록" 아래에 **유형** 섹션을 두고, 섹션 머리에 **편집** 버튼을 둔다.
- 행은 `kindCatalog.activeKinds`에 카탈로그에 없는 ID의 "이름 없는 유형"을
  더한 목록이다.
- "이름 없는 유형"이 될 ID는 노트북처럼 화면에 불러온 기록에서 모은다
  (`refreshNotebookCatalog(from:)`과 같은 방식).
- 아이콘과 색은 `KindDefinition`에서 온다. `icon(for:)`와
  `JournalTheme.categoryColor(for:)`는 정의를 받도록 바꾼다.

### "유형 편집" 시트 (새 파일 `KindManagementViews.swift`)

iOS와 macOS가 같은 시트를 쓴다. macOS 사이드바에는 iOS식 편집 모드가 없기
때문이다.

- **활성 유형 목록:** 끌어서 순서를 바꾼다(`onMove`). 삭제는 밀기 또는 − 버튼이고,
  누르면 1단계의 확인 창이 뜬다.
- **미분류:** 맨 끝에 회색으로 고정되고 편집할 수 없다.
- **행을 누르면 상세 편집:** 이름 입력, 색 8개 격자, 아이콘 격자, 미리보기 행.
  저장하면 검증 오류를 인라인으로 보여 준다.
- **+ 유형 추가:** 같은 상세 편집 화면을 새 유형으로 연다. 기본 색과 아이콘은
  아직 안 쓴 첫 프리셋이다.
- **"삭제한 기본 유형" 구역:** 항목마다 **되살리기** 버튼이 있다.

### 유형 목록을 쓰는 다른 곳

`JournalKind.allCases` 대신 카탈로그를 쓴다.

| 위치 | 바꿀 목록 |
|---|---|
| 편집기 유형 선택 2곳 (`EntryViews.swift`) | `creatableKinds` |
| 일괄 정리 (`EntryViews.swift`) | `creatableKinds` |
| 분류 규칙 대상 (`OrganizationSettingsViews.swift`) | `creatableKinds` |
| Day One 가져오기 미리보기 (`SettingsAndImportViews.swift`) | `activeKinds` |

- 기록 행과 배지에 쓰던 `entry.kind.localizedName`은
  `model.kindCatalog.definition(for:).name`으로 바꾼다.
- 편집기에서 유형을 바꿀 때 전용 필드를 버린다는 확인 창(`discardedDetailLabels`)은
  지금처럼 유지한다. 이때 본문 변환은 하지 않는다. 변환은 삭제 흐름에서만 한다.
- Day One 분류(`ClassificationEngine`)는 바꾸지 않는다. 규칙의 `targetKind`가
  사용자 유형 ID일 수 있을 뿐이다.

### 유료 게이트

```swift
@MainActor protocol FeatureAccess: AnyObject {
    var canManageKinds: Bool { get }
}
```

- `AppModel`이 주입받고, 편집 시트를 여는 곳 한 군데에서만 읽는다.
- **잠김:** 편집 버튼에 자물쇠가 붙는다. 누르면 "유료 기능" 안내 시트가 뜬다
  (2단계에서 구매 화면으로 교체). 이미 만든 유형으로 기록을 쓰고 옮기는 일은
  잠기지 않는다.
- **1단계 기본값은 열림:** 구현은 `UnlockedFeatureAccess`이고, 모든 빌드에서 열려 있다.
  구매 수단이 아직 없기 때문이다.
- **잠금 시뮬레이션:** Debug 빌드 설정 화면에 "유료 기능 잠금 시뮬레이션"
  스위치(`UserDefaults`)를 둬서 잠긴 화면을 확인할 수 있게 한다.
- **2단계:** StoreKit 기반 구현으로 바꾸고 기본값을 "잠김"으로 한다.

## 5. 백업

- **새 파일:** `JournalBackupService`가 백업에 `kinds.json`을 추가한다. 내용은
  `KindCatalog`의 정의 배열이다.
- **매니페스트:** `BackupManifest`에 `includesKindCatalog: Bool`을 디코딩 기본값
  `false`로 추가한다.
- **복원:** 백업 카탈로그를 현재 카탈로그와 `merged(with:)`로 합쳐 저장한 뒤 정리
  작업을 돌린다.
- **이전 백업:** `kinds.json`이 없으면 현재 카탈로그를 그대로 쓴다. 그 안의 기록은
  기본 유형 ID만 쓰므로 문제가 없다.

## 6. 이전 TestFlight 빌드와의 호환성

이전 빌드는 고칠 수 없으므로 한계를 기록하고 운영으로 막는다.

- **이전 빌드에서 사용자 유형 기록:**
  - 미분류로 보인다(`?? .unclassified`).
  - 그 빌드에서 편집해 저장하면 `kindRaw`가 `unclassified`로 덮인다. 본문과
    필드는 보존된다.
  - 그 기록의 리비전 스냅샷은 디코딩에 실패해 이력이 안 보일 수 있다.
- **이전 빌드에서 새 백업:** `JournalKind` 디코딩에 실패해 복원을 거부한다. 데이터
  손실은 없다.
- **대응:** `docs/pre-release-checklist.md`에 "유형 편집을 쓰기 전에 모든 기기를 이
  빌드 이상으로 업데이트"를 적는다. 앱은 아직 App Store에 출시되지 않았다.

## 7. 테스트

### 단위 테스트 (`swift test`)

- **`JournalDomainTests`:**
  - `JournalKind` JSON 왕복: 기본 ID 문자열이 그대로인지, 모르는 ID가 보존되는지.
  - `KindCatalog`:
    - 빈 카탈로그가 지금 구성과 같은지.
    - 각 검증 규칙.
    - 병합: 최신 우선, 동률이면 deviceID.
    - 삭제·되살리기.
    - `resolvedTarget` 체인, 순환, 모르는 ID.
  - `carryOverText`: 유형별 출력, 값 없음, 시간대.
  - `KindDeletionService`: `InMemoryJournalRepository`로 다음을 확인한다.
    - 기록 이동과 본문 추가.
    - 리비전 생성.
    - 분류 규칙 대상 변경.
    - 삭제된 기록은 건드리지 않는지.
  - `KindReconciler`: 삭제 표시된 유형만 옮기는지, 모르는 ID는 그대로인지.
- **`JournalDataTests`:** SwiftData 저장소가 사용자 유형 ID를 저장·조회·필터하는지,
  `mapRule`이 사용자 유형 대상을 보존하는지. `KindCatalogStore`의 저장과 병합은
  주입한 `UserDefaults`로 확인한다.
- **`JournalSearchTests`:** 사용자 유형 ID로 색인하고 필터하는지.
- **`JournalBackupTests`:**
  - `kinds.json` 왕복.
  - `kinds.json` 없는 백업의 복원.
  - 사용자 유형 기록 왕복.

### 그 밖의 확인

- **`JournalChecks`:** 사용자 유형을 만들고, 기록을 저장·조회한 뒤, 유형을 삭제해
  이동되는지 확인한다.
- **빌드 게이트:** `./scripts/check.sh`와 서명 없는 iOS·macOS `xcodebuild`가 모두
  통과해야 한다.
- **실기기 확인** (`docs/pre-release-checklist.md`에 추가):
  - 두 기기 간 카탈로그 동기화: 추가, 이름 변경, 순서 변경, 삭제, 되살리기.
  - 한 기기가 삭제하는 동안 다른 기기가 오프라인에서 그 유형으로 기록을 쓰고,
    다시 연결한 뒤 정리 작업이 기록을 옮기는지.
  - 백업 → 다른 기기 복원 후 유형 구성.

## 범위 밖

- StoreKit 결제, 구매 복원, 영수증 확인 (2단계 별도 스펙)
- 사용자 유형의 전용 필드나 템플릿
- 미분류의 이름·색 변경
- 기록을 한 번에 다른 유형으로 합치는 별도 "병합" 기능 (삭제 시 이동으로 대신함)

## 문서 갱신

- `CLAUDE.md`와 `docs/user-guide.md`: "고정 유형" 서술을 사용자 관리 유형으로
  고친다.
- `docs/implementation-todo.md`: 2단계(결제)를 남은 일로 추가한다.
- `docs/pre-release-checklist.md`: 6절과 7절의 실기기 확인 항목을 추가한다.
