#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
@testable import PilgrimJournal
import XCTest

@MainActor
final class JournalSessionControllerTests: XCTestCase {
    func testUnresolvableRootIsReportedInsteadOfOpeningAStore() async {
        let controller = JournalSessionController(
            rootURLProvider: {
                throw NSError(
                    domain: "test",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Application Support 없음"]
                )
            },
            cloudKitContainerIdentifier: nil
        )

        await controller.activate(appleUserIdentifier: "apple-user")

        XCTAssertNil(controller.appModel)
        XCTAssertNil(controller.activeScope)
        XCTAssertTrue(controller.errorMessage?.contains("Application Support 없음") == true)
    }

    // The error screen's retry calls activate again; a root that resolves on
    // the second try must open the journal.
    func testRetryResolvesTheRootAgainAfterAFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "journal-retry-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var attempts = 0
        let controller = JournalSessionController(
            rootURLProvider: {
                attempts += 1
                // Fails at launch (init) and on the first activate, then recovers.
                if attempts <= 2 { throw CocoaError(.fileNoSuchFile) }
                return root
            },
            cloudKitContainerIdentifier: nil
        )

        await controller.activate(appleUserIdentifier: "apple-user")
        XCTAssertNil(controller.appModel)
        XCTAssertNotNil(controller.errorMessage)

        await controller.activate(appleUserIdentifier: "apple-user")
        XCTAssertNotNil(controller.appModel)
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(attempts, 3)
    }

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

    func testMigrationToICloudCarriesTheKindCatalog() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "journal-kind-migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let root = parent.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        // Each scope keeps its kind catalog in a named defaults suite; a
        // unique user keeps this test's suites from leaking into other runs.
        let appleUser = "kind-migration-\(UUID().uuidString)"
        var suites: [String] = []
        defer {
            try? FileManager.default.removeItem(at: parent)
            for suite in suites {
                UserDefaults().removePersistentDomain(forName: suite)
            }
        }
        func suiteName(_ scope: JournalAccountScope?) throws -> String {
            let scope = try XCTUnwrap(scope)
            return "PilgrimJournal.\(scope.appleUserHash).\(scope.storageLocation.directoryName)"
        }
        var location = JournalStorageLocation.localOnly
        let controller = JournalSessionController(
            rootURL: root,
            cloudKitContainerIdentifier: nil,
            storageLocationProvider: { location }
        )

        await controller.activate(appleUserIdentifier: appleUser)
        suites.append(try suiteName(controller.activeScope))
        let localModel = try XCTUnwrap(controller.appModel)
        let custom = try localModel.createKind(
            name: "설교노트", colorToken: .teal, iconToken: "star")
        try localModel.deleteKind(.prayer, moveTo: .memo)
        let entry = try localModel.repository.save(
            JournalEntryDraft(kind: custom, title: "주일 설교"),
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 10)
        )

        location = .iCloud(accountHash: "icloud-account-a")
        await controller.activate(appleUserIdentifier: appleUser, forceRefresh: true)
        suites.append(try suiteName(controller.pendingMigration?.destination))
        XCTAssertNotNil(controller.confirmPendingMigration())

        let cloudModel = try XCTUnwrap(controller.appModel)
        XCTAssertEqual(
            cloudModel.kindCatalog.creatableKinds.first { $0.kind == custom }?.name, "설교노트")
        XCTAssertFalse(cloudModel.kindCatalog.activeKinds.contains { $0.kind == .prayer })
        XCTAssertEqual(try cloudModel.repository.entry(id: entry.id)?.kind, custom)
        XCTAssertEqual(cloudModel.unknownKinds, [])
    }

    /// Deleting a kind with the default target leaves hand-written entries in
    /// 미분류; moving the local scope to iCloud must still carry them.
    func testMigrationCarriesManualEntriesMovedToUnclassified() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "journal-unclassified-migration-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let root = parent.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        let appleUser = "unclassified-migration-\(UUID().uuidString)"
        var suites: [String] = []
        defer {
            try? FileManager.default.removeItem(at: parent)
            for suite in suites {
                UserDefaults().removePersistentDomain(forName: suite)
            }
        }
        func suiteName(_ scope: JournalAccountScope?) throws -> String {
            let scope = try XCTUnwrap(scope)
            return "PilgrimJournal.\(scope.appleUserHash).\(scope.storageLocation.directoryName)"
        }
        var location = JournalStorageLocation.localOnly
        let controller = JournalSessionController(
            rootURL: root,
            cloudKitContainerIdentifier: nil,
            storageLocationProvider: { location }
        )

        await controller.activate(appleUserIdentifier: appleUser)
        suites.append(try suiteName(controller.activeScope))
        let localModel = try XCTUnwrap(controller.appModel)
        let entry = try localModel.repository.save(
            JournalEntryDraft(kind: .prayer, title: "손으로 쓴 기도"),
            deviceID: "iPhone",
            at: Date(timeIntervalSince1970: 10)
        )
        try localModel.deleteKind(.prayer, moveTo: .unclassified)
        XCTAssertEqual(try localModel.repository.entry(id: entry.id)?.kind, .unclassified)

        location = .iCloud(accountHash: "icloud-account-a")
        await controller.activate(appleUserIdentifier: appleUser, forceRefresh: true)
        suites.append(try suiteName(controller.pendingMigration?.destination))
        let result = try XCTUnwrap(controller.confirmPendingMigration())

        XCTAssertEqual(result.migratedEntries, 1)
        XCTAssertNil(controller.errorMessage)
        let cloudModel = try XCTUnwrap(controller.appModel)
        XCTAssertEqual(try cloudModel.repository.entry(id: entry.id)?.kind, .unclassified)
        XCTAssertEqual(try cloudModel.repository.entry(id: entry.id)?.title, "손으로 쓴 기도")
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
