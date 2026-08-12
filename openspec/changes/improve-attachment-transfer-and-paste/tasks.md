## 1. 도메인

- [x] 1.1 `Sources/JournalDomain/JournalRecords.swift`의 `AttachmentTransferState`에 `.uploading` 케이스를 추가한다.

## 2. 동기화 이벤트 처리

- [x] 2.1 `Sources/PilgrimJournal/AppModel.swift`에 `@Published private(set) var isCloudImportInProgress = false`를 신설한다.
- [x] 2.2 `handleCloudSyncStoreEvent`를 재구성한다: `completedAt == nil` 분기에서 `event.operation`에 따라 `.exporting`이면 `.pending → .uploading`(`updateAttachmentTransferStates`), `.importing`이면 `isCloudImportInProgress = true`로 세팅. 완료 분기에서 `.importing`이면 `isCloudImportInProgress = false`로 리셋.
- [x] 2.3 업로드 완료 매칭 집합을 `[.pending, .uploading]`으로, 실패 매칭 집합을 `[.pending, .downloading, .uploading]`으로 갱신한다(design.md "`.pending`/`.uploading` 동시 매칭이 필수" 참고 — 시작 이벤트를 놓친 첨부가 각각 `.pending`/무한 대기에 갇히지 않도록).
- [x] 2.4 `Tests/PilgrimJournalTests/AppModelNavigationTests.swift`에 이벤트 시퀀스별 상태 전이 회귀 테스트를 추가한다: 시작 이벤트 없이 완료 이벤트만 온 경우도 `.uploaded`로 도달하는지(`testUploadCompletionReachesUploadedEvenWhenStartEventWasMissed`), `.exporting`/`.importing` 시작·완료·실패 각각에서 `isCloudImportInProgress`와 첨부 상태가 기대대로 바뀌는지(`testExportStartEventMarksPendingAttachmentsUploading`, `testUploadFailureWhileUploadingIsRetryable`, `testImportStartAndEndTogglesIsCloudImportInProgress`).

## 3. 다운로드 UI

- [x] 3.1 `Sources/PilgrimJournal/EntryViews.swift`에 `AttachmentDownloadStatusView`(자체 `@State`를 가진 독립 `View` 구조체)를 신설하고, `.task(id: attachment.updatedAt)` 기반으로 타임아웃(잠정 25초) 후 "재시도" UI로 전환한다. `model.isCloudImportInProgress`가 true인 동안은 타임아웃을 미루고 "동기화 진행 중"을 보여준다.
- [x] 3.2 `AttachmentEditorSection.attachmentAction(_:)`의 `.downloading` 분기를 `AttachmentDownloadStatusView`로 교체한다.
- [x] 3.3 `attachmentStatus(_:)`에 `.uploading` 케이스("iCloud 업로드 중" 등)를 추가하고, `attachmentAction(_:)`의 스피너 조건에서 `.uploading`을 `.pending`과 같이 묶는다.

## 4. 첨부 저장 리팩터

- [x] 4.1 `Sources/PilgrimJournal/AppModel.swift`에 `addAttachment(data: Data, originalName: String, mimeType: String, to entryID: UUID) -> UUID?`를 신설한다(기존 `addAttachment(from:to:)`의 `Data(contentsOf:)` 이후 로직을 이 함수로 옮긴다).
- [x] 4.2 기존 `addAttachment(from url:to:)`가 URL에서 Data를 읽은 뒤 4.1의 함수를 호출하도록 리팩터링한다. 기존 `Bool` 반환 시그니처와 호출부(`EntryViews.swift:1179`)는 그대로 유지한다.

## 5. 붙여넣기 삽입 경로

- [x] 5.1 `MarkdownCommandProcessor.insertingAttachmentImage(id: UUID, into text: String, selection: NSRange) -> ExpansionResult`를 순수 함수로 추가한다(커서 앞뒤에 필요한 개행을 강제해 마커가 항상 독립된 줄에 오도록). `Tests/PilgrimJournalTests/MarkdownSupportTests.swift`에 유닛 테스트 4건을 추가했다(빈 문서, 문단 중간, 줄 끝, 이미 개행 뒤).
- [x] 5.2 `MarkdownBodyEditor`에 `storeImageAttachment: ((Data, String, String) -> UUID?)?` 파라미터를 추가하고, macOS/iOS 양쪽 `LiveMarkdownTextEditor`와 `Coordinator`까지 배선한다. (design.md는 `entryID`/`ensureEntryID`도 별도로 threading하는 안을 제시했지만, `storeImageAttachment` 클로저 자체가 호출 시점에 entryID 해석을 캡처하도록 구현이 단순화되어 별도 파라미터 두 개는 불필요해졌다 — `EntryViews.swift`의 클로저가 `persistedEntryID ?? ensurePersistedEntryID()`를 내부에서 호출한다.)
- [x] 5.3 macOS `MarkdownNSTextView`에 `handleImagePaste: (() -> Bool)?` 프로퍼티와 `override func paste(_ sender: Any?)`를 추가한다. `Coordinator`에 `handleImagePaste()`를 구현한다: pasteboard(`NSPasteboard.general`, PNG 우선·TIFF→PNG 변환 폴백)에서 이미지 데이터를 읽고 → `storeImageAttachment` 호출 → `MarkdownCommandProcessor.insertingAttachmentImage` 호출 → 결과를 `replaceExternalText(...)`로 반영.
- [x] 5.4 iOS `MarkdownUITextView`에 동일한 패턴(`handleImagePaste`/`paste(_:)` 오버라이드, `UIPasteboard.general.image` → PNG)을 적용했다.
- [x] 5.5 `Sources/PilgrimJournal/EntryViews.swift`의 두 `MarkdownBodyEditor` 호출부(`InlineEntryEditorView`, `EntryEditorView`)에 `persistedEntryID`/`ensurePersistedEntryID`(옆 `AttachmentEditorSection`에 이미 전달 중인 것과 동일)를 내부에서 사용하는 `storeImageAttachment` 클로저를 배선했다.

## 6. 보기 모드 렌더링

- [x] 6.1 `MarkdownBlockKind`에 `.image(UUID)` 케이스를 추가한다.
- [x] 6.2 `MarkdownDocumentParser.parse`에 `![](attachment:<uuid>)` 단독 줄 인식 분기를 문단 폴백 이전에 추가한다. (테스트 접근을 위해 `MarkdownBlockKind`/`MarkdownBlock`/`MarkdownDocumentParser`의 접근 수준을 `private`에서 파일 기본값(internal)으로 낮췄다 — 외부에 노출되는 API 표면은 그대로다, `PilgrimJournal`은 라이브러리가 아니라 앱 실행 파일이라 영향 없음.)
- [x] 6.3 `MarkdownPreviewView`가 `@EnvironmentObject private var model: AppModel`을 받도록 하고, `.image(let id)` 블록을 `model.attachmentBinary(for:)`/`model.hasLocalBinary(for:)`로 렌더링한다(바이너리 없으면 자리표시자, 다운로드 전/삭제됨을 구분하는 문구 포함).
- [x] 6.4 `Tests/PilgrimJournalTests/MarkdownSupportTests.swift`에 `MarkdownDocumentParser`가 `![](attachment:<uuid>)` 줄을 `.image` 블록으로 인식하는지, 문단에 섞인 경우(독립된 줄이 아님) 리터럴 텍스트로 남는지 테스트를 추가했다.

## 7. 문서와 검증

- [x] 7.1 `docs/implementation-todo.md`의 세 항목을 `## 완료`로 옮겼다.
- [x] 7.2 `docs/known-issues.md`에 이미지 붙여넣기가 `replaceExternalText`/`publishedHistory` 경로를 재사용했다는 점을 기록했다.
- [x] 7.3 `docs/user-guide.md`에 이미지 붙여넣기 사용법과 `.uploading`/다운로드 타임아웃 문구를 추가했다.
- [x] 7.4 `docs/device-verification.md`(세션 C-5 신규)와 `docs/pre-release-checklist.md`(미룬 항목에 추가, 기존 "참고만 해둘 관찰"·"백로그" 항목은 해소로 갱신)에 실기기 검증 게이트를 추가했다.
- [ ] 7.5 다운로드 타임아웃 값과 붙여넣기 UX 카피(design.md Open Questions)를 실기기 검증 결과에 따라 확정하고 문서에 반영한다. — 실기기 접근이 없어 이번 세션에서는 미룸, `docs/pre-release-checklist.md`의 미룬 항목으로 추적.
- [x] 7.6 `./scripts/check.sh`를 실행해 통과를 확인했다(빌드 + `swift test` 167건 + JournalChecks + 개인정보 스캔, 전부 통과).
