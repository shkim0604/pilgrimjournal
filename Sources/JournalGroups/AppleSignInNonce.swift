import CryptoKit
import Foundation
import Security

/// The nonce for the group server's Apple sign-in (design.md 3절): a 32-byte random raw value
/// sent to the server as `rawNonce`, and its SHA-256 (lowercase hex) set on
/// `ASAuthorizationAppleIDRequest.nonce`.
public struct AppleSignInNonce: Equatable, Sendable {
    /// base64url without padding of 32 random bytes.
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    /// A fresh nonce from the system's secure random generator.
    public static func generate(byteCount: Int = 32) -> AppleSignInNonce {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            // SystemRandomNumberGenerator is also cryptographically secure on Apple platforms.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return AppleSignInNonce(raw: base64URL(Data(bytes)))
    }

    /// `SHA256(raw)` in lowercase hex: the value for the Apple request.
    public var hashed: String { Self.sha256Hex(raw) }

    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
