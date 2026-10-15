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

    func testCustomKindAlwaysShowsItsOwnName() {
        var definition = KindCatalog.unknownDefinition(for: .custom())
        definition.name = "QT"
        XCTAssertEqual(definition.displayName, "QT")
    }
}
