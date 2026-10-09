## Why

휴지통 이동(`moveToTrash`)은 `deletedAt` tombstone만 세울 뿐, 기록을 완전히 지우는
경로가 앱 어디에도 없다. 두 가지 실제 문제로 이어진다: (1) 첨부를 포함한 기록이
로컬과 iCloud에 영구히 남아 저장 공간을 회수할 수 없다. (2) `AppModel.analyzeDayOne`이
`includeDeleted: true`로 중복 판정을 하기 때문에, 한 번 가져온 뒤 휴지통으로 옮긴
Day One 기록은 같은 `sourceUUID`로 다시는 가져올 수 없다 — 사실상의 버그다.

## What Changes

- 휴지통 화면에서 기록을 하나씩 영구 삭제할 수 있다.
- 휴지통 화면 툴바에서 휴지통 전체를 한 번에 비울 수 있다.
- 영구 삭제는 기록, 수정 이력, 첨부 행을 함께 제거하고, 다른 기록이 더 이상
  참조하지 않는 첨부 파일만 로컬 저장소에서 지운다(checksum 기반 dedupe라 공유
  파일은 보존).
- 영구 삭제된 Day One 가져오기 기록은 같은 `sourceUUID`로 재가져오기가 가능해진다.
  휴지통에만 있고 영구 삭제되지 않은 기록은 계속 중복으로 취급한다(변경 없음).
- 실행 전 되돌릴 수 없음과 영향 범위(다른 기기·미동기화 편집·이전 백업 복원 시
  되살아날 수 있음)를 알리는 확인 대화상자를 표시한다.
- 자동 보존 기간에 따른 영구 삭제는 넣지 않는다 — 수동 확인 동작만 추가한다.
- 앱 내 사용법(`앱 사용법` → 휴지통 항목)과 `docs/user-guide.md`를 갱신한다.

새 SwiftData 모델이나 canonical 모델의 새 속성은 추가하지 않는다 — CloudKit
자동 스키마 재배포가 필요 없도록 하기 위한 의도적 제약이다.

## Capabilities

### New Capabilities
- `trash-permanent-delete`: 휴지통에 있는 기록의 영구 삭제와 전체 비우기, 첨부 파일
  정리, Day One 재가져오기 회복, 되돌릴 수 없음 고지를 정의한다.

### Modified Capabilities
- `in-app-usage-guide`: `핵심 기능의 행동 중심 안내` 요구사항이 다루는 휴지통 관련
  안내에 영구 삭제·비우기 사용법이 추가된다.

## Impact

- `Sources/JournalDomain/JournalRepository.swift`: `JournalRepository.purgeEntries`,
  `AttachmentRepository.attachmentChecksums`, `JournalPurgeSummary` 추가.
- `Sources/JournalData/SwiftDataJournalRepository.swift`,
  `Sources/JournalData/InMemoryJournalRepository.swift`: 위 프로토콜 구현.
- `Sources/JournalData/ImportAudit.swift`, `LocalImportStore.swift`:
  `removeSourceSnapshots(sourceUUIDs:)` 추가.
- `Sources/JournalData/JournalStoreChange.swift`: 삭제 알림 분류 로직 수정
  (canonical 삭제 시 다른 창에 전체 갱신 요청).
- `Sources/PilgrimJournal/AppModel.swift`: `permanentlyDelete`, `emptyTrash`,
  첨부 파일·미리보기 임시 파일 정리, `autosaveOnEditorExit` 보강.
- `Sources/PilgrimJournal/EntryViews.swift`: `TrashView`에 영구 삭제·비우기 UI와
  확인 대화상자 추가.
- `Sources/PilgrimJournal/AppUsageGuideView.swift`, `docs/user-guide.md`,
  `docs/implementation-todo.md`, `docs/device-verification.md`,
  `docs/pre-release-checklist.md` 갱신.
- 외부 API나 CloudKit 스키마 변경 없음. 기존 `moveToTrash`/`restoreFromTrash` 동작은
  변경하지 않는다.
