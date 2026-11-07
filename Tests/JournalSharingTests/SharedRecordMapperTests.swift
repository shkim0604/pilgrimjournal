#if canImport(XCTest)
import CloudKit
import Foundation
import JournalDomain
import JournalSharing
import XCTest

final class SharedRecordMapperTests: XCTestCase {
    private let space = SharedSpaceRecord(scope: .notebook, name: "우리집 기도제목", role: .owner)
    private let kind = SharedKindSnapshot(
        kind: .prayer, name: "기도노트", colorToken: .amber, iconToken: "hands.sparkles")

    private func makeEntry() -> JournalEntryRecord {
        JournalEntryRecord(
            id: UUID(),
            kind: .prayer,
            title: "11월 기도제목",
            body: "1. 아빠 건강\n2. 동생 수능",
            occurredAt: Date(timeIntervalSince1970: 1_000),
            originalTimeZone: "Asia/Seoul",
            tags: ["가족", "기도"],
            isStarred: true,
            isPinned: false,
            details: EntryDetails(prayerStatus: .ongoing),
            sourceUUID: "DAYONE-UUID",
            sourceMetadata: Data("day one metadata".utf8),
            currentRevisionID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            modifiedByDeviceID: "device-a"
        )
    }

    func testEntryRoundTripsThroughARecordWithoutDayOneSourceData() throws {
        let entry = makeEntry()
        let zoneID = SharedRecordMapper.zoneID(for: space)
        let record = CKRecord(
            recordType: SharedRecordType.entry,
            recordID: SharedRecordMapper.recordID(for: entry.id, in: zoneID)
        )

        SharedRecordMapper.write(SharedEntryPayload(entry: entry, kind: kind), to: record)
        let decoded = try SharedRecordMapper.entryPayload(from: record)

        var expected = entry
        expected.sourceUUID = nil
        expected.sourceMetadata = nil
        XCTAssertEqual(decoded, SharedEntryPayload(entry: expected, kind: kind))
        XCTAssertEqual(record.recordID.zoneID.zoneName, space.zoneName)
    }

    func testContentFieldsAreEncrypted() {
        let record = CKRecord(recordType: SharedRecordType.entry)
        SharedRecordMapper.write(SharedEntryPayload(entry: makeEntry(), kind: kind), to: record)

        XCTAssertNil(record["title"])
        XCTAssertNil(record["body"])
        XCTAssertEqual(record.encryptedValues["title"] as? String, "11월 기도제목")
        XCTAssertEqual(record.encryptedValues["body"] as? String, "1. 아빠 건강\n2. 동생 수능")
    }

    func testDeletedEntryKeepsItsDeletionDate() throws {
        var entry = makeEntry()
        entry.deletedAt = Date(timeIntervalSince1970: 3_000)
        let record = CKRecord(recordType: SharedRecordType.entry)

        SharedRecordMapper.write(SharedEntryPayload(entry: entry, kind: kind), to: record)

        XCTAssertEqual(
            try SharedRecordMapper.entryPayload(from: record).entry.deletedAt, entry.deletedAt)
    }

    func testRecordMissingAFieldFailsToDecode() {
        let record = CKRecord(recordType: SharedRecordType.entry)
        XCTAssertThrowsError(try SharedRecordMapper.entryPayload(from: record)) { error in
            XCTAssertEqual(error as? SharedRecordError, .missingField("kind"))
        }
    }

    func testRevisionRoundTripsThroughARecord() throws {
        let entry = makeEntry()
        let revision = EntryRevisionRecord(
            entryID: entry.id,
            parentRevisionID: UUID(),
            snapshot: entry.draft,
            createdAt: Date(timeIntervalSince1970: 2_000),
            deviceID: "device-a"
        )
        let record = CKRecord(
            recordType: SharedRecordType.revision,
            recordID: SharedRecordMapper.recordID(
                for: revision.id, in: SharedRecordMapper.zoneID(for: space))
        )

        try SharedRecordMapper.write(revision, to: record)
        let decoded = try SharedRecordMapper.revision(from: record)

        var expected = revision
        expected.snapshot.sourceUUID = nil
        expected.snapshot.sourceMetadata = nil
        XCTAssertEqual(decoded, expected)
    }
}
#endif
