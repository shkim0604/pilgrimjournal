import Foundation
import XCTest

@testable import PilgrimJournal

/// Uses a throwaway code; the real one must never appear in this public
/// repository, only its salted key in `PremiumCode.production`.
@MainActor
final class PremiumCodeTests: XCTestCase {
    private static let testSalt = Data((0..<16).map { UInt8($0) })

    private func makeCode(_ value: String = "open-sesame") throws -> PremiumCode {
        let key = try XCTUnwrap(
            PremiumCode.derive(value, salt: Self.testSalt, iterations: 1_000, length: 32))
        return PremiumCode(salt: Self.testSalt, iterations: 1_000, derivedKey: key)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "PremiumCodeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testMatchesIgnoringCaseAndSurroundingSpaces() throws {
        let code = try makeCode()
        XCTAssertTrue(code.matches("open-sesame"))
        XCTAssertTrue(code.matches("  Open-Sesame\n"))
        XCTAssertFalse(code.matches("open sesame"))
        XCTAssertFalse(code.matches(""))
    }

    func testProductionCodeIsAStretchedKey() {
        XCTAssertEqual(PremiumCode.production.derivedKey.count, 32)
        XCTAssertGreaterThanOrEqual(PremiumCode.production.iterations, 100_000)
        XCTAssertEqual(PremiumCode.production.salt.count, 16)
        XCTAssertFalse(PremiumCode.production.matches("open-sesame"))
    }

    func testLockedUntilTheRightCodeIsEnteredAndRemembered() async throws {
        let defaults = makeDefaults()
        let access = PremiumCodeFeatureAccess(defaults: defaults, code: try makeCode())
        XCTAssertFalse(access.canManageKinds)
        XCTAssertFalse(access.isPremium)

        let wrong = await access.redeem(code: "guess")
        XCTAssertFalse(wrong)
        XCTAssertFalse(access.canManageKinds)

        let right = await access.redeem(code: "OPEN-SESAME")
        XCTAssertTrue(right)
        XCTAssertTrue(access.canManageKinds)

        let reopened = PremiumCodeFeatureAccess(defaults: defaults, code: try makeCode())
        XCTAssertTrue(reopened.isPremium)
    }

    // The production key is derived offline with Python's
    // hashlib.pbkdf2_hmac; this standard PBKDF2-HMAC-SHA256 vector pins that
    // CommonCrypto computes the same thing.
    func testDerivationMatchesTheStandardPBKDF2Vector() throws {
        let key = try XCTUnwrap(
            PremiumCode.derive("password", salt: Data("salt".utf8), iterations: 1, length: 32))
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }
}
