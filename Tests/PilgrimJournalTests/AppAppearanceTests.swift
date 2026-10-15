#if canImport(XCTest)
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
@testable import PilgrimJournal
import XCTest

final class AppAppearanceTests: XCTestCase {
    func testFollowsTheSystemUntilTheUserChooses() {
        XCTAssertEqual(AppAppearance.defaultValue, .system)
    }

    func testOffersSystemLightAndDarkInThatOrder() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
        XCTAssertEqual(AppAppearance.allCases.map(\.title), ["시스템 설정", "라이트", "다크"])
    }

    // A value written by a newer build, or a corrupted one, must not leave the
    // app stuck in a mode the user can't see in the picker.
    func testUnknownStoredValueFallsBackToSystem() {
        XCTAssertEqual(AppAppearance(storedValue: "sepia"), .system)
        XCTAssertEqual(AppAppearance(storedValue: "dark"), .dark)
    }

    #if os(macOS)
    func testMapsToTheMacAppearanceNames() {
        XCTAssertNil(AppAppearance.system.appearanceName)
        XCTAssertEqual(AppAppearance.light.appearanceName, .aqua)
        XCTAssertEqual(AppAppearance.dark.appearanceName, .darkAqua)
    }
    #elseif os(iOS)
    func testMapsToTheIOSInterfaceStyles() {
        XCTAssertEqual(AppAppearance.system.interfaceStyle, .unspecified)
        XCTAssertEqual(AppAppearance.light.interfaceStyle, .light)
        XCTAssertEqual(AppAppearance.dark.interfaceStyle, .dark)
    }
    #endif
}
#endif
