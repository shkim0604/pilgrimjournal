#if canImport(XCTest)
import CloudKit
@testable import JournalData
import JournalDomain
import XCTest

final class CloudKitDataWiperTests: XCTestCase {
    func testAccountZonesAreEveryCustomZoneButNotTheDefaultZone() {
        let mirroring = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone")
        let owned = CKRecordZone.ID(zoneName: SharedSpaceRecord.zoneName(for: UUID()))
        let unknown = CKRecordZone.ID(zoneName: "some-future-zone")
        let defaultZone = CKRecordZone.default().zoneID

        let targets = CloudKitDataWiper.accountZoneIDs(
            in: [defaultZone, mirroring, owned, unknown]
        )

        XCTAssertEqual(Set(targets), [mirroring, owned, unknown])
    }

    func testAcceptedSharesAreTheZoneWideSharesOfFamilySpaces() {
        let spaceZone = CKRecordZone.ID(
            zoneName: SharedSpaceRecord.zoneName(for: UUID()),
            ownerName: "_owner-record-id"
        )
        let foreign = CKRecordZone.ID(zoneName: "not-a-space", ownerName: "_other")

        let shares = CloudKitDataWiper.acceptedShareIDs(in: [spaceZone, foreign])

        XCTAssertEqual(
            shares,
            [CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: spaceZone)]
        )
        XCTAssertEqual(shares.first?.zoneID.ownerName, "_owner-record-id")
    }

    func testItemsThatAreAlreadyGoneCountAsDeleted() {
        XCTAssertNoThrow(
            try CloudKitDataWiper.throwIfAnyFailed([
                ("a", .success(())),
                ("b", .failure(CKError(.zoneNotFound))),
                ("c", .failure(CKError(.unknownItem))),
                ("d", .failure(CKError(.userDeletedZone))),
            ])
        )
    }

    func testEveryFailedItemIsNamed() {
        XCTAssertThrowsError(
            try CloudKitDataWiper.throwIfAnyFailed([
                ("zone-b", .failure(CKError(.quotaExceeded))),
                ("zone-ok", .success(())),
                ("zone-a", .failure(CKError(.networkFailure))),
            ])
        ) { error in
            let wipeError = error as? CloudKitWipeError
            XCTAssertEqual(wipeError?.remaining, ["zone-a", "zone-b"])
            XCTAssertEqual(wipeError?.reason, CKError(.networkFailure).localizedDescription)
            XCTAssertTrue(wipeError?.errorDescription?.contains("2") == true)
        }
    }
}
#endif
