#if canImport(XCTest)
@testable import PilgrimJournal
import XCTest

final class AppUsageGuideContentTests: XCTestCase {
    func testCommonGuideCoversRequiredTopics() {
        let sections = AppUsageGuideContent.sections(for: .iOS)
        let sectionIDs = Set(sections.map(\.id))
        let itemIDs = Set(sections.flatMap(\.items).map(\.id))

        XCTAssertEqual(
            sectionIDs,
            ["getting-started", "organize-and-find", "sync", "security"]
        )
        XCTAssertTrue(
            [
                "create-entry",
                "entry-types",
                "edit-entry",
                "organize",
                "search",
                "trash",
                "apple-and-icloud",
                "local-first",
                "app-lock",
                "app-lock-boundary",
            ].allSatisfy(itemIDs.contains)
        )
        XCTAssertTrue(
            sections
                .flatMap(\.items)
                .allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty }
        )
    }

    func testMacGuideAddsMacOnlyDataManagement() {
        let sections = AppUsageGuideContent.sections(for: .macOS)
        let macSection = sections.first { $0.id == "mac-data-management" }

        XCTAssertNotNil(macSection)
        XCTAssertEqual(
            Set(macSection?.items.map(\.id) ?? []),
            ["day-one-import", "backup", "restore"]
        )
    }

    func testIOSGuideDoesNotAdvertiseMacSettingsActions() {
        let sections = AppUsageGuideContent.sections(for: .iOS)
        let itemIDs = Set(sections.flatMap(\.items).map(\.id))

        XCTAssertFalse(sections.contains { $0.id == "mac-data-management" })
        XCTAssertTrue(itemIDs.isDisjoint(with: ["day-one-import", "backup", "restore"]))
    }
}
#endif
