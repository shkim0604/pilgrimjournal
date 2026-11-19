import JournalDomain
import XCTest

@testable import PilgrimJournal

final class KindDisplayNameTests: XCTestCase {
    func testUntouchedBuiltInShowsItsDefaultInTheAppLanguage() {
        let definition = KindCatalog.defaultDefinition(for: .prayer)
        XCTAssertEqual(definition.displayName, BuiltInKind.prayer.localizedDefaultName)
    }

    func testRenamedBuiltInShowsTheUsersName() {
        var definition = KindCatalog.defaultDefinition(for: .diary)
        definition.name = "감사 일기"
        XCTAssertEqual(definition.displayName, "감사 일기")
    }

    // Saving the editor without touching a built-in's translated name must
    // keep the Korean default in the synced catalog.
    func testKeepingTheTranslatedDefaultStoresTheKoreanDefault() {
        let definition = KindCatalog.defaultDefinition(for: .reading)
        XCTAssertEqual(
            definition.storedName(for: BuiltInKind.reading.localizedDefaultName),
            BuiltInKind.reading.defaultName)
        XCTAssertEqual(definition.storedName(for: "책 메모"), "책 메모")
    }

    func testScrapShowsItsDefaultAndAlternateNamesInTheAppLanguage() {
        var definition = KindCatalog.defaultDefinition(for: .scrap)
        XCTAssertEqual(definition.displayName, BuiltInKind.scrap.localizedDefaultName)
        definition.name = KindCatalog.scrapAlternateName
        XCTAssertEqual(definition.displayName, String(localized: "그룹 스크랩"))
        XCTAssertEqual(
            definition.storedName(for: String(localized: "그룹 스크랩")),
            KindCatalog.scrapAlternateName)
        XCTAssertEqual(
            definition.storedName(for: BuiltInKind.scrap.localizedDefaultName), "스크랩")
        definition.name = "모임 글"
        XCTAssertEqual(definition.displayName, "모임 글")
        // Only scrap has an alternate name.
        var memo = KindCatalog.defaultDefinition(for: .memo)
        memo.name = KindCatalog.scrapAlternateName
        XCTAssertEqual(memo.displayName, KindCatalog.scrapAlternateName)
    }

    func testScrapNotebookShowsItsFirstWordInTheAppLanguage() {
        let scrap = BuiltInKind.scrap.localizedDefaultName
        XCTAssertEqual(NotebookDisplayName.displayName("스크랩"), scrap)
        XCTAssertEqual(
            NotebookDisplayName.displayName(ScrapComposer.notebookName(groupName: "수요 기도모임")),
            "\(scrap) · 수요 기도모임")
        XCTAssertEqual(
            NotebookDisplayName.displayName("스크랩 · Wednesday prayer"),
            "\(scrap) · Wednesday prayer")
        for own in ["스크랩북", "스크랩·붙임", "내 스크랩 · 모음", "QT"] {
            XCTAssertEqual(NotebookDisplayName.displayName(own), own)
        }
    }

    func testCustomKindAlwaysShowsItsOwnName() {
        var definition = KindCatalog.unknownDefinition(for: .custom())
        definition.name = "QT"
        XCTAssertEqual(definition.displayName, "QT")
    }
}
