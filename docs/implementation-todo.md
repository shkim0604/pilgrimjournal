# 구현 TODO (미룬 기능·개선)

출시 게이트가 아닌, "나중에 만들 것"을 모아둔 문서. 실기기 검증 항목은
`docs/pre-release-checklist.md`를 본다.

## 대기 중

- **유료 코드 잠금의 출시 위험** (2026-10-15 도입) — 유형 편집(추가·이름
  변경·삭제·순서)은 모든 빌드에서 기본으로 잠기고, 설정 › 유료 기능이나 잠금
  안내 화면에서 코드를 넣은 기기만 열린다(`PremiumCodeFeatureAccess`, 기기별
  `UserDefaults`, 동기화·재설치 후 유지 안 됨). 저장소가 공개라 코드는 소스에
  없고 솔트+PBKDF2 키만 있다(`PremiumCode.production`; 바꾸는 법은 그 주석).
  - App Store 심사 지침 3.1.1은 인앱 결제 아닌 코드로 기능을 여는 것을 금지한다.
    심사에서 거절될 수 있다.
  - 이 빌드로 업데이트하면 기존 사용자도 유형 편집이 잠긴다.

- **영문 현지화 다듬기** — 영어 번역(2026-10-15)에서 남긴 것:
  - 한 키를 두 곳에서 써서 영어가 어색한 곳: "제목"(제목 칸 = Title, iPhone
    도구줄의 제목 = Heading이어야 함), "유형"(사이드바 Types / 시트 Type),
    "노트북"(사이드바 머리 Notebooks). 쓰는 곳마다 다른 키로 나눠야 한다.
  - 숫자가 둘 이상인 문장("%lld개 반영 · %lld개 휴지통 · 충돌 %lld개" 등)은
    단수형이 없어 "1 conflicts"가 나올 수 있다.
  - 기록 유형을 바꿀 때 본문에 덧붙는 줄(`EntryDetails.carryOverLines`)과
    가져오기 감사 기록 일부는 저장되는 데이터라 한국어로 남겼다.
  - 실기기·Mac에서 전 화면 영어 확인은 아직. App Store 영문 설명·스크린샷도 없다.
  - 앱 안에 언어 선택은 없다 — iOS 설정 › Pilgrim Journal › 언어, macOS 시스템
    설정 › 일반 › 언어 및 지역 › 앱에서 고른다.

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

- **macOS 첨부 칸 사진을 본문 커서 자리에 넣기** (사용자 판단으로 보류, 2026-10-15)
  macOS는 붙여넣은 이미지만 본문에 들어가고, 첨부 칸의 파일·사진 버튼은 목록에만
  올린다. 이동은 이미 된다 — 이미지 줄을 선택해 끌어 옮기기(`NSTextView` 기본 텍스트
  드래그)와 ▲▼(2026-10-15, 아래 완료 항목). 필요해지면 iPhone처럼
  `attachmentInsertionSelection` + `MarkdownImageInserter`를 macOS coordinator에
  연결하면 된다.
- **사용자 유형 관리 — 2단계: 결제와 잠금**
  StoreKit 결제·구매 복원을 붙이고 `FeatureAccess` 기본값을 잠김으로 바꾼다.
  지금은 모든 빌드에서 열려 있다.
- **유형 편집 시트의 작은 UX 빈틈**
  - 시트의 오류 메시지가 목록 맨 위에 있어 스크롤하면 보이지 않는다.
  - macOS에는 눈에 보이는 삭제 버튼이 없다(컨텍스트 메뉴·Delete 키만).
  - "이름 없는 유형"을 삭제하면 그 자리표시 이름이 삭제 기록에 남는다(편집은
    이름 칸을 비운 채 열도록 고쳤다). 삭제된 유형이라 화면에는 영향이 없다.
- **사용자 유형 동기화의 남은 한계 (최종 리뷰에서 미룸)**
  - 다른 기기가 삭제한 유형을 오프라인 기기가 편집(이름·순서 변경)하면, 그
    편집이 더 늦은 시각이라 삭제를 이기고 유형이 되살아난다. 기록은 이미
    옮겨졌으므로 빈 유형이 하나 생길 뿐 데이터 손실은 없다.
  - 두 기기가 동시에 서로 다른 유형을 삭제하면 병합 결과에 새로 쓸 수 있는
    유형(`creatableKinds`)이 하나도 남지 않을 수 있다.
  - 이 빌드는 디코딩할 수 없는 iCloud 카탈로그를 만나면 다음 편집 때 로컬
    카탈로그로 덮어쓴다. 그 값이 더 새 빌드가 쓴 것이라면 그 빌드의 편집이
    사라진다.
  - 유형을 한 번이라도 삭제하면 이후 CloudKit 가져오기가 끝날 때마다 정리
    작업이 저장소 전체를 훑는다. 기록이 많아지면 비용을 재야 한다.
  - Day One 가져오기 뒤에는 정리 작업을 돌리지 않는다. 가져온 기록이 삭제된
    유형으로 분류되면(예: 아직 정리되지 않은 다른 기기의 규칙) 다음 정리 시점까지
    그 유형에 남는다.

## 완료

- **macOS 본문 이미지 ▲▼ 이동** (2026-10-15) — iPhone과 같은 버튼과 규칙
  (`movingAttachmentImage`, `moveButtonRects`). 커서가 이미지 줄에 있으면 우측 상단에
  ▲▼가 그려지고, 클릭은 `mouseDown`이 `super`보다 먼저 받는다(그래야 커서가 이미지
  밖으로 나가 버튼이 사라지지 않는다). iPhone과 달리 `NSTextView`는 글자와 장식을 한
  뷰에서 그리고 글자가 바뀌면 스스로 다시 그려서, 별도 `needsDisplay`는 필요 없었다
  (`MacImageMoveTests`).
- **화면 모드 설정** (2026-10-15) — 설정 › 화면에서 시스템 설정·라이트·다크를
  고른다. 기기별(`@AppStorage`, 동기화 안 함)이고, SwiftUI `preferredColorScheme`
  대신 창 단위로 적용한다(iOS `overrideUserInterfaceStyle`, macOS
  `NSApp.appearance`) — 그래야 "시스템 설정"으로 돌아올 때 확실히 풀리고
  AppKit/UIKit 편집기 색도 따라간다. iOS 시뮬레이터에서 즉시 전환·재실행 유지·
  시스템 추종 확인. Mac 화면 확인과 실기기 확인은 아직.
- **iPhone 본문 사진 위치 지정과 ▲▼ 이동** (2026-10-15) — 사진·촬영·파일(이미지)
  버튼, 키보드 도구줄 📷, 꾹 눌러 뜨는 메뉴의 사진 삽입으로 넣은 사진이 첨부
  목록뿐 아니라 본문의 마지막 커서 자리(커서가 없었으면 끝)에 한 줄로 들어간다.
  커서가 이미지 줄에 있으면 우측 상단 ▲▼로 위·아래 문단과 자리를 바꾼다.
  도구줄 칸이 6개로 꽉 차 있어 "키보드 닫기"를 빼고 📷을 넣었다(본문을 아래로
  쓸어내리면 키보드가 닫힌다). 집중 모드에서도 첨부 칸은 목록만 숨긴 채 남아
  사진 선택 화면을 띄운다. `docs/known-issues.md` 참고.
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
