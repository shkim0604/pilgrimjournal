## Why

`docs/implementation-todo.md`에 이미 기록된 채 미뤄져 있던 세 가지 첨부 관련 항목을 하나의 변경으로 묶는다. 셋 다 같은 밑단(`AttachmentRepository`/`AttachmentFileStore`, CloudKit 동기화 이벤트, `AppModel`의 첨부 상태 관리)을 건드리므로 따로 처리하기보다 함께 설계하는 편이 낫다.

1. **"다운로드" 버튼이 실제로 fetch를 트리거하지 않음** — `AppModel.requestAttachmentDownload`는 로컬 `state`만 `.downloading`으로 바꿀 뿐 CloudKit에 asset을 요청하는 코드가 없다. CloudKit의 자체 백그라운드 동기화가 결국 전달해주길 기다리는 구조라, 그게 안 오면 스피너가 무한정 돈다.
2. **첨부 업로드 진행률 표시 없음** — `AttachmentTransferState`에 "시작 전"과 "전송 중"을 구분하는 상태가 없어서, 큰 파일을 올릴 때 화면이 "iCloud 업로드 대기" 하나로만 뭉뚱그려 보이고 멈춘 것처럼 보인다.
3. **본문에 이미지 붙여넣기 지원 없음** — 클립보드 이미지를 마크다운 본문에 바로 붙여넣으면 지금은 조용히 사라진다(iOS `UITextView`는 순수 텍스트만 다루고, macOS `NSTextView`는 `isRichText = true`라 화면엔 잠깐 보여도 `textView.string`으로 다시 읽을 때 사라짐).

## What Changes

- CloudKit에 특정 레코드의 asset을 강제로 fetch하는 공개 API가 없다는 플랫폼 제약을 받아들이고(아래 design.md의 Non-Goals 참고), 대신 다운로드 버튼을 "무한 스피너"에서 "타임아웃 후 재시도"로 바꾼다. CloudKit import가 실제로 진행 중인 동안에는 타임아웃을 미루고 "동기화 진행 중"으로 표시한다.
- `AttachmentTransferState`에 `.uploading` 케이스를 추가한다. `NSPersistentCloudKitContainer.eventChangedNotification`이 이미 보내주지만 지금은 버려지고 있는 "작업 시작" 신호(`completedAt == nil`)를 이용해 "대기 중"과 "전송 중"을 구분한다. 바이트 단위 진행률은 API 한계로 제공하지 않는다(스토어 단위 근사치).
- 클립보드 이미지를 붙여넣으면 "첨부 추가"가 쓰는 `AttachmentFileStore`/`AttachmentRepository` 경로로 저장하고, 본문에 `![](attachment:<id>)` 마크다운 구문을 삽입한다. 1차 범위는 라이브 에디터에는 원시 텍스트로 보이고, 보기 모드(`MarkdownPreviewView`)에서 실제 이미지로 렌더링되는 것까지다 — 라이브 에디터 내 WYSIWYG 인라인 이미지는 범위에서 제외한다(이유는 design.md Non-Goals 참고).
- 위 세 가지 모두 새 canonical 모델이나 canonical 모델의 새 속성을 추가하지 않는다 — CloudKit 스키마 재배포가 필요 없다.

## Capabilities

### Modified Capabilities

- `local-data-portability`: 첨부 업로드/다운로드 상태 표현과 UX(타임아웃·재시도, 전송 중 구분)가 추가된다.
- `journal-entry-management`: 본문에 클립보드 이미지를 첨부로 삽입하고 보기 모드에서 렌더링하는 동작이 추가된다.

### New Capabilities

없음 — 기존 두 capability의 확장으로 충분하다.

## Impact

- `Sources/JournalDomain/JournalRecords.swift`: `AttachmentTransferState`에 `.uploading` 추가.
- `Sources/PilgrimJournal/AppModel.swift`: `handleCloudSyncStoreEvent` 재구성, `isCloudImportInProgress` 플래그 추가, `addAttachment(data:originalName:mimeType:to:)` 신설(기존 `addAttachment(from:to:)`가 위임).
- `Sources/PilgrimJournal/EntryViews.swift`: `attachmentStatus`/`attachmentAction`에 `.uploading` 반영, `.downloading` 전용 타임아웃+재시도 서브뷰(`AttachmentDownloadStatusView`) 추가, `MarkdownBodyEditor` 호출부 두 곳(`InlineEntryEditorView`, `EntryEditorView`)에 `entryID`/`ensureEntryID`/`storeImageAttachment` 배선.
- `Sources/PilgrimJournal/MarkdownSupport.swift`: `MarkdownCommandProcessor.insertingAttachmentImage` 신설, macOS/iOS `Coordinator.handleImagePaste` 신설, `MarkdownNSTextView`/`MarkdownUITextView`에 `paste(_:)` 오버라이드 추가, `MarkdownBlockKind.image(UUID)` + `MarkdownDocumentParser` 파서 분기 + `MarkdownPreviewView` 렌더링 추가.
- `docs/implementation-todo.md`: 세 항목을 구현 완료 후 `## 완료`로 이동.
- `docs/known-issues.md`: 이미지 붙여넣기가 재사용한 안전 삽입 경로(`replaceExternalText`)를 짧게 언급해 향후 우회 경로 재발을 방지.
- `docs/device-verification.md`, `docs/pre-release-checklist.md`: 이미지 붙여넣기 실기기 검증 게이트 추가(iOS 소프트 키보드 포함, 기존 편집기 입력 릴리스 게이트와 동일한 수준).
- 외부 API나 CloudKit 스키마 변경 없음. `AttachmentEntity.stateRaw`는 이미 존재하는 `String` 컬럼에 새 raw value("uploading")만 추가되는 것이라 새 필드나 새 모델이 필요 없다.
