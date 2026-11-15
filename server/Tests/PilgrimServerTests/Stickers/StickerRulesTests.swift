import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

final class StickerRulesTests: XCTestCase {
    func testNamesAreTrimmedAndOptional() throws {
        XCTAssertNil(try StickerRules.normalizedName(nil))
        XCTAssertNil(try StickerRules.normalizedName(""))
        XCTAssertNil(try StickerRules.normalizedName("  \n "))
        XCTAssertEqual(try StickerRules.normalizedName("  기쁨 "), "기쁨")
        let twenty = String(repeating: "가", count: APILimits.stickerNameMax)
        XCTAssertEqual(try StickerRules.normalizedName(twenty), twenty)
        // Graphemes, not bytes or scalars.
        let flags = String(repeating: "🇰🇷", count: APILimits.stickerNameMax)
        XCTAssertEqual(try StickerRules.normalizedName(flags), flags)
    }

    func testRefusesLongAndMultilineNames() {
        let long = mediaThrownAPIError {
            _ = try StickerRules.normalizedName(String(repeating: "a", count: 21))
        }
        XCTAssertEqual(long?.code, .limitExceeded)
        XCTAssertEqual(long?.limit, APILimits.stickerNameMax)
        XCTAssertEqual(long?.field, "name")

        let multiline = mediaThrownAPIError { _ = try StickerRules.normalizedName("기쁨\n감사") }
        XCTAssertEqual(multiline?.code, .validationFailed)
        XCTAssertEqual(multiline?.field, "name")
    }
}
