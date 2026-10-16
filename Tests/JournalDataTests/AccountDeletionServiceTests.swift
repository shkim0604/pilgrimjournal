#if canImport(XCTest)
import Foundation
@testable import JournalData
import XCTest

final class AccountDeletionServiceTests: XCTestCase {
    private var baseURL: URL!
    private var rootURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory.appending(
            path: "AccountDeletionServiceTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        rootURL = baseURL.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseURL)
    }

    func testCloudFailureLeavesLocalDataAndKeychainIntact() async throws {
        let fixture = try await makeFixture(storageLocation: .iCloud(accountHash: "cloud-a"))
        let cloud = RecordingCloudEraser(error: StubError.offline)
        let service = makeService(fixture: fixture, cloudEraser: cloud)

        do {
            try await service.deleteAccount(fixture.request) {}
            XCTFail("클라우드 단계가 실패하면 삭제를 멈춰야 합니다.")
        } catch let error as AccountDeletionError {
            guard case .cloudDeletionFailed = error else {
                return XCTFail("예상과 다른 오류: \(error)")
            }
            XCTAssertTrue(error.leavesLocalDataIntact)
        }

        XCTAssertTrue(exists(fixture.scopePaths.root))
        XCTAssertTrue(exists(fixture.scopePaths.root.appending(path: "scope.json")))
        let session = try await fixture.sessionService.session()
        XCTAssertEqual(session.currentUserIdentifier, "apple-user-a")
        XCTAssertNotNil(fixture.appLockStore.load())
        XCTAssertTrue(fixture.preferences.removedSuites.isEmpty)
        XCTAssertTrue(fixture.preferences.removedCloudKeys.isEmpty)
        XCTAssertTrue(fixture.preferences.removedStandardKeys.isEmpty)
    }

    func testDeletionRemovesOnlyThisUsersScopesAndClearsKeychainAndSuites() async throws {
        let fixture = try await makeFixture(storageLocation: .iCloud(accountHash: "cloud-a"))
        let localScope = JournalAccountScope(
            appleUserIdentifier: "apple-user-a",
            storageLocation: .localOnly
        )
        let registry = JournalAccountScopeRegistry(root: rootURL)
        _ = try registry.prepareScope(localScope)
        try registry.markMigrationCompleted(from: localScope, to: fixture.scope)
        let otherScope = JournalAccountScope(
            appleUserIdentifier: "apple-user-b",
            storageLocation: .localOnly
        )
        let otherPaths = try registry.prepareScope(otherScope)
        let preview = baseURL.appending(path: "AttachmentPreview", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        let cloud = RecordingCloudEraser()
        let service = makeService(
            fixture: fixture,
            cloudEraser: cloud,
            temporaryItems: [preview]
        )
        let closed = CallRecorder()

        try await service.deleteAccount(fixture.request) {
            await closed.record("close")
        }

        let closeCalls = await closed.calls
        XCTAssertEqual(closeCalls, ["close"])
        XCTAssertEqual(cloud.erasedIdentifiers, ["apple-user-a"])
        XCTAssertFalse(
            exists(registry.accountDirectory(appleUserHash: fixture.scope.appleUserHash))
        )
        XCTAssertFalse(
            exists(registry.bookkeepingDirectory(appleUserHash: fixture.scope.appleUserHash))
        )
        XCTAssertFalse(exists(preview))
        XCTAssertTrue(exists(otherPaths.root.appending(path: "scope.json")))

        XCTAssertNil(fixture.appLockStore.load())
        let session = try await fixture.sessionService.session()
        XCTAssertEqual(session, AppleAuthenticationSession())
        XCTAssertEqual(
            Set(fixture.preferences.removedSuites),
            [localScope.userDefaultsSuiteName, fixture.scope.userDefaultsSuiteName]
        )
        XCTAssertEqual(fixture.preferences.removedCloudKeys, ["journal-notebooks"])
        XCTAssertEqual(fixture.preferences.removedStandardKeys, ["has-completed-onboarding"])
    }

    func testLocalOnlyScopeSkipsCloudStepAndKeyValueStore() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let cloud = RecordingCloudEraser()
        let service = makeService(fixture: fixture, cloudEraser: cloud)

        try await service.deleteAccount(fixture.request) {}

        XCTAssertTrue(cloud.erasedIdentifiers.isEmpty)
        XCTAssertTrue(fixture.preferences.removedCloudKeys.isEmpty)
        XCTAssertFalse(exists(fixture.scopePaths.root))
        let session = try await fixture.sessionService.session()
        XCTAssertNil(session.boundUserIdentifier)
    }

    func testLegacyStoreIsRemovedOnlyWhenThisUserClaimedIt() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let registry = JournalAccountScopeRegistry(root: rootURL)
        try registry.claimLegacyData(for: fixture.scope)
        let legacyStore = baseURL.appending(path: "Canonical.store")
        let legacyWAL = baseURL.appending(path: "Canonical.store-wal")
        let unrelated = baseURL.appending(path: "Unrelated.store")
        for url in [legacyStore, legacyWAL, unrelated] {
            try Data("x".utf8).write(to: url)
        }
        let service = makeService(fixture: fixture, cloudEraser: nil)

        try await service.deleteAccount(fixture.request) {}

        XCTAssertFalse(exists(legacyStore))
        XCTAssertFalse(exists(legacyWAL))
        XCTAssertTrue(exists(unrelated))
        // A different Apple user may now claim the (empty) legacy slot.
        let other = JournalAccountScope(
            appleUserIdentifier: "apple-user-b",
            storageLocation: .localOnly
        )
        XCTAssertNoThrow(try registry.verifyLegacyClaim(for: other))
    }

    func testLegacyStoreClaimedByAnotherUserSurvives() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let registry = JournalAccountScopeRegistry(root: rootURL)
        let other = JournalAccountScope(
            appleUserIdentifier: "apple-user-b",
            storageLocation: .localOnly
        )
        try registry.claimLegacyData(for: other)
        let legacyStore = baseURL.appending(path: "Canonical.store")
        try Data("x".utf8).write(to: legacyStore)
        let service = makeService(fixture: fixture, cloudEraser: nil)

        try await service.deleteAccount(fixture.request) {}

        XCTAssertTrue(exists(legacyStore))
        XCTAssertTrue(registry.isLegacyDataClaimed(byAppleUserHash: other.appleUserHash))
    }

    func testCloudEraserRefusesBindingOwnedByDifferentUser() async throws {
        let store = InMemoryBindingStore(
            storedHash: CloudIdentityBindingService.subjectHash(for: "apple-user-b")
        )
        let zones = CallRecorder()
        let eraser = CloudKitAccountDataEraser(bindingStore: store) {
            await zones.record("wipe")
            return []
        }

        do {
            try await eraser.eraseCloudData(appleUserIdentifier: "apple-user-a")
            XCTFail("다른 사용자에게 귀속된 iCloud는 지우면 안 됩니다.")
        } catch {
            XCTAssertEqual(
                error as? AccountDeletionError,
                .cloudAccountOwnedByDifferentUser
            )
        }
        let wipeCalls = await zones.calls
        XCTAssertTrue(wipeCalls.isEmpty)
        let storedHash = await store.storedHash
        XCTAssertNotNil(storedHash)
    }

    func testCloudEraserDeletesBindingBeforeZones() async throws {
        let store = InMemoryBindingStore(
            storedHash: CloudIdentityBindingService.subjectHash(for: "apple-user-a")
        )
        let order = CallRecorder()
        let eraser = CloudKitAccountDataEraser(bindingStore: store) {
            let hashAtWipe = await store.storedHash
            await order.record(hashAtWipe == nil ? "wipe-after-unbind" : "wipe-while-bound")
            return ["com.apple.coredata.cloudkit.zone"]
        }

        try await eraser.eraseCloudData(appleUserIdentifier: "apple-user-a")

        let calls = await order.calls
        XCTAssertEqual(calls, ["wipe-after-unbind"])
    }

    func testEmptyIdentifierDeletesNothing() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let service = makeService(fixture: fixture, cloudEraser: nil)
        let closed = CallRecorder()

        do {
            try await service.deleteAccount(
                AccountDeletionRequest(appleUserIdentifier: "  ", storageLocation: .localOnly)
            ) {
                await closed.record("close")
            }
            XCTFail("빈 식별자는 거부해야 합니다.")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .invalidUserIdentifier)
        }
        let closeCalls = await closed.calls
        XCTAssertTrue(closeCalls.isEmpty)
        XCTAssertTrue(exists(fixture.scopePaths.root))
    }

    func testSystemPreferencesRemoveSuiteDropsItsValues() {
        let suiteName = "PilgrimJournalTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(["노트"], forKey: "journal-notebooks")
        defer { defaults?.removePersistentDomain(forName: suiteName) }

        SystemAccountPreferences().removeSuite(named: suiteName)

        XCTAssertNil(UserDefaults(suiteName: suiteName)?.object(forKey: "journal-notebooks"))
    }

    // MARK: - Helpers

    private struct Fixture {
        var scope: JournalAccountScope
        var scopePaths: JournalPaths
        var request: AccountDeletionRequest
        var sessionService: AppleAuthenticationSessionService
        var appLockStore: InMemorySecureValueStore
        var preferences: RecordingPreferences
    }

    private func makeFixture(storageLocation: JournalStorageLocation) async throws -> Fixture {
        let scope = JournalAccountScope(
            appleUserIdentifier: "apple-user-a",
            storageLocation: storageLocation
        )
        let paths = try JournalAccountScopeRegistry(root: rootURL).prepareScope(scope)
        try Data("entry".utf8).write(to: paths.attachments.appending(path: "blob"))
        let sessionService = AppleAuthenticationSessionService(store: InMemorySecureValueStore())
        try await sessionService.acceptAuthorizedUser(identifier: "apple-user-a")
        let appLockStore = InMemorySecureValueStore()
        appLockStore.save(Data("lock".utf8))
        return Fixture(
            scope: scope,
            scopePaths: paths,
            request: AccountDeletionRequest(
                appleUserIdentifier: "apple-user-a",
                storageLocation: storageLocation
            ),
            sessionService: sessionService,
            appLockStore: appLockStore,
            preferences: RecordingPreferences()
        )
    }

    private func makeService(
        fixture: Fixture,
        cloudEraser: (any CloudAccountDataErasing)?,
        temporaryItems: [URL] = []
    ) -> AccountDeletionService {
        let root: URL = rootURL
        return AccountDeletionService(
            rootURLProvider: { root },
            cloudEraser: cloudEraser,
            sessionService: fixture.sessionService,
            appLockStore: fixture.appLockStore,
            preferences: fixture.preferences,
            standardDefaultsKeys: ["has-completed-onboarding"],
            cloudKeyValueKeys: ["journal-notebooks"],
            temporaryItems: temporaryItems
        )
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

private enum StubError: Error {
    case offline
}

private actor CallRecorder {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

private final class RecordingCloudEraser: CloudAccountDataErasing, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private var identifiers: [String] = []

    init(error: Error? = nil) {
        self.error = error
    }

    var erasedIdentifiers: [String] {
        lock.withLock { identifiers }
    }

    func eraseCloudData(appleUserIdentifier: String) async throws {
        if let error { throw error }
        lock.withLock { identifiers.append(appleUserIdentifier) }
    }
}

private final class RecordingPreferences: AccountPreferencesClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var suites: [String] = []
    private var standardKeys: [String] = []
    private var cloudKeys: [String] = []

    var removedSuites: [String] { lock.withLock { suites } }
    var removedStandardKeys: [String] { lock.withLock { standardKeys } }
    var removedCloudKeys: [String] { lock.withLock { cloudKeys } }

    func removeSuite(named suiteName: String) {
        lock.withLock { suites.append(suiteName) }
    }

    func removeStandardValues(forKeys keys: [String]) {
        lock.withLock { standardKeys.append(contentsOf: keys) }
    }

    func removeCloudValues(forKeys keys: [String]) {
        lock.withLock { cloudKeys.append(contentsOf: keys) }
    }
}

private actor InMemoryBindingStore: CloudIdentityBindingStore {
    var storedHash: String?

    init(storedHash: String?) {
        self.storedHash = storedHash
    }

    func loadSubjectHash() async throws -> String? {
        storedHash
    }

    func saveSubjectHashIfAbsent(_ subjectHash: String) async throws -> String {
        if let storedHash { return storedHash }
        storedHash = subjectHash
        return subjectHash
    }

    func deleteBinding() async throws {
        storedHash = nil
    }
}
#endif
