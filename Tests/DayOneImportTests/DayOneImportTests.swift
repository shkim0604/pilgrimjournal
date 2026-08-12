#if canImport(XCTest)
import DayOneImport
import Foundation
import JournalData
import JournalDomain
import XCTest

final class DayOneImportTests: XCTestCase {
    func testBatchNotebookAssignmentChangesOnlySelectedPreviewItems() {
        let first = DayOnePreviewItem(
            stableEntryID: UUID(),
            sourceUUID: "selected-1",
            draft: JournalEntryDraft(kind: .diary, body: "첫 기록", tags: ["기존"]),
            rawJSON: Data(),
            classification: ClassificationDecision(
                kind: .diary,
                ruleID: nil,
                isConflict: false
            ),
            attachments: [],
            warnings: []
        )
        let second = DayOnePreviewItem(
            stableEntryID: UUID(),
            sourceUUID: "selected-2",
            draft: JournalEntryDraft(kind: .prayer, body: "둘째 기록"),
            rawJSON: Data(),
            classification: ClassificationDecision(
                kind: .prayer,
                ruleID: nil,
                isConflict: false
            ),
            attachments: [],
            warnings: []
        )
        let unselected = DayOnePreviewItem(
            stableEntryID: UUID(),
            sourceUUID: "unselected",
            draft: JournalEntryDraft(kind: .reading, body: "남은 기록"),
            rawJSON: Data(),
            classification: ClassificationDecision(
                kind: .reading,
                ruleID: nil,
                isConflict: false
            ),
            attachments: [],
            warnings: []
        )
        let preview = DayOneImportPreview(
            archiveURL: URL(fileURLWithPath: "/tmp/fixture.zip"),
            archiveFingerprint: "fixture",
            exportVersion: "1.0",
            JSONDisplayName: "fixture.json",
            items: [first, second, unselected],
            duplicateSourceUUIDs: [],
            optionalFieldCounts: [:],
            missingAttachmentCount: 0,
            warnings: []
        )

        let updated = preview.assigningNotebook(
            "가져온 일기",
            to: ["selected-1", "selected-2"]
        )

        XCTAssertEqual(updated.items[0].draft.notebookName, "가져온 일기")
        XCTAssertEqual(updated.items[0].draft.visibleTags, ["기존"])
        XCTAssertEqual(updated.items[1].draft.notebookName, "가져온 일기")
        XCTAssertNil(updated.items[2].draft.notebookName)
    }

    func testAnalyzesAnonymousVersionOneSampleAndUsesText() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let richTextObject: [String: Any] = [
            "contents": [["text": "rich text 내용"]],
            "meta": ["version": 1],
        ]
        let richTextData = try JSONSerialization.data(withJSONObject: richTextObject)
        let richText = String(decoding: richTextData, as: UTF8.self)
        let root: [String: Any] = [
            "metadata": ["version": "1.0"],
            "entries": [[
                "uuid": "00000000-0000-0000-0000-000000000001",
                "text": "일반 본문",
                "richText": richText,
                "creationDate": "2026-07-23T01:10:59Z",
                "modifiedDate": "2026-07-23T01:11:59Z",
                "timeZone": "Asia/Seoul",
                "starred": true,
                "isPinned": true,
                "location": ["country": "대한민국"],
                "weather": ["temperatureCelsius": 25],
                "template": ["uuid": "template-prayer", "title": "기도"],
            ]],
        ]
        let json = try JSONSerialization.data(withJSONObject: root)
        try TestZipFactory.make(
            items: [.init(name: "%EC%9D%BC%EA%B8%B0.json", data: json, deflated: true)],
            at: url
        )
        let rule = ClassificationRuleRecord(
            source: .templateUUID,
            value: "template-prayer",
            targetKind: .prayer,
            priority: 10
        )

        let preview = try DayOneArchiveAnalyzer().analyze(
            archiveURL: url,
            rules: [rule]
        )

        XCTAssertEqual(preview.exportVersion, "1.0")
        XCTAssertEqual(preview.JSONDisplayName, "일기.json")
        XCTAssertEqual(preview.items.count, 1)
        XCTAssertEqual(preview.items[0].draft.body, "일반 본문")
        XCTAssertEqual(preview.items[0].draft.kind, .prayer)
        XCTAssertEqual(preview.items[0].draft.originalTimeZone, "Asia/Seoul")
        XCTAssertTrue(preview.items[0].draft.isStarred)
        XCTAssertTrue(preview.items[0].draft.isPinned)
    }

    func testFallsBackToRichTextContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let richText = #"{"contents":[{"text":"첫 줄"},{"text":"둘째 줄"}]}"#
        let root: [String: Any] = [
            "metadata": ["version": "1.0"],
            "entries": [[
                "uuid": "source-without-standard-uuid",
                "richText": richText,
                "creationDate": "2026-07-23T01:10:59Z",
            ]],
        ]
        try TestZipFactory.make(
            items: [.init(
                name: "export.json",
                data: try JSONSerialization.data(withJSONObject: root),
                deflated: false
            )],
            at: url
        )
        let preview = try DayOneArchiveAnalyzer().analyze(archiveURL: url)
        XCTAssertEqual(preview.items[0].draft.body, "첫 줄\n둘째 줄")
        XCTAssertEqual(preview.items[0].draft.kind, .unclassified)
    }

    func testRejectsPathTraversal() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestZipFactory.make(
            items: [.init(name: "../evil.json", data: Data("{}".utf8), deflated: false)],
            at: url
        )
        XCTAssertThrowsError(try SafeZipArchive(url: url))
    }

    func testMarksKnownSourceAsDuplicateWithoutMutation() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let root: [String: Any] = [
            "metadata": ["version": "1.0"],
            "entries": [[
                "uuid": "known-source",
                "text": "본문",
                "creationDate": "2026-07-23T01:10:59Z",
            ]],
        ]
        try TestZipFactory.make(
            items: [.init(
                name: "journal.json",
                data: try JSONSerialization.data(withJSONObject: root),
                deflated: true
            )],
            at: url
        )
        let preview = try DayOneArchiveAnalyzer().analyze(
            archiveURL: url,
            knownSourceUUIDs: ["known-source"]
        )
        XCTAssertEqual(preview.duplicateSourceUUIDs, ["known-source"])
    }

    func testAnalysisCountsOptionalFieldsAndMissingAttachments() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let root: [String: Any] = [
            "metadata": ["version": "1.0"],
            "entries": [[
                "uuid": "with-attachments",
                "text": "첨부 테스트",
                "creationDate": "2026-07-23T01:10:59Z",
                "timeZone": "Asia/Seoul",
                "tags": ["사진"],
                "weather": ["temperatureCelsius": 25],
                "photos": [
                    ["filename": "present.jpg"],
                    ["filename": "missing.jpg"],
                ],
            ]],
        ]
        try TestZipFactory.make(
            items: [
                .init(
                    name: "journal.json",
                    data: try JSONSerialization.data(withJSONObject: root),
                    deflated: true
                ),
                .init(
                    name: "photos/present.jpg",
                    data: Data([0xFF, 0xD8, 0xFF]),
                    deflated: false
                ),
            ],
            at: url
        )

        let preview = try DayOneArchiveAnalyzer().analyze(archiveURL: url)

        XCTAssertFalse(preview.archiveFingerprint.isEmpty)
        XCTAssertNotNil(preview.dateRange)
        XCTAssertEqual(preview.optionalFieldCounts["timeZone"], 1)
        XCTAssertEqual(preview.optionalFieldCounts["tags"], 1)
        XCTAssertEqual(preview.optionalFieldCounts["weather"], 1)
        XCTAssertEqual(preview.optionalFieldCounts["photos"], 1)
        XCTAssertEqual(preview.missingAttachmentCount, 1)
        XCTAssertTrue(
            preview.items[0].warnings.contains { $0.contains("missing.jpg") }
        )
    }

    func testEqualPriorityConflictStaysUnclassifiedUntilExplicitOverride() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let sourceUUID = "conflicting-source"
        let root: [String: Any] = [
            "metadata": ["version": "1.0"],
            "entries": [[
                "uuid": sourceUUID,
                "text": "분류 충돌",
                "creationDate": "2026-07-23T01:10:59Z",
                "tags": ["공통"],
            ]],
        ]
        try TestZipFactory.make(
            items: [.init(
                name: "journal.json",
                data: try JSONSerialization.data(withJSONObject: root),
                deflated: true
            )],
            at: url
        )
        let rules = [
            ClassificationRuleRecord(
                source: .tag,
                value: "공통",
                targetKind: .prayer,
                priority: 10
            ),
            ClassificationRuleRecord(
                source: .tag,
                value: "공통",
                targetKind: .diary,
                priority: 10
            ),
        ]

        let preview = try DayOneArchiveAnalyzer().analyze(
            archiveURL: url,
            rules: rules
        )
        XCTAssertEqual(preview.items[0].draft.kind, .unclassified)
        XCTAssertTrue(preview.items[0].classification.isConflict)

        let overridden = preview.applying(
            itemOverrides: [sourceUUID: .reading]
        )
        XCTAssertEqual(overridden.items[0].draft.kind, .reading)
        XCTAssertFalse(overridden.items[0].classification.isConflict)
        XCTAssertNil(overridden.items[0].classification.ruleID)
    }

    func testAnonymousMediaAndMalformedFieldFixture() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestZipFactory.makeMediaFixture(at: url)

        let preview = try DayOneArchiveAnalyzer().analyze(archiveURL: url)

        XCTAssertEqual(preview.items.count, 3)
        XCTAssertEqual(preview.optionalFieldCounts["tags"], 1)
        XCTAssertEqual(preview.optionalFieldCounts["photos"], 1)
        XCTAssertEqual(preview.optionalFieldCounts["videos"], 1)
        XCTAssertEqual(preview.optionalFieldCounts["audios"], 1)
        XCTAssertEqual(preview.missingAttachmentCount, 1)
        XCTAssertTrue(preview.warnings.contains { $0.contains("uuid") })
        XCTAssertTrue(
            preview.items
                .first { $0.sourceUUID == "fixture-malformed-rich-text" }?
                .warnings.contains { $0.contains("richText") } == true
        )
    }

    func testRejectsInvalidEncryptedAndOversizedArchives() throws {
        let invalidURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        let encryptedURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        let oversizedURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer {
            try? FileManager.default.removeItem(at: invalidURL)
            try? FileManager.default.removeItem(at: encryptedURL)
            try? FileManager.default.removeItem(at: oversizedURL)
        }

        try Data("not a zip".utf8).write(to: invalidURL)
        XCTAssertThrowsError(try DayOneArchiveAnalyzer().analyze(archiveURL: invalidURL))

        try TestZipFactory.make(
            items: [.init(
                name: "encrypted.json",
                data: Data("{}".utf8),
                deflated: false,
                encrypted: true
            )],
            at: encryptedURL
        )
        XCTAssertThrowsError(try SafeZipArchive(url: encryptedURL))

        try TestZipFactory.make(
            items: [.init(
                name: "large.json",
                data: Data(repeating: 0x41, count: 128),
                deflated: false
            )],
            at: oversizedURL
        )
        XCTAssertThrowsError(
            try SafeZipArchive(
                url: oversizedURL,
                limits: ZipSafetyLimits(maximumEntrySize: 64)
            )
        )
    }

    @MainActor
    func testFailedAnalysisDoesNotMutateCanonicalRepository() throws {
        let repository = InMemoryJournalRepository()
        _ = try repository.save(
            JournalEntryDraft(kind: .diary, body: "기존 기록"),
            deviceID: "Mac",
            at: .now
        )
        let before = try repository.list(
            kind: nil,
            includeDeleted: true,
            limit: 100
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestZipFactory.make(
            items: [.init(
                name: "wrong.json",
                data: Data(#"{"metadata":{"version":"9.9"},"entries":[]}"#.utf8),
                deflated: true
            )],
            at: url
        )

        XCTAssertThrowsError(try DayOneArchiveAnalyzer().analyze(archiveURL: url))
        let after = try repository.list(
            kind: nil,
            includeDeleted: true,
            limit: 100
        )
        XCTAssertEqual(after, before)
    }

    @MainActor
    func testExecutorReportsPerItemOutcomesAndProgress() async throws {
        let repository = InMemoryJournalRepository()
        _ = try repository.save(
            JournalEntryDraft(
                kind: .diary,
                body: "이미 가져온 기록",
                sourceUUID: "duplicate-source"
            ),
            deviceID: "Mac",
            at: .now
        )
        let items = [
            DayOnePreviewItem(
                stableEntryID: UUID(),
                sourceUUID: "new-source",
                draft: JournalEntryDraft(
                    kind: .prayer,
                    title: "새 기도",
                    body: "본문",
                    sourceUUID: "new-source"
                ),
                rawJSON: Data("{}".utf8),
                classification: ClassificationDecision(
                    kind: .prayer,
                    ruleID: nil,
                    isConflict: false
                ),
                attachments: [],
                warnings: ["선택 필드 확인"]
            ),
            DayOnePreviewItem(
                stableEntryID: UUID(),
                sourceUUID: "duplicate-source",
                draft: JournalEntryDraft(
                    kind: .diary,
                    body: "중복",
                    sourceUUID: "duplicate-source"
                ),
                rawJSON: Data("{}".utf8),
                classification: ClassificationDecision(
                    kind: .diary,
                    ruleID: nil,
                    isConflict: false
                ),
                attachments: [],
                warnings: []
            ),
        ]
        let preview = DayOneImportPreview(
            archiveURL: URL(fileURLWithPath: "/tmp/anonymous.zip"),
            archiveFingerprint: "anonymous",
            exportVersion: "1.0",
            JSONDisplayName: "journal.json",
            items: items,
            duplicateSourceUUIDs: ["duplicate-source"],
            optionalFieldCounts: [:],
            missingAttachmentCount: 0,
            warnings: []
        )
        var progress: [(Int, Int)] = []

        let result = await DayOneImportExecutor().execute(
            preview: preview,
            repository: repository,
            deviceID: "Mac"
        ) { _ in
        } onProgress: { completed, total in
            progress.append((completed, total))
        }

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.outcomes.map(\.status), [.imported, .skipped])
        XCTAssertEqual(result.outcomes[0].warnings, ["선택 필드 확인"])
        XCTAssertEqual(progress.map(\.0), [1, 2])
        XCTAssertTrue(progress.allSatisfy { $0.1 == 2 })
    }

    @MainActor
    func testPurgedImportedEntryCanBeReimported() async throws {
        let repository = InMemoryJournalRepository()
        let original = try repository.save(
            JournalEntryDraft(
                kind: .diary,
                body: "지울 가져오기 기록",
                sourceUUID: "purge-then-reimport"
            ),
            deviceID: "Mac",
            at: .now
        )
        try repository.moveToTrash(entryID: original.id, deviceID: "Mac", at: .now)
        // The bug this regression test locks in: a trashed-but-not-purged
        // entry keeps blocking re-import via `entry(sourceUUID:)`, which
        // does not filter deleted rows — only removing the row entirely
        // (purgeEntries) frees the sourceUUID.
        _ = try repository.purgeEntries(ids: [original.id])

        let items = [
            DayOnePreviewItem(
                stableEntryID: UUID(),
                sourceUUID: "purge-then-reimport",
                draft: JournalEntryDraft(
                    kind: .diary,
                    body: "다시 가져온 기록",
                    sourceUUID: "purge-then-reimport"
                ),
                rawJSON: Data("{}".utf8),
                classification: ClassificationDecision(
                    kind: .diary,
                    ruleID: nil,
                    isConflict: false
                ),
                attachments: [],
                warnings: []
            ),
        ]
        let preview = DayOneImportPreview(
            archiveURL: URL(fileURLWithPath: "/tmp/anonymous.zip"),
            archiveFingerprint: "anonymous",
            exportVersion: "1.0",
            JSONDisplayName: "journal.json",
            items: items,
            duplicateSourceUUIDs: [],
            optionalFieldCounts: [:],
            missingAttachmentCount: 0,
            warnings: []
        )

        let result = await DayOneImportExecutor().execute(
            preview: preview,
            repository: repository,
            deviceID: "Mac"
        )

        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.outcomes.map(\.status), [.imported])
        XCTAssertNotNil(try repository.entry(sourceUUID: "purge-then-reimport"))
    }

    @MainActor
    func testTrashedButNotPurgedImportedEntryStillBlocksReimport() async throws {
        let repository = InMemoryJournalRepository()
        let original = try repository.save(
            JournalEntryDraft(
                kind: .diary,
                body: "휴지통에만 있는 기록",
                sourceUUID: "trashed-not-purged"
            ),
            deviceID: "Mac",
            at: .now
        )
        try repository.moveToTrash(entryID: original.id, deviceID: "Mac", at: .now)

        let items = [
            DayOnePreviewItem(
                stableEntryID: UUID(),
                sourceUUID: "trashed-not-purged",
                draft: JournalEntryDraft(
                    kind: .diary,
                    body: "다시 시도",
                    sourceUUID: "trashed-not-purged"
                ),
                rawJSON: Data("{}".utf8),
                classification: ClassificationDecision(
                    kind: .diary,
                    ruleID: nil,
                    isConflict: false
                ),
                attachments: [],
                warnings: []
            ),
        ]
        let preview = DayOneImportPreview(
            archiveURL: URL(fileURLWithPath: "/tmp/anonymous.zip"),
            archiveFingerprint: "anonymous",
            exportVersion: "1.0",
            JSONDisplayName: "journal.json",
            items: items,
            duplicateSourceUUIDs: ["trashed-not-purged"],
            optionalFieldCounts: [:],
            missingAttachmentCount: 0,
            warnings: []
        )

        let result = await DayOneImportExecutor().execute(
            preview: preview,
            repository: repository,
            deviceID: "Mac"
        )

        XCTAssertEqual(result.succeeded, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.outcomes.map(\.status), [.skipped])
        XCTAssertTrue(try XCTUnwrap(repository.entry(id: original.id)).isDeleted)
    }

    @MainActor
    func testExecutorImportsMediaAndIsolatesMissingAttachment() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestZipFactory.makeMediaFixture(at: url)
        let preview = try DayOneArchiveAnalyzer().analyze(archiveURL: url)
        let repository = InMemoryJournalRepository()

        let result = await DayOneImportExecutor().execute(
            preview: preview,
            repository: repository,
            deviceID: "Mac"
        )

        XCTAssertEqual(result.succeeded, 3)
        XCTAssertEqual(try repository.allAttachments().count, 2)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("missing.m4a") }
        )
        let mediaEntry = try XCTUnwrap(
            repository.entry(sourceUUID: "fixture-with-media")
        )
        let media = try repository.allAttachments().filter {
            $0.0.entryID == mediaEntry.id
        }
        XCTAssertEqual(Set(media.map(\.0.mimeType)), ["image/jpeg", "video/quicktime"])
        XCTAssertTrue(media.allSatisfy { $0.0.state == .pending })
    }

    @MainActor
    func testCorruptMediaDoesNotFailJournalEntry() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestZipFactory.makeMediaFixture(at: url)
        let archive = try SafeZipArchive(url: url)
        let videoEntry = try XCTUnwrap(
            archive.entries.first { $0.displayName.hasSuffix("clip.mov") }
        )
        var archiveData = try Data(contentsOf: url)
        let headerOffset = Int(videoEntry.localHeaderOffset)
        let nameLength = Int(archiveData[headerOffset + 26])
            | (Int(archiveData[headerOffset + 27]) << 8)
        let extraLength = Int(archiveData[headerOffset + 28])
            | (Int(archiveData[headerOffset + 29]) << 8)
        let payloadOffset = headerOffset + 30 + nameLength + extraLength
        archiveData[payloadOffset] ^= 0xFF
        try archiveData.write(to: url)
        let preview = try DayOneArchiveAnalyzer().analyze(archiveURL: url)
        let repository = InMemoryJournalRepository()

        let result = await DayOneImportExecutor().execute(
            preview: preview,
            repository: repository,
            deviceID: "Mac"
        )

        XCTAssertEqual(result.succeeded, 3)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(try repository.allAttachments().count, 1)
        XCTAssertTrue(
            result.warnings.contains {
                $0.contains("clip.mov") && $0.contains("checksum")
            }
        )
    }

    @MainActor
    func testRerunPartialCompletionAndSafeBoundaryCancellation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: url) }
        try TestZipFactory.makeMediaFixture(at: url)
        let preview = try DayOneArchiveAnalyzer().analyze(archiveURL: url)

        let rerunRepository = InMemoryJournalRepository()
        let first = await DayOneImportExecutor().execute(
            preview: preview,
            repository: rerunRepository,
            deviceID: "Mac"
        )
        let second = await DayOneImportExecutor().execute(
            preview: preview,
            repository: rerunRepository,
            deviceID: "Mac"
        )
        XCTAssertEqual(first.succeeded, 3)
        XCTAssertEqual(second.skipped, 3)
        XCTAssertEqual(try rerunRepository.allAttachments().count, 2)

        let partialRepository = InMemoryJournalRepository()
        _ = try partialRepository.save(
            preview.items[0].draft,
            deviceID: "Mac",
            at: .now
        )
        let resumed = await DayOneImportExecutor().execute(
            preview: preview,
            repository: partialRepository,
            deviceID: "Mac"
        )
        XCTAssertEqual(resumed.succeeded, 2)
        XCTAssertEqual(resumed.skipped, 1)

        let cancelledRepository = InMemoryJournalRepository()
        var keepGoing = true
        let cancelled = await DayOneImportExecutor().execute(
            preview: preview,
            repository: cancelledRepository,
            deviceID: "Mac"
        ) { _ in
        } onProgress: { completed, _ in
            if completed == 1 { keepGoing = false }
        } shouldContinue: {
            keepGoing
        }
        XCTAssertEqual(cancelled.succeeded, 1)
        XCTAssertTrue(
            cancelled.warnings.contains { $0.contains("취소") }
        )
        XCTAssertEqual(
            try cancelledRepository.list(
                kind: nil,
                includeDeleted: false,
                limit: 10
            ).count,
            1
        )
    }

    @MainActor
    func testLargeArchivePerformanceProgressAndCancellation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-large.zip")
        defer { try? FileManager.default.removeItem(at: url) }
        let entries: [[String: Any]] = (0..<5_000).map { value in
            [
                "uuid": "large-fixture-\(value)",
                "text": "대량 가져오기 성능 검증 본문 \(value)",
                "creationDate": "2026-01-01T01:00:00Z",
                "tags": ["합성", "묶음-\(value % 10)"],
            ]
        }
        let rawJSON = try JSONSerialization.data(withJSONObject: [
            "metadata": ["version": "1.0"],
            "entries": entries,
        ])
        try TestZipFactory.make(
            items: [TestZipFactory.Item(
                name: "large.json",
                data: rawJSON,
                deflated: true
            )],
            at: url
        )

        let analyzeStarted = ContinuousClock.now
        let preview = try DayOneArchiveAnalyzer().analyze(archiveURL: url)
        let analyzeDuration = analyzeStarted.duration(to: .now)
        let archiveSize = try XCTUnwrap(
            url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )

        XCTAssertEqual(preview.items.count, 5_000)
        XCTAssertLessThan(analyzeDuration, .seconds(15))
        XCTAssertLessThan(archiveSize, rawJSON.count)

        let repository = InMemoryJournalRepository()
        var keepGoing = true
        var progress: [Int] = []
        let result = await DayOneImportExecutor().execute(
            preview: preview,
            repository: repository,
            deviceID: "performance-test",
            batchSize: 50
        ) { _ in
        } onProgress: { completed, total in
            XCTAssertEqual(total, 5_000)
            progress.append(completed)
            if completed == 250 { keepGoing = false }
        } shouldContinue: {
            keepGoing
        }

        XCTAssertEqual(result.succeeded, 250)
        XCTAssertEqual(progress, Array(1...250))
        XCTAssertTrue(result.warnings.contains { $0.contains("취소") })
        XCTAssertEqual(
            try repository.list(kind: nil, includeDeleted: false, limit: 10_000).count,
            250
        )
    }
}
#endif
