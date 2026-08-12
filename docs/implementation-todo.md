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
  렌더링됨. 라이브 에디터 내 WYSIWYG 인라인 이미지는 `LiveMarkdownStyler`의
  "저장되는 마크다운 문자를 절대 바꾸지 않는다" 불변조건과 충돌해 범위에서
  제외함 (2026-08-12)

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
