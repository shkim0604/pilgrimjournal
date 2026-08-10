#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
@testable import PilgrimJournal
import XCTest

@MainActor
final class JournalSessionControllerTests: XCTestCase {
    func testLocalRecordsRequireConfirmationBeforeMovingToICloud() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "journal-session-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let root = parent.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        var location = JournalStorageLocation.localOnly
        let controller = JournalSessionController(
            rootURL: root,
            cloudKitContainerIdentifier: nil,
            storageLocationProvider: { location }
        )

        await controller.activate(appleUserIdentifier: "apple-user")
        let localModel = try XCTUnwrap(controller.appModel)
        let original = try localModel.repository.save(
            JournalEntryDraft(kind: .memo, title: "로컬 기록"),
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 10)
        )
        let localRoot = localModel.paths.root

        location = .iCloud(accountHash: "icloud-account-a")
        await controller.activate(
            appleUserIdentifier: "apple-user",
            forceRefresh: true
        )

        let pending = try XCTUnwrap(controller.pendingMigration)
        XCTAssertEqual(pending.entryCount, 1)
        XCTAssertEqual(controller.activeScope?.storageLocation, .localOnly)
        XCTAssertEqual(controller.appModel?.paths.root, localRoot)
        XCTAssertEqual(controller.appModel?.entries.first?.id, original.id)

        let result = try XCTUnwrap(controller.confirmPendingMigration())
        XCTAssertEqual(result.migratedEntries, 1)
        XCTAssertEqual(
            controller.activeScope?.storageLocation,
            .iCloud(accountHash: "icloud-account-a")
        )
        XCTAssertNotEqual(controller.appModel?.paths.root, localRoot)
        XCTAssertEqual(controller.appModel?.entries.first?.id, original.id)
        XCTAssertNil(controller.pendingMigration)
    }

    func testICloudAccountChangeNeverOpensPreviousCloudStore() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "journal-account-change-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let root = parent.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        var location = JournalStorageLocation.localOnly
        let controller = JournalSessionController(
            rootURL: root,
            cloudKitContainerIdentifier: nil,
            storageLocationProvider: { location }
        )

        await controller.activate(appleUserIdentifier: "apple-user")
        let original = try XCTUnwrap(controller.appModel).repository
        let record = try original.save(
            JournalEntryDraft(kind: .diary, title: "계정 A 기록"),
            deviceID: "Mac",
            at: Date(timeIntervalSince1970: 10)
        )
        location = .iCloud(accountHash: "icloud-account-a")
        await controller.activate(
            appleUserIdentifier: "apple-user",
            forceRefresh: true
        )
        XCTAssertNotNil(controller.confirmPendingMigration())
        let firstCloudRoot = try XCTUnwrap(controller.appModel).paths.root
        XCTAssertEqual(controller.appModel?.entries.first?.id, record.id)

        location = .iCloud(accountHash: "icloud-account-b")
        await controller.activate(
            appleUserIdentifier: "apple-user",
            forceRefresh: true
        )

        let pending = try XCTUnwrap(controller.pendingMigration)
        XCTAssertEqual(
            pending.destination.storageLocation,
            .iCloud(accountHash: "icloud-account-b")
        )
        XCTAssertEqual(controller.activeScope?.storageLocation, .localOnly)
        XCTAssertNotEqual(controller.appModel?.paths.root, firstCloudRoot)

        location = .iCloud(accountHash: "icloud-account-a")
        await controller.activate(
            appleUserIdentifier: "apple-user",
            forceRefresh: true
        )
        XCTAssertNil(controller.pendingMigration)
        XCTAssertEqual(controller.appModel?.paths.root, firstCloudRoot)
        XCTAssertEqual(controller.appModel?.entries.first?.id, record.id)
    }

    func testDeactivationDropsTheOpenAccountModel() async {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "journal-deactivate-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let root = parent.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: parent) }
        let controller = JournalSessionController(
            rootURL: root,
            cloudKitContainerIdentifier: nil
        )

        await controller.activate(appleUserIdentifier: "apple-user")
        XCTAssertNotNil(controller.appModel)

        controller.deactivate()

        XCTAssertNil(controller.appModel)
        XCTAssertNil(controller.activeScope)
        XCTAssertNil(controller.pendingMigration)
    }
}
#endif
