# 알려진 문제와 재발 방지

반복해서 되살아난 문제의 **지켜야 할 규칙만** 적는다. CloudKit 스키마나 마크다운
편집기를 건드리기 전에 읽을 것. 증상·원인 추적·검증 과정 같은 이력은
[archive/known-issues-history.md](archive/known-issues-history.md)에 원문 그대로 있다.

## CloudKit 스키마 드리프트

**규칙**

- `PilgrimJournalSchemaV1.canonicalModels`(`Sources/JournalData/JournalSchema.swift`)에
  모델이나 속성(특히 optional)을 추가하면 릴리스 전에 Debug 빌드를
  `PILGRIM_DEPLOY_CLOUDKIT_SCHEMA=1`로 직접 실행하고(`CloudKitSchemaInitializer`, 명령은
  [development.md](development.md) "CloudKit 운영 도구") CloudKit Console → **Development** →
  `Deploy Schema Changes...`로 배포한다. 릴리스 전 Deploy 창이 **변경 0건**이어야 한다.
- 손으로 레코드를 만들어 스키마를 유도하지 말 것 — 모든 optional 필드를 채울 수 없다.
- Debug 빌드여야 한다(Production은 `initializeCloudKitSchema()`를 거부). Apple 로그인은 필요
  없다. 로그의 `SQLite disk I/O error` 몇 줄은 임시 저장소 정리 소음이다 — throw 하지 않았으면
  성공이고, 판단 기준은 Deploy 창의 변경 목록이다.
- Production 스키마 변경은 되돌릴 수 없다(additive-only, 모든 필드가 queryable·sortable 인덱스).

**이유** CloudKit 자동 스키마 생성은 SwiftData 모델을 보지 않고, Development에서 실제로
값이 채워져 export 된 필드만 만든다. TestFlight(Production)는 빠진 타입·필드를 쓰는 레코드를
거부한다. 타입 누락만 `cloudSyncErrorPresentation`이 "CloudKit 프로덕션 스키마가 아직 배포되지
않았습니다"로 드러낸다 — 기존 타입의 필드 누락이 UI에 보인다고 기대하지 말 것.

**지키는 테스트** 없음(수동 절차).
`AppModelNavigationTests.testCloudSyncErrorRevealsMissingProductionSchema`는 타입 누락 표시만 본다.
이력: [CloudKit 스키마가 모델보다 부족하다](archive/known-issues-history.md#cloudkit-스키마가-모델보다-부족하다)

## 편집기 입력이 씹힌다 — binding 메아리

**규칙**

- 에디터에 프로그래밍적으로 텍스트를 쓰는 모든 기능(서식 도구, slash command, 붙여넣기,
  사진 삽입·이동, 재로드)은 `Coordinator.replaceExternalText`를 지나고, SwiftUI binding 쓰기는
  전부 `publish(_:)`를 지나 `publishedHistory`에 기록된다. `textView.insertText`나
  `NSTextStorage`를 직접 고치는 우회 경로를 새로 만들지 말 것.
- `LiveMarkdownTextEditor`의 `updateUIView`/`updateNSView`는 `textView.text != text`로 외부
  변경을 판단하지 않는다. `MarkdownInputReconciliation.shouldApplyExternalText(incoming:current:publishedHistory:)`가
  이력에 있는 값(자기 메아리)은 무시하고 발행한 적 없는 값만 적용한다. iOS·macOS 같다.
- IME 조합 중(`markedTextRange != nil`)에는 텍스트 저장소를 바꾸지 않는다
  (`canMutateTextStorage`). 조합 중에 온 외부 변경(`editorReloadRequest` 재로드 등)은
  `deferredExternalText`로 들고 있다가 조합이 끝나면 `ExternalTextRebase`로 조합 글자를 얹어
  `replaceExternalText`로 적용한다.
- `LiveMarkdownStyler.apply`는 속성만 바꾸고 문자는 바꾸지 않는다(그래서 `textDidChange`/
  `textViewDidChange` 재진입이 없다). 이 전제를 깨지 말 것.
- 본문 텍스트 뷰(`MarkdownBodyEditor`/`LiveMarkdownTextEditor`)를 `if`·`Group` 분기나 `.id()`로
  감싸지 말 것. 집중 모드(`EntryEditorFocusLayout`)·기도제목(`PrayerTopicChecklistEditor`)처럼
  주변 뷰만 넣고 뺀다. 다시 만들어지면 입력 중인 글자와 캐럿을 잃는다.

**이유** `updateUIView`가 받는 binding은 렌더 시점 값이라 타이핑보다 뒤처질 수 있고, 그걸
외부 변경으로 보고 되쓰면 그 사이 친 글자가 사라진다(한글·영어 공통, 본문만). 남은 위험: 외부
값이 우연히 과거 발행 값과 같으면 무시된다(undo·redo는 `undoManager` 경로라 해당 없음).

**지키는 테스트** `MarkdownSupportTests`의 `testStaleBindingEchoDoesNotOverwriteNewerTyping`,
`testExternalTextChangeIsStillApplied`, `testPublishedHistoryIsBoundedAndKeepsTheNewestValues`,
`testIMECompositionDefersTextStorageMutation`; `ExternalTextRebaseTests`;
`EntryEditorFocusLayoutTests`. 실제 키보드 타이밍은 덮지 못한다 → 아래 릴리스 게이트.
이력: [편집기 입력이 씹힌다](archive/known-issues-history.md#편집기-입력이-씹힌다-수정-적용-실기기-확인-대기)

## 편집기를 연 직후 첫 입력이 지워진다 — 여는 시점 본문

**규칙**

- iOS `makeUIView`는 여는 시점 본문을 `Coordinator.adoptInitialText`로 `publishedHistory`에
  넣는다. 빼지 말 것.
- macOS에는 이 시딩을 넣지 않는다. 대신 `isOpeningTextEcho`(`openingText`)가 SwiftUI가 새
  값을 넘기기 전까지만 여는 시점 값을 메아리로 본다 — 리비전 복원(macOS 전용)을 삼키지 않게.
- hosted 테스트는 본문 편집기 단독이 아니라 실제 `EntryEditorView`를 띄운다. 단순한 호스트
  뷰로는 늦은 메아리가 재현되지 않는다.

**이유** iOS 편집 화면은 키 입력마다 `updateUIView`를 여러 번 부르고 첫 호출의 `text`는 키 입력
이전 값이다. 발행된 적 없는 여는 시점 본문이 외부 변경으로 판정돼 첫 글자가 사라지거나 순서가
섞였다(시뮬레이터 전용 아님 — `insertText`로 재현된다).

**지키는 테스트** `LiveMarkdownTextEditorIOSTests`(`testFirstKeystrokeAfterOpeningIsKept`,
`testTypingInBurstsWithPausesKeepsEveryCharacterInOrder`; `#if os(iOS)`라 CI `ios-tests` 잡이 돌린다,
로컬 명령은 `CLAUDE.md`), macOS는 `MarkdownSupportTests.testOpeningTextEchoAfterFirstEditStillAllowsALaterRevisionRestore`.
이력: [iPhone 편집기를 연 직후 첫 입력이 지워짐](archive/known-issues-history.md#2026-10-15--iphone-편집기를-연-직후-첫-입력이-지워짐-수정-실기기-확인-대기)

## 에디터 입력 릴리스 게이트

**TestFlight 빌드마다 올리기 전에 통과할 것.** 실기기 타이핑 체크리스트의 유일한 정본이다
(다른 문서는 여기를 링크). 자동화 테스트는 실제 키보드 입력 타이밍을 덮지 못한다.

- [ ] **본문**(제목 아님)을 30초 이상 한글·영어 섞어 빠르게 입력한다. 한 글자도 씹히지 않아야 한다.
- [ ] **Release 구성**으로 확인한다. DEBUG 최적화 차이로 증상이 가려질 수 있다.
- [ ] **iPhone 실기기 소프트 키보드**로 확인한다. Mac 하드웨어 키보드·시뮬레이터로는 부족하다.
- [ ] 도구모음 서식·slash command를 쓴 뒤 이어서 타이핑한다(외부 변경과 입력이 겹치는 구간).
- [ ] 입력 도중 키보드 도구막대로 집중 모드를 켜고 끈 뒤 이어서 타이핑한다(글자·캐럿 유지).
- [ ] 편집기를 막 연 직후 첫 입력 — 기존 기록과 새 기록 각각, 본문 끝을 탭하고 **영어 한
      글자**를 친 뒤 1초 기다린다. 글자가 남고 캐럿이 그 뒤에 있어야 한다. 30초 연속 입력으로는
      이 경우가 가려진다.
- [ ] 이미지가 1장 이상 든 본문에서 30초 입력을 다시 한다(`draw(_:)` 이미지 합성이 같은 경로를
      탄다). 이미지 3장 이상인 긴 문서에서 스크롤하며 입력해 체감 랙이 없는지 본다.

관련: [device-verification.md](device-verification.md)의 세션 D-2.
이력: [릴리스 게이트](archive/known-issues-history.md#릴리스-게이트-이게-재발을-막는-핵심)

## 한영 전환 지연은 우리 문제가 아니다

"한영 전환이 느리다"는 관찰이 나오면 먼저 제목 칸(순수 SwiftUI `TextField`)과 비교한다.
제목도 같으면 시스템 입력기(와 화면공유) 지연이라 앱 코드로 고칠 대상이 아니다.

## 장식은 `.attachment`가 아니라 `draw(_:)`로 그린다

**규칙**

- 저장되는 마크다운 문자 위에 `NSAttributedString.Key.attachment`를 얹어 무언가를 보이게 하지
  말 것. 불릿·체크박스·이미지는 `MarkdownBulletDecoration`/`MarkdownChecklistDecoration`/
  `MarkdownAttachmentImageDecoration`이 위치를 찾고 텍스트 뷰의 `draw(_:)`가 직접 그린다.
  `draw(_:)`의 루프는 모두 dirty-rect 컬링을 한다.
- 그림만 바뀌는 편집(이미지 두 줄 맞바꾸기 등)도 다시 그려져야 하므로 `replaceExternalText`가
  `setNeedsDisplay()`를 부른다. 지우지 말 것.
- 이미지 크기의 출처인 마커의 `=WxH`, `LiveMarkdownStyler.attachmentImageParagraphStyle`,
  `draw(_:)`가 어긋나면 안 된다. 리사이즈 드래그 중에만 `attachmentResizePreview`가 우선한다.

**이유** `NSTextAttachment`는 U+FFFC 자리에서만 렌더되는데, 이 에디터는 저장 문자를 바꾸지 않고
마커를 색·크기로만 숨긴다. 그래서 `.attachment` 체크리스트는 한 번도 렌더된 적이 없었다.

**지키는 테스트** `MarkdownSupportTests.testChecklistMarkerAndBracketsAreHiddenNotAttachmentBased`,
`testChecklistDecorationLocatesMarkerAndCheckedState`;
`BodyImagePlacementIOSTests.testMovingAnImageRedrawsThePictures`.
이력: [체크리스트가 렌더링된 적이 없었음](archive/known-issues-history.md#2026-08-12--체크리스트가-실제로는-한-번도-렌더링된-적이-없었음-별도-발견-macos-실측-후-수정),
[리사이즈 중 옛 크기](archive/known-issues-history.md#2026-08-15--이미지-리사이즈-중-그림이-옛-크기로-남아-있음)

## 첨부 hot path — `allAttachments()`·`.binary` 금지

**규칙**

- 렌더 경로, SwiftUI view body, 루프 안에서 `AttachmentRepository.allAttachments()`를 부르거나
  `AttachmentEntity.binary`를 건드리지 말 것. 범위를 좁힌 조회를 쓴다: `attachments(forEntry:)`,
  `attachments(inStates:)`, `attachmentChecksum(id:)`, `attachmentChecksums()`(가져오기 루프
  진입 전에 한 번).
- 전송 상태 전이는 `updateAttachmentState(id:state:updatedAt:)`로. 상태 하나 바꾸자고 blob을
  다시 쓰지 말 것(같은 CKAsset을 재업로드한다).
- 로컬 바이너리 유무(`hasLocalBinary`)는 `AttachmentFileStore`의 CAS 파일 존재로 본다. 없을 때만
  DB blob으로 폴백하고 그 자리에서 CAS를 채운다(hydrate).
- 이미지는 `AttachmentImageCache`로 목표 크기에 맞춰 다운샘플 디코드한다(id 키 — 첨부 바이너리는
  생성 뒤 바뀌지 않는다). `draw(_:)`는 Coordinator의 동기 캐시 `cachedAttachmentImage(for:)`만
  부른다. view body에서는 디스크 I/O 대신 `.task(id:)` + `@State`(`AttachmentImageView`).
- 키 입력마다 렌더를 늘리지 말 것: `saveState`는 `if saveState != .saving`일 때만 대입한다.
  `performAutosave` 뒤 전체 `refresh()`는 실기기 프로파일링 전에는 손대지 않는다.

**이유** `.binary`는 `@Attribute(.externalStorage)`라 blob마다 별도 파일이고, `allAttachments()`는
모든 blob을 폴트시킨다. 첨부 행마다 불려 렌더 한 번에 A×T개 blob이 읽혀 편집기가 느려졌다.

**지키는 테스트** `JournalDataTests`의 `testAttachmentsForEntryOnlyReturnsThatEntrysAttachmentsAndNeverBinary`,
`testAttachmentsInStatesFiltersByStateOnly`, `testAttachmentChecksumNeverReadsBinaryButFindsIt`,
`testUpdateAttachmentStatePreservesBinaryAndReturnsFalseForMissingRow`,
`testAttachmentFileStoreHydrateIsIdempotentAndSelfHealing`; `AttachmentImageCacheTests`.
이력: [첨부 있는 기록이 계속 느렸던 진짜 원인](archive/known-issues-history.md#2026-08-14--첨부-있는-기록이-계속-느렸던-진짜-원인-allattachments가-렌더-경로에서-db-전체를-읽고-있었음)

## 이미지 붙여넣기가 회색이면 메뉴 검증을 본다

`importsGraphics = false`라 이미지만 든 클립보드에서는 메뉴가 비활성이고 `paste(_:)`가 아예
불리지 않는다. 핸들러보다 검증을 먼저 의심할 것: macOS `validateUserInterfaceItem(_:)`, iOS
`canPerformAction(_:withSender:)` + `UIPasteboard.general.hasImages`. `readablePasteboardTypes`에
이미지 타입을 넣지 말 것 — `super.paste(_:)`가 `NSTextAttachment`를 꽂아 평문 모델이 깨진다.
이력: [AppKit이 메뉴를 잠근다](archive/known-issues-history.md#2026-08-15--이미지-붙여넣기가-비활성이던-진짜-원인-appkit이-paste_를-부르기도-전에-메뉴를-잠근다)

## 숨긴 마커 뒤 입력과 원자적 이미지 줄

**규칙**

- 입력 속성 보정은 `MarkdownNSTextView`/`MarkdownUITextView`의 `insertText`·`setMarkedText`
  (`restoreTypingAttributesIfHidden`)에서만 한다. `MarkdownInputReconciliation.shouldRestoreTypingAttributes`가
  숨김(0.1pt 미만 또는 알파 0)이라 하면 `LiveMarkdownStyler.typingAttributes(forLinePrefix:)`로 되돌린다.
  캐럿 이동마다 쫓지 말 것 — 경로가 여럿이고 `replaceExternalText` 중엔 델리게이트가 안 불린다.
- 폰트는 객체 비교가 아니라 `pointSize`로 비교한다. 한글이 섞이면 실제 face가 대체돼 매 키
  입력마다 속성을 다시 쓰고 IME 조합을 깬다. 평범한 입력에서는 속성을 건드리지 않는다.
- 블록 마커 완성(`completesBlockMarker`)과 인라인 구분자는 그 키 입력에서 바로 재스타일한다
  (`shouldStyleImmediately`). 나머지는 `EditorTiming.stylingDebounce` 디바운스다.
- 이미지 줄은 원자적이다. `insertText`/`setMarkedText`가 `MarkdownAttachmentImageDecoration.insertionRelocation`으로
  글자를 위/아래 새 줄로 옮긴다(`moveInsertionOffImageLine`). 선택 영역이 있는 입력은 건드리지 않는다.
- **줄 전체**를 숨기는 스타일을 새로 추가하면, AppKit의 `typingAttributes` 상속은 순수 함수로
  재현되지 않으므로 `swiftc` 스크립트로 다시 실측한다(방법은 이력 참고).

**이유** 이미지 줄은 줄 전체를, 제목은 `# `를 투명 + `hiddenMarkerFont`로 숨긴다. 캐럿 앞 문자
속성을 물려받아 새 글자가 투명 0.1pt로 찍히고, 재스타일은 디바운스라 치는 동안 복구되지 않는다.
저장 문자는 정확히 `![](attachment:id …)`여야 하므로 이미지는 인라인 첨부가 아니라 독립 블록이다.

**지키는 테스트** `MarkdownSupportTests`의 `testTypingAttributesAreRestoredWhenInheritedFromAHiddenMarker`,
`testTypingAttributesAreLeftAloneForOrdinaryText`, `testStylerHiddenMarkerAttributesAreDetectedAsNeedingRestore`,
`testHeadingsAreTypedAtTheSizeTheStylerWouldApply`, `testCompletingABlockMarkerStylesOnThatKeystroke`,
`testTypingAtTheEndOfAnImageLineMovesBelowTheImage`, `testTypingAtTheStartOfAnImageLineMovesAboveTheImage`,
`testTypingInsideAnImageMarkerMovesBelowTheImage`, `testTypingOnOrdinaryLinesIsNotRelocated`.
이력: [숨긴 마커 뒤 글자](archive/known-issues-history.md#2026-08-15--숨긴-마커-뒤에서-입력한-글자가-안-보임-이미지-줄-h1-등-제목),
[이미지 줄은 원자적](archive/known-issues-history.md#2026-08-15--이미지-줄은-원자적이어야-한다-글자-하나에-이미지가-사라짐)

## 사진 삽입은 한 경로, 본문 키보드 버튼은 `MarkdownKeyboardAccessory`

**규칙**

- iPhone의 사진·촬영·파일(이미지)·키보드 📷·편집 메뉴 사진 삽입은 모두 첨부 칸 저장 →
  `MarkdownImageInserter` → `Coordinator.insertAttachmentImage` → `insertingAttachmentImage` →
  `replaceExternalText` 한 경로다. 새 진입점도 여기에 붙인다.
- 위치는 `MarkdownCommandProcessor.attachmentInsertionSelection`이 정한다: 본문이 포커스를 받은
  적 없으면 끝, 아니면 마지막 커서. 선택 영역은 대체하지 않고 뒤에 넣고, 다른 이미지 마커
  한가운데면 그 줄 끝으로 옮긴다.
- ▲▼ 이동(`movingAttachmentImage`)의 히트테스트 `attachmentMoveTarget`은 `draw(_:)`와 같은
  조건을 쓴다. 그려지지 않은 버튼이 탭을 가로채면 이미지를 탭해 커서를 두는 동작이 죽는다.
- 본문 키보드 버튼은 SwiftUI `.toolbar(placement: .keyboard)`(본문 `UITextView`에는 안 붙는다)가
  아니라 `MarkdownKeyboardAccessory`에 넣는다. 같은 목록이 `inputAccessoryView`로 그려지고
  `signature`가 바뀔 때만 다시 만든다. 390pt 폭 iPhone에서 아이콘 6개가 한계다(7개는 잘린다).
- 집중 모드에서 첨부 칸은 `if`로 빼지 말고 목록만 숨긴다(`AttachmentEditorSection.showsList`).
  피커·카메라를 띄우는 게 그 칸이라, 빼면 📷과 사진 삽입이 조용히 아무 일도 안 한다.

**지키는 테스트** `BodyImagePlacementIOSTests`(hosted, `EntryEditorView`):
`testPhotoStaysInTheBodyOfTheRealEntryEditor`, `testTypingAfterAnInsertedPhotoKeepsEveryCharacter`,
`testMoveButtonsOnlyAnswerForTheImageUnderTheCaret`, `testBodyKeyboardBarOffersPhotoInsteadOfDismiss` 외;
`MacImageMoveTests`; `MarkdownSupportTests`의 `testImageInsertion…`·`testMovingAnImage…`;
`MarkdownKeyboardAccessoryTests`.
이력: [사진을 본문 커서 자리에](archive/known-issues-history.md#2026-10-15--사진을-본문-커서-자리에-넣고-로-옮긴다-iphone-새-프로그래밍적-진입점),
[본문 키보드 도구막대](archive/known-issues-history.md#2026-10-15--iphone-본문에는-키보드-도구막대가-뜬-적이-없었다)

## `BGSystemTaskSchedulerErrorDomain Code=3` 로그는 잡음

앱은 `BGTaskScheduler`를 쓰지 않는다. 시스템 프레임워크의 소음이니 단서로 삼지 말 것.
