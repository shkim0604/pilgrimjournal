## 1. 도메인 계약

- [x] 1.1 `Sources/JournalDomain/JournalRepository.swift`에 `JournalPurgeSummary`
      (purgedEntryIDs, removedRevisionCount, removedAttachmentIDs, releasedChecksums,
      purgedSourceUUIDs, `.empty`)를 추가한다.
- [x] 1.2 `JournalRepository`에 `purgeEntries(ids: Set<UUID>) throws -> JournalPurgeSummary`를
      추가한다.
- [x] 1.3 `AttachmentRepository`에 `attachmentChecksums() throws -> Set<String>`을
      추가한다.
- [x] 1.4 `Sources/JournalData/ImportAudit.swift`의 `ImportAuditStore`에
      `removeSourceSnapshots(sourceUUIDs: Set<String>) throws`를 추가한다.

## 2. 저장소 구현

- [x] 2.1 `SwiftDataJournalRepository.purgeEntries`: fetchLimit 없이 전량 조회 →
      휴지통 밖 id가 섞여 있으면 삭제 전에 throw(validate-all-then-delete) → 자식
      먼저 삭제(revision → attachment → entry) → `saveIfNeeded()` 실패 시
      `context.rollback()`.
- [x] 2.2 `SwiftDataJournalRepository.attachmentChecksums`: `binary`를 읽지 않는
      bare `FetchDescriptor<AttachmentEntity>()`로 구현한다.
- [x] 2.3 `InMemoryJournalRepository.purgeEntries`/`attachmentChecksums`: entries/
      revisionStorage/attachmentStorage 스냅샷 → 삭제 → `persist()` 실패 시 복원,
      SwiftData와 같은 검증·idempotent 의미론을 갖게 한다.
- [x] 2.4 `LocalImportStore.removeSourceSnapshots`/`InMemoryImportStore.removeSourceSnapshots`:
      해당 sourceUUID의 `SourceSnapshotEntity`(또는 in-memory 대응)만 제거하고
      `ImportItemEntity` 감사 로그는 남긴다.
- [x] 2.5 `Tests/JournalDataTests/JournalDataTests.swift`에 저장소 계층 테스트를
      추가한다: 기록·revision·첨부 동시 삭제, 휴지통 밖 기록 거부(부분 실패 없음),
      공유 checksum은 release하지 않음, 두 번 호출해도 idempotent.

## 3. 변경 전파 수정

- [x] 3.1 `Sources/JournalData/JournalStoreChange.swift`: `deletedIdentifiers`를
      별도로 읽어 `context.model(for:)` 대신 `identifier.entityName`을
      `PilgrimJournalSchemaV1.canonicalModels`에서 만든 이름 집합과 대조하도록
      고친다. canonical 삭제가 하나라도 있으면 `requiresFullRefresh = true`.
- [x] 3.2 `AppModel.handleJournalStoreChange`의 두 분기 모두에
      `if isPresentingTrash { refreshTrash() }`를 추가한다.
- [x] 3.3 삭제 식별자 분류 테스트를 `JournalDataTests`에 추가한다(canonical 삭제 시
      `requiresFullRefresh == true`, 로컬 전용 엔티티 삭제는 `nil` 유지).

## 4. AppModel

- [x] 4.1 `applyPurge(ids:announceCount:)` 공통 경로를 구현한다: repository 호출 →
      searchIndex.remove → selectedEntryID/editingEntry 각각 독립적으로 정리 →
      selectedEntryIDs.subtract → attachmentRevision 증가 → markLocalMutation →
      refreshTrash → refresh.
- [x] 4.2 `permanentlyDelete(_:)`와 `emptyTrash()`를 `applyPurge` 위에 구현한다.
      `emptyTrash()`는 먼저 `refreshTrash()`로 최신 목록을 확보한 뒤 그 id 전체로
      호출한다.
- [x] 4.3 커밋 이후 첨부 정리: `releaseAttachmentFiles(_:)`가
      `attachmentChecksums()`로 남은 전체 참조를 다시 계산해
      `AttachmentFileStore.removeIfUnreferenced`를 호출하고, `removedAttachmentIDs`
      각각에 대해 `tmp/AttachmentPreview/<id>` 미리보기 임시 디렉터리를 지운다.
- [x] 4.4 `importStore.removeSourceSnapshots(sourceUUIDs: summary.purgedSourceUUIDs)`를
      `applyPurge`에서 호출한다.
- [x] 4.5 `emptyTrash()` 완료 시 `lastOperationOutcome`으로 결과를 알린다(개별
      삭제는 알리지 않음).
- [x] 4.6 `autosaveOnEditorExit`(:624-633) 가드를 강화해, `draft.id`가 있는데
      `repository.entry(id:)`가 `nil`이거나 `isDeleted`면 저장하지 않고 반환하게
      한다.
- [x] 4.7 `AppModel.swift:915` 부근 `analyzeDayOne`의 `includeDeleted: true`
      유지 근거를 주석으로 남긴다.
- [x] 4.8 `Tests/PilgrimJournalTests/AppModelNavigationTests.swift`에 추가한다:
      열린 에디터/선택 정리, autosave가 영구 삭제된 기록을 되살리지 못함(회귀),
      emptyTrash가 살아있는 기록은 건드리지 않음, 공유 CAS 파일은 남고 고유 파일만
      삭제.

## 5. UI

- [x] 5.1 `Sources/PilgrimJournal/EntryViews.swift`의 `TrashView`에 행별 "영구 삭제"
      버튼(iOS/macOS 각각)을 추가한다.
- [x] 5.2 툴바에 "휴지통 비우기" 버튼을 추가하고 휴지통이 비어 있으면 비활성화한다.
- [x] 5.3 두 개의 `confirmationDialog`(개별/전체)에 계획된 한국어 문구와 destructive
      스타일을 적용한다.

## 6. Day One 재가져오기 회귀

- [x] 6.1 `Tests/DayOneImportTests/DayOneImportTests.swift`에 영구 삭제 후 같은
      sourceUUID 재가져오기가 성공하는 테스트를 추가한다(버그 회귀).
- [x] 6.2 휴지통에만 있고 영구 삭제되지 않은 기록은 여전히 중복으로 차단되는
      부정 케이스 테스트를 추가한다.

## 7. 문서와 검증

- [x] 7.1 `docs/implementation-todo.md`의 "휴지통 완전 비우기 기능이 없음" 항목을
      `## 완료`로 옮긴다.
- [x] 7.2 `docs/user-guide.md` 휴지통 절에 영구 삭제/비우기를, 백업 절에 "영구 삭제
      이전 백업을 전체 대치로 복원하면 타임라인으로 되살아남"을 추가한다.
- [x] 7.3 `Sources/PilgrimJournal/AppUsageGuideView.swift`의 `trash` 항목 본문을
      갱신한다(id는 유지). `Tests/PilgrimJournalTests/AppUsageGuideContentTests.swift`에
      본문이 "영구 삭제"를 포함하는지 확인하는 단언을 추가한다.
- [x] 7.4 `docs/device-verification.md`에 휴지통 영구 삭제 2대 기기 수렴 게이트를,
      `docs/pre-release-checklist.md`에 해당 게이트를 추가한다.
- [x] 7.5 `Sources/JournalChecks/main.swift`의 휴지통 왕복 스모크에 purge를
      추가한다.
- [x] 7.6 `./scripts/check.sh`를 실행하고 통과를 확인한다.
