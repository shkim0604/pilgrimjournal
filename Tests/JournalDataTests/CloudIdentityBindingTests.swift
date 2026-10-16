#if canImport(XCTest)
@testable import JournalData
import XCTest

final class CloudIdentityBindingTests: XCTestCase {
    func testFirstAppleUserBindsEmptyPrivateDatabase() async {
        let store = InMemoryCloudIdentityBindingStore()
        let service = CloudIdentityBindingService(store: store)

        let result = await service.verifyOrBind(userIdentifier: "apple-user-a")

        XCTAssertEqual(result, .bound)
        let stored = await store.storedHash
        XCTAssertEqual(
            stored,
            CloudIdentityBindingService.subjectHash(for: "apple-user-a")
        )
    }

    func testSameAppleUserMatchesExistingPrivateDatabase() async {
        let hash = CloudIdentityBindingService.subjectHash(for: "apple-user-a")
        let store = InMemoryCloudIdentityBindingStore(storedHash: hash)
        let service = CloudIdentityBindingService(store: store)

        let result = await service.verifyOrBind(userIdentifier: "apple-user-a")

        XCTAssertEqual(result, .matched)
    }

    func testDifferentAppleUserCannotUseBoundPrivateDatabase() async {
        let hash = CloudIdentityBindingService.subjectHash(for: "apple-user-a")
        let store = InMemoryCloudIdentityBindingStore(storedHash: hash)
        let service = CloudIdentityBindingService(store: store)

        let result = await service.verifyOrBind(userIdentifier: "apple-user-b")

        XCTAssertEqual(result, .mismatch)
    }

    func testConcurrentFirstBindingKeepsExistingOwner() async {
        let ownerHash = CloudIdentityBindingService.subjectHash(
            for: "apple-user-a"
        )
        let store = InMemoryCloudIdentityBindingStore(storedHash: ownerHash)
        let service = CloudIdentityBindingService(store: store)

        let result = await service.verifyOrBind(userIdentifier: "apple-user-b")

        XCTAssertEqual(result, .mismatch)
        let stored = await store.storedHash
        XCTAssertEqual(stored, ownerHash)
    }
}

private actor InMemoryCloudIdentityBindingStore: CloudIdentityBindingStore {
    var storedHash: String?

    init(storedHash: String? = nil) {
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
