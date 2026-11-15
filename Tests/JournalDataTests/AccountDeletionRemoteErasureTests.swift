#if canImport(XCTest)
import Foundation
@testable import JournalData
import XCTest

/// The `RemoteAccountDataErasing` step (the group server): first in every scope, stops the
/// deletion when it fails, and runs again on every retry.
final class AccountDeletionRemoteErasureTests: XCTestCase {
    private var baseURL: URL!
    private var rootURL: URL!

    override func setUpWithError() throws {
        baseURL = FileManager.default.temporaryDirectory.appending(
            path: "AccountDeletionRemoteErasureTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        rootURL = baseURL.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseURL)
    }

    func testRemoteErasureRunsBeforeCloudAndLocalDeletion() async throws {
        let fixture = try await makeFixture(storageLocation: .iCloud(accountHash: "cloud-a"))
        let log = EventLog()
        let scopeRoot = fixture.scopeRoot
        let remote = RecordingRemoteEraser(log: log) {
            // Nothing is gone yet when the remote step runs.
            FileManager.default.fileExists(atPath: scopeRoot.path(percentEncoded: false))
        }
        let cloud = LoggingCloudEraser(log: log)
        let service = makeService(fixture: fixture, cloudEraser: cloud, remoteEraser: remote)

        try await service.deleteAccount(fixture.request) { log.append("close") }

        XCTAssertEqual(log.events, ["close", "remote:apple-user-a", "cloud:apple-user-a"])
        XCTAssertEqual(remote.sawLocalDataIntact, [true])
        XCTAssertFalse(exists(fixture.scopeRoot))
        XCTAssertNil(fixture.appLockStore.load())
    }

    func testRemoteFailureInICloudScopeDeletesNothing() async throws {
        let fixture = try await makeFixture(storageLocation: .iCloud(accountHash: "cloud-a"))
        let log = EventLog()
        let remote = RecordingRemoteEraser(log: log, error: StubError.offline)
        let cloud = LoggingCloudEraser(log: log)
        let service = makeService(fixture: fixture, cloudEraser: cloud, remoteEraser: remote)

        do {
            try await service.deleteAccount(fixture.request) {}
            XCTFail("그룹 서버 단계가 실패하면 멈춰야 합니다.")
        } catch let error as AccountDeletionError {
            guard case .remoteDeletionFailed = error else {
                return XCTFail("예상과 다른 오류: \(error)")
            }
            XCTAssertTrue(error.leavesLocalDataIntact)
            XCTAssertTrue(error.localizedDescription.contains("그룹 서버 계정을 지우지 못했어요"))
        }

        XCTAssertEqual(log.events, ["remote:apple-user-a"], "iCloud 단계가 실행되면 안 됩니다.")
        try await assertNothingDeleted(fixture)
    }

    func testRemoteFailureInLocalOnlyScopeDeletesNothing() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let remote = RecordingRemoteEraser(log: EventLog(), error: StubError.offline)
        let service = makeService(fixture: fixture, cloudEraser: nil, remoteEraser: remote)

        do {
            try await service.deleteAccount(fixture.request) {}
            XCTFail("그룹 서버 단계가 실패하면 멈춰야 합니다.")
        } catch {
            guard case .remoteDeletionFailed = error as? AccountDeletionError else {
                return XCTFail("예상과 다른 오류: \(error)")
            }
        }

        try await assertNothingDeleted(fixture)
    }

    func testRemoteErasureRunsInLocalOnlyScope() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let log = EventLog()
        let remote = RecordingRemoteEraser(log: log)
        let cloud = LoggingCloudEraser(log: log)
        let service = makeService(fixture: fixture, cloudEraser: cloud, remoteEraser: remote)

        try await service.deleteAccount(fixture.request) {}

        XCTAssertEqual(log.events, ["remote:apple-user-a"])
        XCTAssertFalse(exists(fixture.scopeRoot))
    }

    func testRetryAfterFailureRunsRemoteStepAgain() async throws {
        let fixture = try await makeFixture(storageLocation: .iCloud(accountHash: "cloud-a"))
        let log = EventLog()
        let remote = RecordingRemoteEraser(log: log)
        let cloud = LoggingCloudEraser(log: log, failures: 1)
        let service = makeService(fixture: fixture, cloudEraser: cloud, remoteEraser: remote)

        do {
            try await service.deleteAccount(fixture.request) {}
            XCTFail("iCloud 단계가 한 번 실패해야 합니다.")
        } catch {
            XCTAssertTrue((error as? AccountDeletionError)?.leavesLocalDataIntact == true)
        }
        try await service.deleteAccount(fixture.request) {}

        XCTAssertEqual(
            log.events,
            [
                "remote:apple-user-a", "cloud-failed", "remote:apple-user-a",
                "cloud:apple-user-a",
            ])
        XCTAssertFalse(exists(fixture.scopeRoot))
    }

    func testDeletionErrorFromRemoteStepPassesThrough() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let remote = RecordingRemoteEraser(
            log: EventLog(), error: AccountDeletionError.invalidUserIdentifier)
        let service = makeService(fixture: fixture, cloudEraser: nil, remoteEraser: remote)

        do {
            try await service.deleteAccount(fixture.request) {}
            XCTFail("실패해야 합니다.")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .invalidUserIdentifier)
        }
        XCTAssertTrue(exists(fixture.scopeRoot))
    }

    func testInvalidIdentifierNeverReachesRemoteStep() async throws {
        let fixture = try await makeFixture(storageLocation: .localOnly)
        let log = EventLog()
        let service = makeService(
            fixture: fixture, cloudEraser: nil, remoteEraser: RecordingRemoteEraser(log: log))

        do {
            try await service.deleteAccount(
                AccountDeletionRequest(appleUserIdentifier: " ", storageLocation: .localOnly)
            ) {}
            XCTFail("빈 식별자는 거부해야 합니다.")
        } catch {
            XCTAssertEqual(error as? AccountDeletionError, .invalidUserIdentifier)
        }
        XCTAssertTrue(log.events.isEmpty)
    }

    // MARK: - Helpers

    private struct Fixture {
        var scopeRoot: URL
        var request: AccountDeletionRequest
        var sessionService: AppleAuthenticationSessionService
        var appLockStore: InMemorySecureValueStore
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
            scopeRoot: paths.root,
            request: AccountDeletionRequest(
                appleUserIdentifier: "apple-user-a",
                storageLocation: storageLocation
            ),
            sessionService: sessionService,
            appLockStore: appLockStore
        )
    }

    private func makeService(
        fixture: Fixture,
        cloudEraser: (any CloudAccountDataErasing)?,
        remoteEraser: (any RemoteAccountDataErasing)?
    ) -> AccountDeletionService {
        let root: URL = rootURL
        return AccountDeletionService(
            rootURLProvider: { root },
            cloudEraser: cloudEraser,
            remoteEraser: remoteEraser,
            sessionService: fixture.sessionService,
            appLockStore: fixture.appLockStore,
            preferences: SilentPreferences()
        )
    }

    private func assertNothingDeleted(
        _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertTrue(exists(fixture.scopeRoot), file: file, line: line)
        XCTAssertTrue(
            exists(fixture.scopeRoot.appending(path: "scope.json")), file: file, line: line)
        XCTAssertNotNil(fixture.appLockStore.load(), file: file, line: line)
        let session = try await fixture.sessionService.session()
        XCTAssertEqual(session.currentUserIdentifier, "apple-user-a", file: file, line: line)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

private enum StubError: Error {
    case offline
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var events: [String] { lock.withLock { recorded } }

    func append(_ event: String) {
        lock.withLock { recorded.append(event) }
    }
}

private final class RecordingRemoteEraser: RemoteAccountDataErasing, @unchecked Sendable {
    private let lock = NSLock()
    private let log: EventLog
    private let error: Error?
    private let probe: @Sendable () -> Bool
    private var probes: [Bool] = []

    init(log: EventLog, error: Error? = nil, probe: @escaping @Sendable () -> Bool = { true }) {
        self.log = log
        self.error = error
        self.probe = probe
    }

    var sawLocalDataIntact: [Bool] { lock.withLock { probes } }

    func eraseRemoteData(appleUserIdentifier: String) async throws {
        let intact = probe()
        lock.withLock { probes.append(intact) }
        log.append("remote:\(appleUserIdentifier)")
        if let error { throw error }
    }
}

private final class LoggingCloudEraser: CloudAccountDataErasing, @unchecked Sendable {
    private let lock = NSLock()
    private let log: EventLog
    private var remainingFailures: Int

    init(log: EventLog, failures: Int = 0) {
        self.log = log
        self.remainingFailures = failures
    }

    func eraseCloudData(appleUserIdentifier: String) async throws {
        let fails = lock.withLock {
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        if fails {
            log.append("cloud-failed")
            throw StubError.offline
        }
        log.append("cloud:\(appleUserIdentifier)")
    }
}

private struct SilentPreferences: AccountPreferencesClearing {
    func removeSuite(named suiteName: String) {}
    func removeStandardValues(forKeys keys: [String]) {}
    func removeCloudValues(forKeys keys: [String]) {}
}
#endif
