#if canImport(Translation)
import Foundation
import Translation
import XCTest

@testable import PilgrimJournal

/// `translationTask` re-runs only when its configuration changes; these pin down that every new
/// job, a retry of the same pair included, hands it a configuration different from the last one.
final class PrayerRequestTranslationTriggerTests: XCTestCase {
    private let korean = Locale.Language(identifier: "ko")
    private let english = Locale.Language(identifier: "en")

    func testFreshConfigurationsForTheSamePairCompareEqual() throws {
        guard #available(iOS 18, macOS 15, *) else { throw XCTSkip("Translation needs iOS 18") }
        // The reason a retry cannot just build a new configuration.
        XCTAssertEqual(
            TranslationSession.Configuration(source: korean, target: english),
            TranslationSession.Configuration(source: korean, target: english))
    }

    func testFirstJobGetsAConfigurationForItsPair() throws {
        guard #available(iOS 18, macOS 15, *) else { throw XCTSkip("Translation needs iOS 18") }
        let next = PrayerRequestTranslationTrigger.configuration(
            after: nil, source: korean, target: english)
        XCTAssertEqual(next.source, korean)
        XCTAssertEqual(next.target, english)
    }

    func testRetryOfTheSamePairChangesTheConfiguration() throws {
        guard #available(iOS 18, macOS 15, *) else { throw XCTSkip("Translation needs iOS 18") }
        let first = PrayerRequestTranslationTrigger.configuration(
            after: nil, source: korean, target: english)
        let retry = PrayerRequestTranslationTrigger.configuration(
            after: first, source: korean, target: english)
        XCTAssertNotEqual(retry, first)
        XCTAssertEqual(retry.source, korean)
        XCTAssertEqual(retry.target, english)

        let again = PrayerRequestTranslationTrigger.configuration(
            after: retry, source: korean, target: english)
        XCTAssertNotEqual(again, retry)
    }

    func testOtherPairGetsItsOwnConfiguration() throws {
        guard #available(iOS 18, macOS 15, *) else { throw XCTSkip("Translation needs iOS 18") }
        let first = PrayerRequestTranslationTrigger.configuration(
            after: nil, source: korean, target: english)
        let back = PrayerRequestTranslationTrigger.configuration(
            after: first, source: english, target: korean)
        XCTAssertNotEqual(back, first)
        XCTAssertEqual(back.source, english)
        XCTAssertEqual(back.target, korean)
    }
}
#endif
