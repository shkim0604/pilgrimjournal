import Crypto
import Foundation
import PilgrimAPI

/// Where photo files live (design.md 7절). Paths are relative to the store root, as kept in
/// `media.file_path` and `media_file_deletions.file_path`.
public protocol MediaStore: Sendable {
    func write(_ data: Data, to relativePath: String) async throws
    /// The file's bytes, or nil when it does not exist.
    func read(_ relativePath: String) async throws -> Data?
    /// Removes the file. A file that is already gone counts as success.
    func delete(_ relativePath: String) async throws
    func exists(_ relativePath: String) async -> Bool
}

public enum MediaStoreError: Error, Equatable {
    /// The path is absolute, climbs out of the root, or has unexpected characters.
    case invalidPath(String)
}

/// Stores files on local disk under `root` (the `media` Docker volume, `MEDIA_ROOT`).
public struct LocalDiskMediaStore: MediaStore {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public init(rootPath: String) {
        let expanded = (rootPath as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded, isDirectory: true)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(expanded, isDirectory: true)
        self.init(root: url)
    }

    public func write(_ data: Data, to relativePath: String) async throws {
        let url = try fileURL(for: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func read(_ relativePath: String) async throws -> Data? {
        let url = try fileURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func delete(_ relativePath: String) async throws {
        let url = try fileURL(for: relativePath)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return }
            throw error
        }
    }

    public func exists(_ relativePath: String) async -> Bool {
        guard let url = try? fileURL(for: relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Resolves `relativePath` inside the root, refusing anything that could escape it.
    public func fileURL(for relativePath: String) throws -> URL {
        try MediaPaths.validate(relativePath)
        return root.appendingPathComponent(relativePath, isDirectory: false)
    }
}

/// File naming for media (design.md 7절 "저장": `<id 앞 2자>/<id>.jpg`).
public enum MediaPaths {
    public static func relativePath(for mediaID: UUID) -> String {
        let id = mediaID.uuidString.lowercased()
        return "\(id.prefix(2))/\(id).jpg"
    }

    /// Accepts only `segment/segment/...` made of `[A-Za-z0-9._-]`, without `.`/`..` segments.
    public static func validate(_ relativePath: String) throws {
        let segments = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !relativePath.isEmpty, !segments.isEmpty,
            segments.allSatisfy({ segment in
                !segment.isEmpty && segment != "." && segment != ".."
                    && segment.allSatisfy { allowed.contains($0) }
            })
        else { throw MediaStoreError.invalidPath(relativePath) }
    }
}

/// Signs and checks the short-lived media file URLs (design.md 7절 "내려받기"):
/// `<PUBLIC_BASE_URL>/api/media-files/<id>?exp=<unix>&sig=<base64url HMAC-SHA256(secret, "<id>.<exp>")>`.
public struct MediaURLSigner: Sendable {
    let key: SymmetricKey
    let baseURL: URL
    public let lifetime: TimeInterval

    public init(secret: String, baseURL: URL, lifetime: TimeInterval = MediaRef.signedURLLifetime) {
        self.key = SymmetricKey(data: Data(secret.utf8))
        self.baseURL = baseURL
        self.lifetime = lifetime
    }

    public func signedURL(for mediaID: UUID, now: Date = Date()) -> (url: URL, expiresAt: Date) {
        let expiry = Int((now.timeIntervalSince1970 + lifetime).rounded(.down))
        let id = mediaID.uuidString.lowercased()
        let signature = sign(id: id, expiry: expiry)
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/media-files/\(id)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "exp", value: String(expiry)),
            URLQueryItem(name: "sig", value: signature),
        ]
        return (components.url!, Date(timeIntervalSince1970: TimeInterval(expiry)))
    }

    /// Whether `signature` matches and `expiry` (unix seconds) has not passed.
    public func isValid(mediaID: UUID, expiry: Int, signature: String, now: Date = Date())
        -> Bool
    {
        guard TimeInterval(expiry) > now.timeIntervalSince1970,
            let provided = Data(base64URLEncoded: signature)
        else { return false }
        let message = Data("\(mediaID.uuidString.lowercased()).\(expiry)".utf8)
        return HMAC<SHA256>.isValidAuthenticationCode(provided, authenticating: message, using: key)
    }

    private func sign(id: String, expiry: Int) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data("\(id).\(expiry)".utf8), using: key)
        return Data(code).base64URLEncodedString()
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 §5).
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public init?(base64URLEncoded text: String) {
        guard !text.contains("="), !text.contains("+"), !text.contains("/") else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: base64)
    }
}
