import Foundation
import XCTest

@testable import PilgrimJournal

final class AppLanguageTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return (defaults, name)
    }

    func testFollowsTheSystemUntilALanguageIsChosen() {
        let (defaults, name) = makeDefaults()
        XCTAssertEqual(AppLanguage.current(in: defaults, domainName: name), .system)
    }

    func testChoosingALanguageStoresItWhereTheSystemSettingDoes() {
        let (defaults, name) = makeDefaults()
        AppLanguage.english.apply(to: defaults)
        XCTAssertEqual(
            defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String], ["en"])
        XCTAssertEqual(AppLanguage.current(in: defaults, domainName: name), .english)

        AppLanguage.korean.apply(to: defaults)
        XCTAssertEqual(AppLanguage.current(in: defaults, domainName: name), .korean)
    }

    // iOS's per-app language page writes region-qualified codes such as
    // "en-US"; they must still show as the matching option.
    func testReadsRegionQualifiedCodesFromTheSystemSetting() {
        let (defaults, name) = makeDefaults()
        defaults.set(["en-US"], forKey: "AppleLanguages")
        XCTAssertEqual(AppLanguage.current(in: defaults, domainName: name), .english)
    }

    func testChoosingSystemRemovesTheOverride() {
        let (defaults, name) = makeDefaults()
        AppLanguage.english.apply(to: defaults)
        AppLanguage.system.apply(to: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
        XCTAssertEqual(AppLanguage.current(in: defaults, domainName: name), .system)
    }
}
