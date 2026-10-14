import CryptoKit
import Foundation

/// Lowercase-hex SHA-256, the one format every checksum, fingerprint and
/// scope hash in the app is stored and compared in.
public enum ContentHash {
    public static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    /// Formats a digest that was computed incrementally, e.g. while streaming
    /// a large file through `SHA256.update(data:)`.
    public static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
