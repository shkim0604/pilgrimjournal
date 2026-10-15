import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch

struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(message: message) }
}

func sampleRecord(
    id: UUID = UUID(),
    title: String,
    body: String,
    kind: JournalKind = .diary,
    date: Date = .now
) -> JournalEntryRecord {
    JournalEntryRecord(
        id: id,
        kind: kind,
        title: title,
        body: body,
        occurredAt: date,
        originalTimeZone: "Asia/Seoul",
        tags: ["검증"],
        isStarred: false,
        isPinned: false,
        details: EntryDetails(),
        sourceUUID: nil,
        sourceMetadata: nil,
        currentRevisionID: UUID(),
        updatedAt: date,
        modifiedByDeviceID: "checks"
    )
}

do {
    let stableA = StableIdentifier.fromDayOne(sourceUUID: "anonymous-source")
    let stableB = StableIdentifier.fromDayOne(sourceUUID: "anonymous-source")
    try expect(stableA == stableB, "Day One 안정 ID가 결정적이지 않습니다.")

    let rule = ClassificationRuleRecord(
        source: .templateTitle,
        value: "기도",
        targetKind: .prayer,
        priority: 10
    )
    let classified = ClassificationEngine().classify(
        ClassificationCandidate(tags: [], templateUUID: nil, templateTitle: "기도"),
        rules: [rule]
    )
    try expect(classified.kind == .prayer, "템플릿 분류가 실패했습니다.")

    try await MainActor.run {
        let repository = InMemoryJournalRepository()
        let first = try repository.save(
            JournalEntryDraft(kind: .diary, title: "첫 제목", body: "첫 본문"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 1)
        )
        var edited = first.draft
        edited.title = "수정한 제목"
        let current = try repository.save(
            edited,
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 2)
        )
        let revisions = try repository.revisions(entryID: current.id)
        try expect(revisions.count == 2, "revision 생성 수가 맞지 않습니다.")
        guard let original = revisions.first(where: { $0.snapshot.title == "첫 제목" }) else {
            throw CheckFailure(message: "원본 revision을 찾지 못했습니다.")
        }
        let restored = try repository.restore(
            entryID: current.id,
            revisionID: original.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 3)
        )
        try expect(restored.title == "첫 제목", "revision 복원이 실패했습니다.")
        try repository.moveToTrash(
            entryID: restored.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 4)
        )
        let deleted = try repository.entry(id: restored.id)?.isDeleted
        try expect(deleted == true, "tombstone 생성이 실패했습니다.")
        try repository.restoreFromTrash(
            entryID: restored.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 5)
        )
        let undeleted = try repository.entry(id: restored.id)?.isDeleted
        try expect(undeleted == false, "휴지통 복원이 실패했습니다.")

        try repository.moveToTrash(
            entryID: restored.id,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 6)
        )
        let summary = try repository.purgeEntries(ids: [restored.id])
        try expect(
            summary.purgedEntryIDs == [restored.id],
            "영구 삭제 요약이 맞지 않습니다."
        )
        let purgedEntry = try repository.entry(id: restored.id)
        try expect(purgedEntry == nil, "영구 삭제 후에도 기록이 남아 있습니다.")
        let purgedRevisions = try repository.revisions(entryID: restored.id)
        try expect(purgedRevisions.isEmpty, "영구 삭제 후에도 수정 이력이 남아 있습니다.")
    }

    let temporary = FileManager.default.temporaryDirectory
        .appending(path: "PilgrimJournalChecks-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let persistenceURL = temporary.appending(path: "repository.json")
    let persistedID = try await MainActor.run {
        let repository = try InMemoryJournalRepository(persistingTo: persistenceURL)
        return try repository.save(
            JournalEntryDraft(kind: .reading, title: "재실행 검증", body: "로컬 영속화"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        ).id
    }
    let persistedTitle = try await MainActor.run {
        let reopened = try InMemoryJournalRepository(persistingTo: persistenceURL)
        return try reopened.entry(id: persistedID)?.title
    }
    try expect(persistedTitle == "재실행 검증", "로컬 저장소 재실행 복구가 실패했습니다.")

    let secureStore = InMemorySecureValueStore()
    let lockService = AppLockService(store: secureStore, iterations: 1_500)
    try await lockService.configure(
        password: "private-journal",
        confirmation: "private-journal",
        timeout: .fiveMinutes,
        allowsBiometrics: true
    )
    let lockConfiguration = try await lockService.configuration()
    try expect(lockConfiguration.isEnabled, "앱 잠금이 활성화되지 않았습니다.")
    try expect(lockConfiguration.timeout == .fiveMinutes, "앱 잠금 시간이 저장되지 않았습니다.")
    let storedLockData = secureStore.load() ?? Data()
    try expect(
        !storedLockData.contains(Data("private-journal".utf8)),
        "비밀번호 원문이 보안 상태에 저장되었습니다."
    )
    let correctPassword = try await lockService.verify(
        password: "private-journal",
        at: Date(timeIntervalSince1970: 100)
    )
    try expect(correctPassword == .success, "올바른 앱 비밀번호 검증이 실패했습니다.")
    _ = try await lockService.verify(
        password: "wrong-password",
        at: Date(timeIntervalSince1970: 101)
    )
    _ = try await lockService.verify(
        password: "wrong-password",
        at: Date(timeIntervalSince1970: 102)
    )
    let thirdFailure = try await lockService.verify(
        password: "wrong-password",
        at: Date(timeIntervalSince1970: 103)
    )
    guard case let .retryAfter(retryDate) = thirdFailure else {
        throw CheckFailure(message: "반복 실패 재시도 제한이 적용되지 않았습니다.")
    }
    let reopenedLockService = AppLockService(store: secureStore, iterations: 1)
    let persistedRetry = try await reopenedLockService.verify(
        password: "private-journal",
        at: Date(timeIntervalSince1970: 104)
    )
    try expect(
        persistedRetry == .retryAfter(retryDate),
        "서비스 재생성 후 재시도 제한이 유지되지 않았습니다."
    )
    try await reopenedLockService.clearFailuresAfterDeviceAuthentication()
    let unlockedAfterOwnerAuth = try await reopenedLockService.verify(
        password: "private-journal",
        at: Date(timeIntervalSince1970: 105)
    )
    try expect(
        unlockedAfterOwnerAuth == .success,
        "기기 인증 후 실패 상태 초기화가 실패했습니다."
    )
    let backgroundedAt = Date(timeIntervalSince1970: 200)
    try expect(
        !AppLockTimeout.fiveMinutes.shouldLock(
            backgroundedAt: backgroundedAt,
            activeAt: backgroundedAt.addingTimeInterval(299)
        ),
        "자동 잠금 유예 시간보다 일찍 잠겼습니다."
    )
    try expect(
        AppLockTimeout.fiveMinutes.shouldLock(
            backgroundedAt: backgroundedAt,
            activeAt: backgroundedAt.addingTimeInterval(300)
        ),
        "자동 잠금 유예 시간이 지나도 잠기지 않았습니다."
    )

    let root: [String: Any] = [
        "metadata": ["version": "1.0"],
        "entries": [
            [
                "uuid": "00000000-0000-0000-0000-000000000001",
                "text": "익명 검증 본문",
                "richText": #"{"contents":[{"text":"서식 본문"}]}"#,
                "creationDate": "2026-07-23T01:10:59Z",
                "modifiedDate": "2026-07-23T01:11:59Z",
                "timeZone": "Asia/Seoul",
                "starred": true,
                "isPinned": true,
                "template": ["uuid": "template-prayer", "title": "기도"],
            ]
        ],
    ]
    let anonymousJSON = try JSONSerialization.data(withJSONObject: root)
    let dayOneURL = temporary.appending(path: "anonymous-day-one.zip")
    try writeSingleEntryZip(
        name: "%EC%9D%BC%EA%B8%B0.json",
        data: anonymousJSON,
        at: dayOneURL
    )
    let preview = try DayOneArchiveAnalyzer().analyze(
        archiveURL: dayOneURL,
        rules: [rule]
    )
    try expect(preview.jsonDisplayName == "일기.json", "URL 인코딩 파일명 처리가 실패했습니다.")
    try expect(preview.items.count == 1, "Day One 항목 수가 맞지 않습니다.")
    try expect(preview.items[0].draft.body == "익명 검증 본문", "text 우선 처리가 실패했습니다.")
    try expect(preview.items[0].draft.kind == .prayer, "가져오기 분류가 실패했습니다.")

    let importCounts = await Task { @MainActor in
        let repository = InMemoryJournalRepository()
        let executor = DayOneImportExecutor()
        let first = await executor.execute(
            preview: preview,
            repository: repository,
            deviceID: "Mac"
        )
        let second = await executor.execute(
            preview: preview,
            repository: repository,
            deviceID: "Mac"
        )
        return (
            first.succeeded, second.skipped,
            (try? repository.list(
                kind: nil,
                includeDeleted: true,
                limit: 100
            ).count) ?? -1
        )
    }.value
    try expect(importCounts == (1, 1, 1), "Day One 재실행 중복 방지가 실패했습니다.")

    let unsafeURL = temporary.appending(path: "unsafe.zip")
    try writeSingleEntryZip(
        name: "../outside.json",
        data: anonymousJSON,
        at: unsafeURL
    )
    do {
        _ = try SafeZipArchive(url: unsafeURL)
        throw CheckFailure(message: "ZIP path traversal가 거부되지 않았습니다.")
    } catch is CheckFailure {
        throw CheckFailure(message: "ZIP path traversal가 거부되지 않았습니다.")
    } catch {
        // Expected: unsafe archive paths never reach the JSON analyzer.
    }

    let attachmentRoot = temporary.appending(path: "attachments", directoryHint: .isDirectory)
    let attachmentStore = try AttachmentFileStore(root: attachmentRoot)
    let attachmentData = Data("동일 첨부".utf8)
    let attachmentEntryID = UUID()
    let firstAttachment = try attachmentStore.store(
        data: attachmentData,
        entryID: attachmentEntryID,
        originalName: "note.txt",
        mimeType: "text/plain"
    )
    let secondAttachment = try attachmentStore.store(
        data: attachmentData,
        entryID: attachmentEntryID,
        originalName: "copy.txt",
        mimeType: "text/plain"
    )
    try expect(!firstAttachment.wasDeduplicated, "첫 첨부가 중복으로 판정되었습니다.")
    try expect(secondAttachment.wasDeduplicated, "동일 checksum 첨부가 중복 제거되지 않았습니다.")
    let loadedAttachment = try attachmentStore.data(
        checksum: firstAttachment.record.checksum
    )
    try expect(loadedAttachment == attachmentData, "첨부 저장 왕복이 실패했습니다.")

    let searchURL = temporary.appending(path: "search.sqlite")
    let search = try JournalSearchIndex(url: searchURL)
    let searchable = sampleRecord(
        title: "요한복음",
        body: "하나님이 세상을 사랑하사",
        kind: .bibleStudy,
        date: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try search.rebuild(from: [searchable])
    let searchIDs = try search.search(JournalSearchQuery(text: "세상을")).map(\.id)
    try expect(searchIDs == [searchable.id], "한국어 부분 검색이 실패했습니다.")
    try search.integrityCheck()

    let searchStateStore = SearchIndexStateStore(
        url: temporary.appending(path: "search-state.json")
    )
    let expectedSearchState = SearchIndexLocalState(
        indexVersion: 2,
        historyToken: "history-42",
        pendingEntryIDs: [searchable.id]
    )
    try await searchStateStore.save(expectedSearchState)
    let loadedSearchState = try await searchStateStore.load()
    try expect(loadedSearchState == expectedSearchState, "검색 history token과 queue 상태 저장이 실패했습니다.")

    let backupURL = temporary.appending(path: "checks.journalbackup")
    let backup = JournalBackupService()
    let revision = EntryRevisionRecord(
        id: searchable.currentRevisionID,
        entryID: searchable.id,
        parentRevisionID: nil,
        snapshot: searchable.draft,
        createdAt: searchable.updatedAt,
        deviceID: "checks"
    )
    try backup.create(
        at: backupURL,
        entries: [searchable],
        revisions: [revision],
        rules: [rule],
        attachments: []
    )
    let restoredBackup = try backup.readAndValidate(from: backupURL)
    try expect(restoredBackup.entries == [searchable], "백업 왕복이 실패했습니다.")

    let restoreCounts = try await Task { @MainActor in
        let repository = InMemoryJournalRepository()
        let localOnly = try repository.save(
            JournalEntryDraft(kind: .diary, title: "로컬 전용", body: "교체 시 tombstone"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 1)
        )
        let plan = backup.plan(
            contents: restoredBackup,
            currentEntries: try repository.list(
                kind: nil,
                includeDeleted: true,
                limit: 100
            ),
            mode: .replace
        )
        let result = try JournalRestoreExecutor().execute(
            contents: restoredBackup,
            plan: plan,
            repository: repository,
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 2)
        )
        return (
            result.restored,
            result.tombstoned,
            try repository.entry(id: localOnly.id)?.isDeleted == true,
            try repository.entry(id: searchable.id) != nil,
            repository.allRestoreEpochs().count
        )
    }.value
    try expect(
        restoreCounts == (1, 1, true, true, 1),
        "replace 복원 계획 또는 RestoreEpoch 적용이 실패했습니다."
    )

    let userKindResult = try await Task { @MainActor in
        let repository = InMemoryJournalRepository()
        var catalog = KindCatalog()
        let created = try catalog.create(
            name: "설교노트", colorToken: .amber, iconToken: KindIconCatalog.symbols[0],
            deviceID: "Mac", at: Date(timeIntervalSince1970: 1))
        _ = try repository.save(
            JournalEntryDraft(kind: created.kind, title: "주일 설교", body: "본문 요약"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 2)
        )
        let before = try repository.list(kind: created.kind, includeDeleted: false, limit: 10)
        try catalog.delete(
            created.kind, moveTarget: .memo, deviceID: "Mac", at: Date(timeIntervalSince1970: 3))
        let moved = try KindDeletionService().moveEntries(
            from: created.kind, to: .memo, repository: repository,
            deviceID: "Mac", at: Date(timeIntervalSince1970: 4)
        ).moved
        return (before.count, moved.count, moved.first?.kind == .memo)
    }.value
    try expect(
        userKindResult == (1, 1, true), "사용자 유형 저장·이동 확인이 실패했습니다.")

    // A hand-written entry moved to 미분류 must survive a backup restored into an empty store.
    let unclassifiedBackupURL = temporary.appending(path: "unclassified.journalbackup")
    let unclassifiedRestore = try await Task { @MainActor in
        let source = InMemoryJournalRepository()
        var catalog = KindCatalog()
        let entry = try source.save(
            JournalEntryDraft(kind: .prayer, title: "손으로 쓴 기도", body: "감사"),
            deviceID: "Mac", at: Date(timeIntervalSince1970: 1))
        try catalog.delete(
            .prayer, moveTarget: .unclassified, deviceID: "Mac", at: Date(timeIntervalSince1970: 2))
        let move = try KindDeletionService().moveEntries(
            from: .prayer, to: .unclassified, repository: source,
            deviceID: "Mac", at: Date(timeIntervalSince1970: 3))
        if let error = move.error { throw error }
        let entries = try source.list(kind: nil, includeDeleted: true, limit: 10)
        try backup.create(
            at: unclassifiedBackupURL, entries: entries,
            revisions: try source.revisions(entryID: entry.id), rules: [], attachments: [],
            kindCatalog: catalog)
        let contents = try backup.readAndValidate(from: unclassifiedBackupURL)
        let destination = InMemoryJournalRepository()
        let result = try JournalRestoreExecutor().execute(
            contents: contents,
            plan: backup.plan(contents: contents, currentEntries: [], mode: .merge),
            repository: destination, deviceID: "iPhone", at: Date(timeIntervalSince1970: 4))
        return (result.restored, try destination.entry(id: entry.id)?.kind == .unclassified)
    }.value
    try expect(
        unclassifiedRestore == (1, true), "미분류로 옮긴 손 기록의 백업 복원이 실패했습니다.")

    if let sampleIndex = CommandLine.arguments.firstIndex(of: "--day-one"),
        CommandLine.arguments.indices.contains(sampleIndex + 1)
    {
        let privateURL = URL(fileURLWithPath: CommandLine.arguments[sampleIndex + 1])
        let privatePreview = try DayOneArchiveAnalyzer().analyze(archiveURL: privateURL)
        print(
            "개인 샘플 구조 검증 완료: version=\(privatePreview.exportVersion), "
                + "entries=\(privatePreview.items.count), warnings=\(privatePreview.warnings.count)"
        )
    }

    print(
        "JournalChecks 통과: domain, revision, app lock, Day One, attachment, search, backup/restore")
} catch {
    FileHandle.standardError.write(
        Data("JournalChecks 실패: \(error.localizedDescription)\n".utf8)
    )
    exit(1)
}

/// One stored (uncompressed) entry, enough for the importer and safety checks.
func writeSingleEntryZip(name: String, data: Data, at url: URL) throws {
    let writer = try StoredZipWriter(url: url)
    try writer.add(name: name, data: data)
    try writer.finish()
}
