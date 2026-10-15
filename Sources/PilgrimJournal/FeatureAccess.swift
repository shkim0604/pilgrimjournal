import CommonCrypto
import Foundation

/// The single gate for paid features. Every premium check goes through here.
@MainActor
protocol FeatureAccess: AnyObject {
    /// Creating, editing, reordering, deleting and restoring journal kinds.
    var canManageKinds: Bool { get }
    /// Whether this device has the paid features.
    var isPremium: Bool { get }
    /// Unlocks the paid features on this device when `code` is the premium
    /// code. Returns whether it was.
    func redeem(code: String) async -> Bool
}

extension FeatureAccess {
    var isPremium: Bool { canManageKinds }
    func redeem(code: String) async -> Bool { false }
}

/// Grants every feature. The default for tests.
@MainActor
final class UnlockedFeatureAccess: FeatureAccess {
    var canManageKinds: Bool { true }
}

/// Paid features stay locked until the premium code is entered on this
/// device; the unlock is remembered per device and not synced.
@MainActor
final class PremiumCodeFeatureAccess: FeatureAccess {
    static let unlockedKey = "premium-unlocked"
    static let simulateLockedKey = "debug-simulate-premium-locked"

    private let defaults: UserDefaults
    private let code: PremiumCode

    init(defaults: UserDefaults = .standard, code: PremiumCode = .production) {
        self.defaults = defaults
        self.code = code
    }

    var isPremium: Bool { defaults.bool(forKey: Self.unlockedKey) }

    var canManageKinds: Bool {
        #if DEBUG
        if defaults.bool(forKey: Self.simulateLockedKey) { return false }
        #endif
        return isPremium
    }

    func redeem(code input: String) async -> Bool {
        let code = self.code
        // Key stretching takes a noticeable moment; keep it off the main actor.
        let matches = await Task.detached(priority: .userInitiated) {
            code.matches(input)
        }.value
        if matches { defaults.set(true, forKey: Self.unlockedKey) }
        return matches
    }

    #if DEBUG
    func resetForTesting() {
        defaults.removeObject(forKey: Self.unlockedKey)
    }
    #endif
}

/// A premium code kept only as a salted PBKDF2-SHA256 key. The repository is
/// public, so the code itself must never appear in source, tests, commit
/// messages or pull requests; to change it, derive a new salt and key
/// locally (e.g. Python's `hashlib.pbkdf2_hmac`) and replace `.production`.
struct PremiumCode: Sendable {
    let salt: Data
    let iterations: Int
    let derivedKey: Data

    static let production = PremiumCode(
        salt: Data(hex: "cabe028eb76f5f45be64cd6f77ee11b4"),
        iterations: 300_000,
        derivedKey: Data(
            hex: "4e6c4a0e827611ae07cbd88b8dbd2a60affb7a671026f884a65d3d797be0bb55")
    )

    /// Codes are compared case-insensitively, ignoring surrounding spaces.
    static func normalized(_ input: String) -> String {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func matches(_ input: String) -> Bool {
        let normalized = Self.normalized(input)
        guard !normalized.isEmpty,
            let key = Self.derive(
                normalized, salt: salt, iterations: iterations,
                length: derivedKey.count)
        else { return false }
        return Self.constantTimeEquals(key, derivedKey)
    }

    static func derive(_ password: String, salt: Data, iterations: Int, length: Int) -> Data? {
        let passwordBytes = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: length)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                passwordBuffer.withMemoryRebound(to: Int8.self) { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.baseAddress, password.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        &key, length)
                }
            }
        }
        return status == kCCSuccess ? Data(key) : nil
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension Data {
    /// Parses a lowercase hex literal; used only for the compile-time
    /// constants above.
    fileprivate init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
