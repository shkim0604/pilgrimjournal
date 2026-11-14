import XCTest

@testable import JournalShareDrafts

final class PrayerRequestShareTextTests: XCTestCase {
    private func drafts(_ texts: [String]) -> [PrayerRequestDraft] {
        texts.map { PrayerRequestDraft(text: $0, language: .korean, topic: .health, who: "나") }
    }

    func testOneDraftIsTheSentenceAlone() {
        XCTAssertEqual(PrayerRequestShareText.text(for: drafts(["a하도록"])), "a하도록")
    }

    func testSeveralDraftsGetBullets() {
        XCTAssertEqual(PrayerRequestShareText.text(for: drafts(["a", "b", "c"])), "• a\n• b\n• c")
    }

    func testBlankDraftsAreLeftOut() {
        XCTAssertEqual(
            PrayerRequestShareText.text(for: drafts(["a", "", "  \n", "b"])), "• a\n• b")
        XCTAssertEqual(PrayerRequestShareText.text(for: drafts(["", " "])), "")
        XCTAssertEqual(PrayerRequestShareText.text(for: []), "")
    }
}
