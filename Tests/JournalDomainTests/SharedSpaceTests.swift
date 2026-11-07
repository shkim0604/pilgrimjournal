#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class SharedSpaceTests: XCTestCase {
    func testZoneNameRoundTripsToTheSpaceID() {
        let space = SharedSpaceRecord(scope: .notebook, name: "우리집 기도제목", role: .owner)

        XCTAssertTrue(space.zoneName.hasPrefix(SharedSpaceRecord.zoneNamePrefix))
        XCTAssertEqual(SharedSpaceRecord.id(fromZoneName: space.zoneName), space.id)
    }

    func testCoreDataAndUnknownZonesAreNotSharedSpaces() {
        XCTAssertNil(SharedSpaceRecord.id(fromZoneName: "com.apple.coredata.cloudkit.zone"))
        XCTAssertNil(SharedSpaceRecord.id(fromZoneName: "pilgrim-share-not-a-uuid"))
    }

    func testKindSnapshotCopiesTheDefinitionsLook() {
        let definition = KindDefinition(
            kind: .prayer,
            name: "기도노트",
            colorToken: .amber,
            iconToken: "hands.sparkles",
            order: 0,
            state: .active,
            updatedAt: .now,
            modifiedByDeviceID: "device"
        )

        XCTAssertEqual(
            SharedKindSnapshot(definition),
            SharedKindSnapshot(
                kind: .prayer, name: "기도노트", colorToken: .amber, iconToken: "hands.sparkles")
        )
    }
}
#endif
