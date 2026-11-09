#if canImport(XCTest)
import Foundation
import CloudKit
import DayOneImport
import JournalData
import JournalDomain
import JournalSearch
@testable import PilgrimJournal
import XCTest

extension AppModelNavigationTests {
    func testCloudSyncErrorRevealsMissingProductionSchema() {
        let nested = NSError(
            domain: CKErrorDomain,
            code: CKError.invalidArguments.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create new type CD_JournalEntryEntity in production schema"
            ]
        )
        let error = NSError(
            domain: CKErrorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: ["record": nested]
            ]
        )

        XCTAssertEqual(
            cloudSyncErrorPresentation(for: error),
            CloudSyncErrorPresentation(
                message: "CloudKit 프로덕션 스키마가 아직 배포되지 않았습니다.",
                retryable: false
            )
        )
    }

    @MainActor
    func testCloudSyncEventsExposeCompletionAndRefreshImportedRecords() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-cloud-events-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "cloud-events.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )
        let completedAt = Date(timeIntervalSince1970: 123)

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: nil,
                succeeded: false,
                errorDescription: nil
            ))
        XCTAssertEqual(model.syncState, .pending)

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: completedAt,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.syncState, .synced(completedAt))

        let remoteRecord = try repository.save(
            JournalEntryDraft(kind: .diary, title: "다른 기기 기록"),
            deviceID: "remote-device",
            at: completedAt
        )
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .importing,
                completedAt: completedAt,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.entries.map(\.id), [remoteRecord.id])

        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: completedAt,
                succeeded: false,
                errorDescription: "네트워크 오류"
            ))
        XCTAssertEqual(
            model.syncState,
            .failed(message: "네트워크 오류", retryable: true)
        )
    }

    @MainActor
    func testAccountCheckWithoutCloudReportsLocalOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-manual-sync-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let repository = InMemoryJournalRepository()
        let model = try AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "manual-sync.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: nil
        )
        await model.refreshCloudAccountState()

        XCTAssertEqual(model.syncState, .localOnly)
    }

    @MainActor
    func testAccountCheckDoesNotDemoteACompletedSync() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-sync-state-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = JournalPaths(root: root)
        try paths.prepare()
        let model = try AppModel(
            repository: InMemoryJournalRepository(),
            importStore: InMemoryImportStore(),
            searchIndex: JournalSearchIndex(
                url: paths.search.appending(path: "sync-state.sqlite")
            ),
            paths: paths,
            cloudAccountMonitor: CloudAccountMonitor(
                containerIdentifier: "iCloud.test.PilgrimJournal"
            )
        )
        let completedAt = Date(timeIntervalSince1970: 500)
        model.handleCloudSyncStoreEvent(
            CloudSyncStoreEvent(
                operation: .exporting,
                completedAt: completedAt,
                succeeded: true,
                errorDescription: nil
            ))
        XCTAssertEqual(model.syncState, .synced(completedAt))

        // A healthy account reports no problem, so the completed sync stands.
        // Reporting "pending" here used to strand the UI on 동기화 대기.
        model.applyCloudAccountProblem(nil)

        XCTAssertEqual(model.syncState, .synced(completedAt))
    }
}

#endif
