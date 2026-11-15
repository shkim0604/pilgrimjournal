import Crypto
import Foundation

/// Encrypts Apple refresh tokens at rest (`apple_tokens`, `apple_token_revocations`).
///
/// Format: AES-256-GCM `combined` = 12-byte nonce ‖ ciphertext ‖ 16-byte tag. The key is
/// `APPLE_TOKEN_ENC_KEY`: 32 bytes written as base64 or as 64 hex characters. The revocation
/// worker (S5) decrypts with this same type.
public struct AppleTokenCipher: Sendable {
    /// The raw key bytes. swift-crypto's `SymmetricKey` is not `Sendable` on Linux, so the
    /// bytes are stored and the key is rebuilt on use.
    private let keyBytes: Data

    var key: SymmetricKey { SymmetricKey(data: keyBytes) }

    public init(key: SymmetricKey) {
        self.keyBytes = key.withUnsafeBytes { Data($0) }
    }

    /// Parses `APPLE_TOKEN_ENC_KEY`. Throws `ConfigurationError` unless it is exactly 32 bytes.
    public init(encodedKey text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bytes = Self.hexBytes(trimmed), bytes.count == 32 {
            self.init(key: SymmetricKey(data: bytes))
        } else if let bytes = Data(base64Encoded: trimmed), bytes.count == 32 {
            self.init(key: SymmetricKey(data: bytes))
        } else {
            throw ConfigurationError(
                "APPLE_TOKEN_ENC_KEY must be 32 bytes as base64 or 64 hex characters")
        }
    }

    /// A random key for development and tests, where nothing outlives the process.
    public static func ephemeral() -> AppleTokenCipher {
        AppleTokenCipher(key: SymmetricKey(size: .bits256))
    }

    public func encrypt(_ token: String) throws -> Data {
        let sealed = try AES.GCM.seal(Data(token.utf8), using: key)
        guard let combined = sealed.combined else {
            throw AppleTokenCipherError.encryptionFailed
        }
        return combined
    }

    public func decrypt(_ ciphertext: Data) throws -> String {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        let plain = try AES.GCM.open(box, using: key)
        guard let token = String(data: plain, encoding: .utf8) else {
            throw AppleTokenCipherError.notUTF8
        }
        return token
    }

    private static func hexBytes(_ text: String) -> Data? {
        guard text.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

public enum AppleTokenCipherError: Error, Equatable {
    case encryptionFailed
    case notUTF8
}
