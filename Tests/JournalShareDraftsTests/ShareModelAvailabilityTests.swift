import XCTest

@testable import JournalShareDrafts

final class ShareModelAvailabilityTests: XCTestCase {
    private func resolve(
        switchOn: Bool = true, osSupported: Bool = true, reason: ShareModelUnavailableReason? = nil
    ) -> ShareModelAvailability {
        .resolve(switchOn: switchOn, osSupported: osSupported, reason: reason)
    }

    func testSwitchOffWinsOverEverything() {
        XCTAssertEqual(resolve(switchOn: false, osSupported: false), .disabled)
    }

    func testUnsupportedOS() {
        XCTAssertEqual(resolve(osSupported: false), .unsupportedOS)
    }

    func testAvailableWithoutReason() {
        XCTAssertEqual(resolve(), .available)
    }

    func testDeviceNotEligible() {
        XCTAssertEqual(resolve(reason: .deviceNotEligible), .deviceNotEligible)
    }

    func testAppleIntelligenceNotEnabled() {
        XCTAssertEqual(resolve(reason: .appleIntelligenceNotEnabled), .appleIntelligenceOff)
    }

    func testModelNotReadyAndUnknownReasons() {
        XCTAssertEqual(resolve(reason: .modelNotReady), .modelNotReady)
        XCTAssertEqual(resolve(reason: .other), .modelNotReady)
    }
}
