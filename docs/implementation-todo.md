# 구현 TODO (미룬 기능·개선)

출시 게이트가 아닌, "나중에 만들 것"을 모아둔 문서. 실기기 검증 항목은
`docs/pre-release-checklist.md`를 본다.

## 대기 중

- **지난 백업 목록 화면**
  지금은 백업을 파일 하나(`.journalbackup`)로 내보내기만 하고, 앱은 그
  기록을 전혀 안 남긴다(`AppModel.lastBackupExportMessage`는 가장 최근 것
  하나만 잠깐 담는 휘발성 문자열, 영속 저장 없음 — `AppModel.swift:79,1072`
  `prepareBackup()`). 복원할 때도 그냥 Finder 파일 선택 창만 뜬다.
  설정 → 백업 및 복원에 **최근 3개를 보여주고, "전체 보기" 버튼으로 나머지도
  볼 수 있는 목록 화면**을 추가한다. 구현하려면:
  - 내보내기 성공 시마다 메타데이터(파일명, 저장 시각, 항목 수, 저장 위치
    URL)를 기록하는 작은 로그가 필요하다 — CloudKit에 안 실리는 device-only
    저장소(`LocalAuxiliary` store, 검색 인덱스 상태와 같은 위치)에 두는 게
    맞아 보인다.
  - `.fileExporter`가 사용자가 고른 임의의 위치에 저장하므로, 그 URL이
    나중에 이동/삭제됐을 수 있다는 점을 감안해 "파일을 찾을 수 없음" 처리가
    필요하다.

## 완료

- **iPhone 편집기 집중 모드** — 키보드 도구막대의 버튼으로 켜고 끈다. 켜면
  상단 바·메타데이터 칩·유형별 칸·태그·첨부·글자 수·Markdown 메뉴 줄이 사라지고
  제목과 본문만 남는다. 키보드를 내린 상태에서는 오른쪽 위 작은 버튼으로
  나오고, 저장에 실패하면 그 옆에 저장 오류와 "다시 저장"이 뜬다. 편집기를 열
  때마다 평소 화면으로 시작한다(저장하지 않는 `@State`). 무엇을 보일지는
  `EntryEditorFocusLayout`이 정하고 `EntryEditorFocusLayoutTests`가 검증한다.
  Mac의 집중 모드(`FocusModeLayoutPolicy`)는 그대로다. 실기기 확인은
  `docs/pre-release-checklist.md`에 남아 있다. (2026-10-15)
  - 같이 고친 것: 키보드 도구막대가 **본문에서는 한 번도 뜬 적이 없었다.**
    SwiftUI `.toolbar(placement: .keyboard)`는 SwiftUI 입력칸에만 붙고 본문의
    UIKit 텍스트 뷰에는 붙지 않는다. 이제 같은 항목(`MarkdownKeyboardAccessory`)을
    본문 텍스트 뷰의 `UIToolbar`로도 보여 준다. 390pt 폭에서 넘치지 않도록
    "오늘" 버튼을 빼고(`/today` 명령으로 대신) "키보드 닫기"를 아이콘으로 바꿨다.
- **첨부 다운로드 fetch 미트리거 / 업로드 진행률 세분화 / 이미지 붙여넣기**
  — openspec `improve-attachment-transfer-and-paste`. CloudKit이 특정
  레코드의 asset을 강제로 fetch하게 만드는 공개 API는 없다는 제약을 그대로
  받아들이고, 다운로드 버튼은 타임아웃(잠정 25초) 후 재시도 UI로 바꿈 — CloudKit
  import가 실제로 진행 중이면(`AppModel.isCloudImportInProgress`) 타임아웃을
  미룸. `AttachmentTransferState`에 `.uploading`을 추가하고,
  `NSPersistentCloudKitContainer.eventChangedNotification`이 이미 보내지만
  버려지고 있던 "작업 시작" 신호(`completedAt == nil`)를 살려 "대기 중"과
  "전송 중"을 구분함(`AppModel.handleCloudSyncStoreEvent`). 클립보드 이미지
  붙여넣기는 "첨부 추가"와 같은 `AttachmentFileStore`/`AttachmentRepository`
  경로로 저장하고 본문에 `![](attachment:id)` 마크다운을 삽입함(macOS/iOS
  `paste(_:)` 오버라이드 → 기존에 안전하다고 검증된
  `Coordinator.replaceExternalText` 경로로 삽입) — 라이브 에디터에서는 원시
  텍스트로 보이고, 보기 모드(`MarkdownPreviewView`)에서 실제 이미지로
  렌더링됨. (2026-08-12)

- **라이브 에디터 내 인라인 리사이즈 가능한 이미지** — 위 항목에서 범위
  제외했던 것을 사용자 요청으로 이어서 구현함. 문자 치환 없이
  `LiveMarkdownStyler`의 "저장되는 마크다운 문자를 절대 바꾸지 않는다"
  불변조건을 지키면서, 이미지 마커 줄에 `NSParagraphStyle.minimumLineHeight`
  /`maximumLineHeight`로 높이를 예약하고(기존 `separatorParagraphStyle`
  패턴 재사용) `draw(_:)`가 그 자리에 디코드된 이미지를 직접 합성하는
  방식으로 해결함. 크기는 `![](attachment:id =WxH)`로 텍스트 자체에
  인코딩(별도 메타데이터 저장소 없음). 커서가 이미지 줄에 있을 때만 보이는
  리사이즈 핸들을 드래그하면 가로세로 비율 고정으로 크기가 바뀌고, 놓는
  순간 한 번만 `Coordinator.replaceExternalText`로 `=WxH`를 확정함(드래그
  중에는 attribute만 바꿔 `textDidChange` 재진입 위험 없음). macOS는
  `mouseDown`/`mouseDragged`/`mouseUp` 오버라이드, iOS는 `UITextView`의
  내장 제스처와 충돌하지 않도록 `UIPanGestureRecognizer` +
  `UIGestureRecognizerDelegate` 히트테스트로 구현. 이미지 데이터는
  `draw(_:)`에서 동기 호출하지 않고, 첨부 전체를 스캔하던 기존
  `allAttachments()` 대신 새로 추가한 단일 조회
  `AttachmentRepository.attachment(id:)`로 Coordinator가 캐시하며 비동기
  로드함. `dirtyRect` 교차 검사로 화면 밖 이미지는 합성하지 않아 편집기
  입력 씹힘 회귀와 같은 `draw(_:)` 경로의 비용 증가를 최소화함 —
  실기기 검증은 `docs/pre-release-checklist.md`로 미룸 (2026-08-12)

- **`entry(sourceUUID:)`의 fetchLimit 500이 대량 가져오기에서 중복 판정을
  놓칠 수 있던 버그** — `SwiftDataJournalRepository.entry(sourceUUID:)`가
  `fetchLimit = 500`을 건 채 정렬 없이 조회해, 가져온 기록이 500개를 넘으면
  500번째 이후 기록은 재가져오기 중복 판정(`DayOneImportExecutor`)·`save()`의
  중복 방지 가드·기기 간 병합 매칭(`JournalSessionController`)에서 전부
  누락될 수 있었다. `purgeEntries`에서 이미 쓰던 "정확성이 걸린 곳엔 임의
  cap을 두지 않는다" 관례를 따라 fetchLimit을 제거함. 휴지통 영구 삭제 작업
  (openspec `add-trash-permanent-delete`) 중 발견, 이번 세션에서 수정
  (2026-08-12)

- **첨부 미리보기(QuickLook/기본 앱 열기)** — iOS는 `.quickLookPreview`,
  macOS는 `NSWorkspace.shared.open`으로 구현함 (2026-08-12)
- **첨부를 다른 위치에 저장** — `AttachmentDocument` + `.fileExporter`로
  구현함 (2026-08-12)
- **편집기 열린 상태에서 수정 이력 복원 시 draft 갱신 안 되던 버그** —
  `RevisionHistoryView`에 `onRestore` 콜백 추가해 수정함 (2026-08-12)
- **휴지통 완전 비우기 기능이 없음** — 휴지통 화면에서 개별 영구 삭제와
  전체 비우기를 추가함. 기록·수정 이력·첨부 행을 함께 지우고, 다른 기록이
  더 이상 참조하지 않는 첨부 파일만 회수함(checksum 기반 dedupe라 공유
  파일은 보존). Day One 재가져오기 영구 차단 버그도 함께 해소 — 영구
  삭제된 기록은 같은 sourceUUID로 다시 가져올 수 있고, 휴지통에만 있는
  기록은 계속 중복으로 차단됨. 새 canonical 모델이나 속성을 추가하지
  않아 CloudKit 스키마 재배포가 필요 없음. openspec
  `add-trash-permanent-delete` (2026-08-12)
