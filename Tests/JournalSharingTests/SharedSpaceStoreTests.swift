#if canImport(XCTest)
import CloudKit
import Foundation
import JournalData
import JournalDomain
import JournalSharing
import XCTest

@MainActor
final class SharedSpaceStoreTests: XCTestCase {
    private final class Provider: SharedEntryCacheProvider {
        var caches: [UUID: InMemoryJournalRepository] = [:]
        var removed: [UUID] = []

        func cache(for space: SharedSpaceRecord) throws -> any SharedEntryCache {
            if let cache = caches[space.id] { return cache }
            let cache = InMemoryJournalRepository()
            caches[space.id] = cache
            return cache
        }

        func removeCache(for space: SharedSpaceRecord) throws {
            caches[space.id] = nil
            removed.append(space.id)
        }
    }

    private let kind = SharedKindSnapshot(
        kind: .prayer, name: "기도노트", colorToken: .amber, iconToken: "hands.sparkles")
    private var directory: URL!
    private var provider: Provider!
    private var enqueued: [CKRecord.ID] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        provider = Provider()
        enqueued = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore() throws -> SharedSpaceStore {
        let store = try SharedSpaceStore(
            directory: directory, deviceID: "device-local", provider: provider)
        store.onEnqueue = { [weak self] saves, _ in self?.enqueued += saves }
        return store
    }

    private func makeSpace(in store: SharedSpaceStore) -> SharedSpaceRecord {
        let space = SharedSpaceRecord(scope: .notebook, name: "우리집 기도제목", role: .owner)
        store.addSpace(space)
        return space
    }

    /// A record as another family member's device would upload it.
    private func remoteRecord(
        _ entry: JournalEntryRecord,
        in space: SharedSpaceRecord,
        body: String,
        updatedAt: Date
    ) -> CKRecord {
        var remote = entry
        remote.body = body
        remote.currentRevisionID = UUID()
        remote.updatedAt = updatedAt
        remote.modifiedByDeviceID = "device-remote"
        let record = CKRecord(
            recordType: SharedRecordType.entry,
            recordID: SharedRecordMapper.recordID(
                for: entry.id, in: SharedRecordMapper.zoneID(for: space))
        )
        SharedRecordMapper.write(SharedEntryPayload(entry: remote, kind: kind), to: record)
        return record
    }

    func testLocalSaveQueuesTheEntryAndItsRevision() throws {
        let store = try makeStore()
        let space = makeSpace(in: store)

        let saved = try store.save(
            JournalEntryDraft(kind: .prayer, title: "11월", body: "1. 아빠 건강"), kind: kind,
            in: space.id)

        XCTAssertEqual(
            Set(enqueued.map(\.recordName)),
            [saved.id.uuidString, saved.currentRevisionID.uuidString])
        let entryRecord = try XCTUnwrap(store.recordToSave(enqueued[0]))
        XCTAssertEqual(
            try SharedRecordMapper.entryPayload(from: entryRecord).entry.body, "1. 아빠 건강")
        let revisionRecord = try XCTUnwrap(store.recordToSave(enqueued[1]))
        XCTAssertEqual(try SharedRecordMapper.revision(from: revisionRecord).entryID, saved.id)
    }

    func testFetchedEntryWithoutLocalEditsIsCopiedExactly() throws {
        let store = try makeStore()
        let space = makeSpace(in: store)
        let saved = try store.save(
            JournalEntryDraft(kind: .prayer, title: "11월", body: "1. 아빠 건강"), kind: kind,
            in: space.id)
        for id in enqueued { store.didSave(try XCTUnwrap(store.recordToSave(id))) }
        enqueued = []

        let record = remoteRecord(saved, in: space, body: "1. 아빠 건강 회복", updatedAt: .now)
        let needsResend = store.applyFetched(record)

        XCTAssertFalse(needsResend)
        let cached = try XCTUnwrap(try store.cache(for: space.id).entry(id: saved.id))
        let remote = try SharedRecordMapper.entryPayload(from: record).entry
        XCTAssertEqual(cached.body, "1. 아빠 건강 회복")
        XCTAssertEqual(cached.currentRevisionID, remote.currentRevisionID)
        XCTAssertTrue(enqueued.isEmpty)
    }

    func testConcurrentEditsToDifferentLinesAreMergedAndResent() throws {
        let store = try makeStore()
        let space = makeSpace(in: store)
        let original = try store.save(
            JournalEntryDraft(kind: .prayer, title: "11월", body: "1. 아빠 건강\n2. 동생 수능"),
            kind: kind, in: space.id, at: Date(timeIntervalSince1970: 100))
        for id in enqueued { store.didSave(try XCTUnwrap(store.recordToSave(id))) }
        enqueued = []

        var edit = original.draft
        edit.body = "1. 아빠 건강 회복\n2. 동생 수능"
        _ = try store.save(edit, kind: kind, in: space.id, at: Date(timeIntervalSince1970: 200))
        enqueued = []
        let remote = remoteRecord(
            original, in: space, body: "1. 아빠 건강\n2. 동생 수능 평안",
            updatedAt: Date(timeIntervalSince1970: 150))

        let needsResend = store.applyFetched(remote)

        XCTAssertTrue(needsResend)
        let merged = try XCTUnwrap(try store.cache(for: space.id).entry(id: original.id))
        XCTAssertEqual(merged.body, "1. 아빠 건강 회복\n2. 동생 수능 평안")
        XCTAssertEqual(enqueued.map(\.recordName), [merged.currentRevisionID.uuidString])
    }

    func testEditorSaveBasedOnAnOlderRevisionKeepsTheRemoteChange() throws {
        let store = try makeStore()
        let space = makeSpace(in: store)
        let original = try store.save(
            JournalEntryDraft(kind: .prayer, title: "11월", body: "1. 아빠 건강\n2. 동생 수능"),
            kind: kind, in: space.id)
        for id in enqueued { store.didSave(try XCTUnwrap(store.recordToSave(id))) }
        _ = store.applyFetched(
            remoteRecord(original, in: space, body: "1. 아빠 건강\n2. 동생 수능 평안", updatedAt: .now))

        // The editor opened before the remote change and only touched line 1.
        var edit = original.draft
        edit.body = "1. 아빠 건강 회복\n2. 동생 수능"
        let saved = try store.save(
            edit, kind: kind, in: space.id, basedOn: original.currentRevisionID)

        XCTAssertEqual(saved.body, "1. 아빠 건강 회복\n2. 동생 수능 평안")
    }

    func testImportedEntryKeepsItsHistoryAndQueuesEverything() throws {
        let store = try makeStore()
        let space = makeSpace(in: store)
        let source = InMemoryJournalRepository()
        let first = try source.save(
            JournalEntryDraft(kind: .prayer, title: "기도", body: "처음"), deviceID: "d", at: .now)
        var draft = first.draft
        draft.body = "고침"
        let second = try source.save(draft, deviceID: "d", at: .now)
        let revisions = try source.revisions(entryID: first.id)

        try store.importEntry(second, revisions: revisions, kind: kind, into: space.id)

        let cache = try store.cache(for: space.id)
        XCTAssertEqual(try cache.entry(id: first.id), second)
        XCTAssertEqual(try cache.revisions(entryID: first.id).count, 2)
        XCTAssertEqual(
            Set(enqueued.map(\.recordName)),
            Set([first.id.uuidString] + revisions.map(\.id.uuidString)))
        XCTAssertEqual(store.spaceID(containing: first.id), space.id)
        XCTAssertNil(store.spaceID(containing: UUID()))
    }

    func testSaveConfirmationKeepsUnsentFlagWhenEditedInFlight() throws {
        let store = try makeStore()
        let space = makeSpace(in: store)
        let saved = try store.save(
            JournalEntryDraft(kind: .prayer, title: "11월", body: "가"), kind: kind, in: space.id)
        let inFlight = try XCTUnwrap(store.recordToSave(enqueued[0]))

        var edit = saved.draft
        edit.body = "가나"
        _ = try store.save(edit, kind: kind, in: space.id)
        store.didSave(inFlight)
        enqueued = []

        // A remote change now still has to merge with the unsent local edit.
        let remote = remoteRecord(saved, in: space, body: "가", updatedAt: .distantPast)
        XCTAssertTrue(store.applyFetched(remote))
        XCTAssertEqual(try store.cache(for: space.id).entry(id: saved.id)?.body, "가나")
    }

    func testRemovingASpaceDropsOnlyThatSpace() throws {
        let store = try makeStore()
        let first = makeSpace(in: store)
        let second = makeSpace(in: store)
        let kept = try store.save(
            JournalEntryDraft(kind: .prayer, title: "남는 기록"), kind: kind, in: second.id)
        _ = try store.save(
            JournalEntryDraft(kind: .prayer, title: "지울 기록"), kind: kind, in: first.id)

        store.removeSpace(zoneID: SharedRecordMapper.zoneID(for: first))

        XCTAssertEqual(store.spaces.map(\.id), [second.id])
        XCTAssertEqual(provider.removed, [first.id])
        let keptID = SharedRecordMapper.recordID(
            for: kept.id, in: SharedRecordMapper.zoneID(for: second))
        XCTAssertNotNil(store.recordToSave(keptID))
    }

    func testSpacesAndSyncStateSurviveReopening() throws {
        let store = try makeStore()
        let space = makeSpace(in: store)
        let saved = try store.save(
            JournalEntryDraft(kind: .prayer, title: "11월"), kind: kind, in: space.id)

        let reopened = try makeStore()

        XCTAssertEqual(reopened.spaces, [space])
        let recordID = SharedRecordMapper.recordID(
            for: saved.id, in: SharedRecordMapper.zoneID(for: space))
        XCTAssertNotNil(reopened.recordToSave(recordID))
        XCTAssertEqual(reopened.ownedZoneIDs, [SharedRecordMapper.zoneID(for: space)])
    }

    func testFetchedRecordInAnUnknownZoneAddsAParticipantSpace() throws {
        let store = try makeStore()
        let space = SharedSpaceRecord(scope: .notebook, name: "", role: .participant)
        let zoneID = SharedRecordMapper.zoneID(for: space, ownerName: "_owner-record-name")
        let entry = JournalEntryRecord(
            id: UUID(), kind: .prayer, title: "엄마 기도제목", body: "", occurredAt: .now,
            originalTimeZone: nil, tags: [], isStarred: false, isPinned: false,
            details: EntryDetails(prayerStatus: .ongoing), sourceUUID: nil, sourceMetadata: nil,
            currentRevisionID: UUID(), updatedAt: .now, modifiedByDeviceID: "device-mom")
        let record = CKRecord(
            recordType: SharedRecordType.entry,
            recordID: SharedRecordMapper.recordID(for: entry.id, in: zoneID))
        SharedRecordMapper.write(SharedEntryPayload(entry: entry, kind: kind), to: record)

        _ = store.applyFetched(record)

        XCTAssertEqual(store.spaces.map(\.id), [space.id])
        XCTAssertEqual(store.spaces.first?.role, .participant)
        XCTAssertTrue(store.ownedZoneIDs.isEmpty)
        XCTAssertEqual(try store.cache(for: space.id).entry(id: entry.id)?.title, "엄마 기도제목")
    }
}
#endif
