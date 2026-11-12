## Context

`AttachmentTransferState`(`Sources/JournalDomain/JournalRecords.swift:161-167`, 현재 `local | pending | uploaded | downloading | failed`)와 `AppModel.handleCloudSyncStoreEvent`(`Sources/PilgrimJournal/AppModel.swift:180-210`)가 세 항목이 공유하는 상태 기계다. `handleCloudSyncStoreEvent`는 `PilgrimJournalApp.swift:632-656`의 `cloudSyncStoreEvent(from:)`가 `NSPersistentCloudKitContainer.eventChangedNotification`을 매핑해 만든 `CloudSyncStoreEvent`를 받는다. 이 이벤트는 `NSPersistentCloudKitContainer.Event`의 `type`/`startDate`/`endDate`/`succeeded`만 노출한다 — 바이트 단위 진행률이나 레코드별 완료 신호는 없다.

앱은 SwiftData의 네이티브 `ModelConfiguration.CloudKitDatabase`(`NSPersistentCloudKitContainer` 기반)를 쓴다. `Sources/JournalData/CloudIdentityBinding.swift:90-122`, `Sources/JournalData/CloudKitDataWiper.swift:26-27`에서 이미 raw `CKContainer.privateCloudDatabase`를 직접 쓰는 선례가 있지만, 둘 다 앱이 소유한 커스텀 레코드 타입에 대한 것이지 SwiftData가 자동 미러링하는 `CD_` 접두사 레코드 타입에 대한 것이 아니다. `docs/known-issues.md`가 경고하는 "손으로 레코드를 만들어 유도하지 말 것"과 같은 계열의 위험이 이 mangled 내부 타입에도 적용된다.

첨부 저장 경로는 `AttachmentFileStore`(`Sources/JournalData/AttachmentFileStore.swift`, checksum 기반 CAS)와 `AttachmentRepository`(`Sources/JournalDomain/JournalRepository.swift:85-93`)이며, "첨부 추가" UI(`AttachmentEditorSection`, `EntryViews.swift:1104+`)가 `AppModel.addAttachment(from:to:)`(`AppModel.swift:940-969`)를 통해 이미 이 경로를 쓰고 있다.

라이브 마크다운 에디터(`LiveMarkdownTextEditor`, `MarkdownSupport.swift` macOS `NSViewRepresentable`/iOS `UIViewRepresentable`)는 `docs/known-issues.md`의 "편집기 입력이 씹힌다" 섹션이 다루는 회귀 이력이 있는 코드다. 그 수정이 만든 `publishedHistory` + `MarkdownInputReconciliation.shouldApplyExternalText` echo 감지 메커니즘, 그리고 그 위에서 동작하는 `Coordinator.replaceExternalText`(이미 undo 등록·재스타일링·`publish(_:)`를 처리)가 이번 붙여넣기 기능이 반드시 재사용해야 할 유일하게 안전한 프로그래밍적 텍스트 삽입 경로다.

## Goals / Non-Goals

**Goals:**
- 다운로드 버튼이 "무한 스피너"에서 "타임아웃 후 명확한 재시도"로 바뀐다.
- 업로드 상태에 "전송 중" 구분이 생긴다(스토어 단위 근사치, 바이트 단위 아님).
- 클립보드 이미지가 첨부로 저장되고, 붙여넣은 자리는 마크다운 참조로 남아 보기 모드에서 실제 이미지로 렌더링된다.
- 위 세 가지를 새 canonical 모델/속성 없이 구현한다.

**Non-Goals:**
- **CloudKit에 특정 레코드의 asset을 강제로 fetch하는 기능.** `ModelConfiguration.CloudKitDatabase`에는 공개 API가 없다. `CD_` 접두사 mangled 레코드 타입에 직접 raw CloudKit(`CKFetchRecordsOperation`)을 쓰는 것은 undocumented 내부 구현(OS 버전에 따라 바뀔 수 있는 Core Data 내부 네이밍)에 의존하는 것이라 배제한다. 재저장(`context.save()`)은 로컬 변경의 export만 유도할 뿐 remote import를 앞당기지 않는다는 것도 확인했다 — 진짜로 쓸 수 있는 가벼운 nudge는 없다.
- **바이트 단위/퍼센트 업로드 진행률.** `NSPersistentCloudKitContainer.Event`가 노출하는 것은 `type`/`startDate`/`endDate`/`succeeded`뿐이다. 스토어(operation) 단위 상태 구분이 이 API로 낼 수 있는 한계다.
- **라이브 에디터 내 WYSIWYG 인라인 이미지 렌더링.** `LiveMarkdownStyler`는 저장되는 마크다운 문자를 절대 바꾸지 않는다는 불변조건을 갖고 있다(체크박스도 문자 치환 대신 커스텀 드로잉으로 구현된 이유, `MarkdownSupport.swift:1373-1381` 주석 참고). 인라인 이미지는 줄 높이/레이아웃에 영향을 줘야 해서 체크박스 같은 오버레이 드로잉으로는 구현할 수 없고, 진짜 `NSTextAttachment`(문자를 U+FFFC로 치환)가 필요한데 이는 그 불변조건과 정면 충돌하고 편집기 입력 씹힘 회귀가 발생했던 것과 같은 종류의 취약한 경로다.
- **첨부 파일 크기 제한.** 기존 "첨부 추가"(파일 선택)에도 크기 검증이 없다 — 붙여넣기만 더 엄격하게 만들어 불일치를 만들지 않는다.
- **클립보드에 이미지가 여러 개 있을 때 전부 처리.** 1차 범위는 첫 번째 이미지 항목만 처리한다.

## Decisions

**다운로드 타임아웃 UI.** `AttachmentEditorSection.attachmentAction(_:)`(`EntryViews.swift:1253-1288`)의 `.downloading` 분기를 별도 `AttachmentDownloadStatusView`(자체 `@State`가 필요해 `@ViewBuilder` 케이스가 아니라 독립된 `View` 구조체)로 뺀다. `.task(id: attachment.updatedAt)`으로 타임아웃을 건다 — `attachment.id`가 아니라 `updatedAt`을 키로 잡아야 `retryAttachmentTransfer`가 `updatedAt`을 갱신할 때 타이머가 자동으로 리셋된다. `model.isCloudImportInProgress`가 true인 동안은 타임아웃 카운트다운을 미루고 "동기화 진행 중"으로 표시하고, 다시 idle이 되면 그때부터 카운트다운을 시작한다. 타임아웃 값(잠정 25초)은 Open Questions에 남긴다.

**`isCloudImportInProgress` 플래그.** `AppModel`에 `@Published private(set) var isCloudImportInProgress = false`를 신설한다. 기존 `syncState`는 로컬 편집(`markLocalMutation`)·setup·계정 문제 등으로 이미 오버로드되어 있어 "import가 지금 진행 중인가"를 재사용하기에 적합하지 않다 — 전용 플래그가 맞다.

**`handleCloudSyncStoreEvent` 재구성.** `CloudSyncStoreEvent`나 `PilgrimJournalApp.swift`의 이벤트 매핑 자체는 변경할 필요가 없다 — `event.operation`은 `completedAt == nil`일 때도 이미 채워져 있는데, 현재 코드(`AppModel.swift:182-185`)의 early-return guard가 그 값을 보기도 전에 버리고 있는 게 실제 버그다. 수정 방향:

```swift
func handleCloudSyncStoreEvent(_ event: CloudSyncStoreEvent) {
    guard cloudAccountMonitor != nil else { return }
    guard let completedAt = event.completedAt else {
        switch event.operation {
        case .exporting:
            updateAttachmentTransferStates(matching: [.pending], to: .uploading)
        case .importing:
            isCloudImportInProgress = true
        case .setup:
            break
        }
        syncState = .pending
        return
    }
    if event.operation == .importing { isCloudImportInProgress = false }
    guard event.succeeded else {
        updateAttachmentTransferStates(
            matching: [.pending, .downloading, .uploading],
            to: .failed
        )
        syncState = .failed(
            message: event.errorDescription ?? "CloudKit 동기화에 실패했습니다.",
            retryable: event.errorRetryable ?? true
        )
        return
    }
    switch event.operation {
    case .setup:
        syncState = .pending
    case .exporting:
        updateAttachmentTransferStates(matching: [.pending, .uploading], to: .uploaded)
        syncState = .synced(completedAt)
    case .importing:
        reconcileDownloadedAttachments()
        syncState = .synced(completedAt)
        rebuildSearchIndex()
        refresh()
    }
}
```

**`.pending`/`.uploading` 동시 매칭이 필수.** 완료 분기(`.exporting` + `completedAt != nil`)는 `[.pending, .uploading]`을 모두 매칭해 `.uploaded`로 옮겨야 한다. 시작 이벤트를 놓친 채(예: 앱이 백그라운드에서 종료됨) 완료 이벤트만 도착한 첨부가 `.pending`에 영원히 머무는 걸 막기 위해서다 — `.uploading`만 매칭하면 이 경로가 깨진다. 실패 분기의 매칭 집합에도 `.uploading`을 포함해야, 업로드 도중 실패한 첨부가 재시도 버튼 없는 상태로 멈추지 않는다.

**CloudKit 믹스드 버전 호환 위험.** `AttachmentEntity.stateRaw`(`SwiftDataModels.swift:49`)는 CloudKit으로 동기화되는 `String` 컬럼이다. 이 변경을 아직 설치하지 않은 기기가 들어오는 `"uploading"` raw value를 `AttachmentTransferState(rawValue:) ?? .failed`(`SwiftDataJournalRepository.swift:373`)로 디코드하면 `.failed`로 잘못 표시된다. 사용자가 "재시도"를 누르면 `.pending`으로 되돌아가 재업로드가 다시 큐잉될 뿐이라 데이터 손실은 없지만, 구버전 기기에서 가짜 오류 UI가 보이는 것은 감수하는 리스크다 — 강제 업데이트 메커니즘이 없는 이 앱 구조에서 CloudKit 동기화 필드에 새 enum case를 추가할 때 항상 따르는 근본적 제약이며, 이번 변경 범위에서 해결할 수 없다.

**이미지 붙여넣기 삽입 경로.** macOS `MarkdownNSTextView`, iOS `MarkdownUITextView`에 `paste(_:)`를 오버라이드한다:

```swift
override func paste(_ sender: Any?) {
    if handleImagePaste?() == true { return }
    super.paste(sender)
}
```

클립보드에 이미지가 없으면 `handleImagePaste`가 `false`를 반환해 `super.paste(sender)`로 넘어가고, 기존 텍스트 붙여넣기 동작은 그대로 보존된다. `paste(_:)`가 이미지 붙여넣기 액션의 유일한 진입점이므로, 이미지가 발견됐을 때 `super`를 호출하지 않으면 macOS `NSTextView`가 기본으로 하는 리치 텍스트 삽입(현재 버그의 원인 — 화면엔 잠깐 보였다 `textView.string` 재조회 시 사라짐) 경로 자체가 실행되지 않는다. 비동기 경합 없이 깔끔하게 막힌다.

실제 텍스트 삽입은 기존에 이미 안전하다고 검증된 `Coordinator.replaceExternalText`(툴바 서식 삽입이 쓰는 것과 동일 — undo 등록, `LiveMarkdownStyler` 재적용, `publish(_:)`로 echo 방지까지 이미 처리됨)를 그대로 통과시킨다. **새로운 raw `NSTextStorage`/`insertText` 조작을 추가하지 않는다** — `docs/known-issues.md`의 편집기 입력 씹힘 회귀가 정확히 이런 종류의 우회 경로(바인딩을 거치지 않은 직접 텍스트 조작)에서 발생했었다.

**마커는 항상 독립된 줄에 삽입.** `MarkdownCommandProcessor.insertingAttachmentImage(id:into:selection:)`가 커서 앞뒤에 필요한 개행을 강제로 넣어 `![](attachment:<uuid>)`가 항상 자기 줄을 차지하게 한다. `MarkdownDocumentParser.parse`(`MarkdownSupport.swift:832-929`)는 줄 단위로 블록을 분류하고 연속된 비-공백 줄을 하나의 `.paragraph`로 합친다 — 마커가 독립된 줄이 아니면 문단에 섞여 `MarkdownPreviewView`에서도 이미지가 아닌 리터럴 텍스트로만 보인다.

**`entryID` 해석 재사용.** `MarkdownBodyEditor`(`MarkdownSupport.swift:980+`)에 `entryID: UUID?`, `ensureEntryID: (() -> UUID?)?`, `storeImageAttachment: ((Data, String, String) -> UUID?)?` 세 파라미터를 추가하고, macOS/iOS 양쪽 `LiveMarkdownTextEditor`와 그 `Coordinator`까지 배선한다. `EntryViews.swift`의 두 호출부(`InlineEntryEditorView:75-79`, `EntryEditorView:667` 부근)는 바로 옆 `AttachmentEditorSection`에 이미 전달 중인 `persistedEntryID`/`ensurePersistedEntryID`를 그대로 재사용한다 — 미저장 신규 기록의 지연 저장 로직을 새로 만들지 않는다. `MarkdownSupport.swift`는 오늘 `Foundation`/`SwiftUI`/`AppKit`/`UIKit`만 import하므로 `AppModel`/`JournalDomain`을 직접 참조하지 않고 클로저로 주입한다.

**`AppModel.addAttachment` 분리.** 기존 `addAttachment(from url:to:)`(`AppModel.swift:940-969`)에서 `Data(contentsOf:)` 이후의 로직(스토어 저장 → state 세팅 → save → `attachmentRevision` 증가 → `markLocalMutation()`)을 `addAttachment(data:originalName:mimeType:to:) -> UUID?`로 분리하고, 기존 함수가 URL에서 Data를 읽은 뒤 이를 호출하도록 리팩터링한다. 붙여넣기는 URL이 아니라 pasteboard에서 얻은 raw `Data`를 직접 갖고 있으므로 신설 함수를 바로 쓴다. `AttachmentRepository` 프로토콜 시그니처는 변경하지 않는다.

**보기 모드 렌더링.** `MarkdownBlockKind`(`MarkdownSupport.swift:815-823`, 기존 `heading`/`paragraph`/`bullet`/`numbered`/`checklist`/`quote`/`code`/`divider`와 같은 패턴)에 `.image(UUID)` 케이스를 추가한다. `MarkdownDocumentParser.parse`의 줄 단위 루프에 문단 폴백 이전 단계로 `![](attachment:<uuid>)` 단독 줄 인식 분기를 넣는다. `MarkdownPreviewView`(`MarkdownSupport.swift:2754+`, 현재 `EntryDetailView`에서만 호출되고 그 뷰가 이미 `model: AppModel`을 환경에 제공 중)가 `@EnvironmentObject`로 `AppModel`을 받아 `model.attachmentBinary(for:)`/`model.hasLocalBinary(for:)`(둘 다 기존 헬퍼, `AppModel.swift:869/888/897`)로 이미지를 해석해 렌더링한다. 바이너리가 아직 없으면(다운로드 전이거나 삭제됨) 자리표시자를 보여준다.

## Risks / Trade-offs

**[Risk] CloudKit 믹스드 버전 호환** — 위 Decisions 참고. 강제 업데이트가 없는 앱 구조의 근본적 제약으로 받아들인다.

**[Risk] 라이브 에디터는 붙여넣기 직후에도 원시 마크다운 텍스트만 보여준다(WYSIWYG 아님).** 사용자가 "붙여넣었는데 그림이 안 보인다"고 오인할 수 있다. → 완화책은 tasks.md에서 결정: 붙여넣기 직후 짧은 안내(토스트/인라인 텍스트)를 보여줄지, 아니면 마크다운 구문 자체("이미지 첨부됨" 같은 표시)를 조금 더 읽기 쉽게 만들지.

**[Risk] 다운로드 타임아웃 25초는 실기기 검증 전 잠정값이다.** 실제 CloudKit import 지연을 관찰한 뒤 조정이 필요할 수 있다.

**[Risk] `MarkdownPreviewView`가 `@EnvironmentObject`를 새로 요구하게 된다.** 현재 유일한 호출부(`EntryDetailView`)는 이미 `model`을 환경에 제공하므로 안전하지만, 앞으로 이 뷰가 `AppModel` 없이 재사용되면 크래시한다(`@EnvironmentObject`는 누락 시 fatal error). latent 제약으로 기록해두고, 향후 재사용 시 주의하도록 한다.

## Migration Plan

새 canonical 모델이나 canonical 모델의 새 속성이 없다. CloudKit 스키마 재배포가 필요 없으므로 `docs/known-issues.md`의 스키마 드리프트 절차는 이 변경에 적용되지 않는다. `AttachmentTransferState`에 raw string case(`"uploading"`)를 추가하는 것뿐이고, 이는 기존 `String` 컬럼(`stateRaw`) 안에서 값의 범위가 늘어나는 것이라 데이터 마이그레이션이 필요 없다. 구버전 기기와의 호환 위험은 위 Risks에 기록했다 — 새 스키마 배포와는 무관한, 순수하게 "새로운 raw value를 모르는 구버전 디코더"의 문제다. 롤아웃은 일반 앱 업데이트이며, 구버전 클라이언트는 새 상태를 `.failed`로 잘못 보여줄 뿐 데이터를 훼손하지 않는다.

## Open Questions

- 다운로드 타임아웃 값(잠정 25초) — 실기기에서 CloudKit import 지연을 관찰한 뒤 확정한다.
- 붙여넣기 UX 카피: 후속 인라인 이미지 표시 구현으로 해소했다. 아래 갱신 기록 참고.

## 후속 구현 반영 (2026-10-10)

위 Non-Goals와 Risks의 "라이브 에디터에서 원시 마크다운만 표시"는 최초 설계
시점의 제약이다. 이후 `MarkdownAttachmentImageDecoration`과 플랫폼별 커스텀
드로잉으로 저장 문자열을 유지하면서 이미지를 인라인 표시하도록 구현했다.
`docs/implementation-todo.md`의 완료 기록과 `docs/pre-release-checklist.md`의
2026-08-15 build 21 사용자 확인(사진 붙여넣기·리사이즈·이미지 뒤 입력)을 근거로,
"그림이 안 보임"을 설명하기 위한 별도 안내 카피는 추가하지 않는다.

다운로드 25초는 여전히 잠정값이다. 위 사용자 확인은 CloudKit import 지연의
측정 결과가 아니므로 타임아웃 확정 근거로 쓰지 않는다. task 7.5는 이 실기기
관찰이 남아 있어 미완료로 유지한다.
