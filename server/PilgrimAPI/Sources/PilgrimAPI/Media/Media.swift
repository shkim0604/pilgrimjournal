import Foundation

public enum MediaPurpose: String, Sendable, Codable, CaseIterable {
    case post, comment, profile, sticker
}

/// An uploaded JPEG. `url` is a signed download URL valid until `urlExpiresAt` (10 minutes);
/// `GET /media/:id` issues a fresh one. The file never changes, so the app caches by `id`.
public struct MediaRef: Equatable, Hashable, Sendable, Codable {
    public var id: UUID
    public var width: Int
    public var height: Int
    public var byteCount: Int
    public var url: URL
    public var urlExpiresAt: Date

    public init(id: UUID, width: Int, height: Int, byteCount: Int, url: URL, urlExpiresAt: Date) {
        self.id = id
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.url = url
        self.urlExpiresAt = urlExpiresAt
    }

    /// How long a signed media URL stays valid.
    public static let signedURLLifetime: TimeInterval = 600
}

/// Multipart field names of `POST /uploads` (`file` is `image/jpeg`).
public enum UploadFormField {
    public static let purpose = "purpose"
    public static let clientID = "clientId"
    /// Required for every purpose except `profile`; the uploader must be a member.
    public static let groupID = "groupId"
    public static let file = "file"
}

/// `POST /uploads` → 201.
public struct UploadResponse: Equatable, Sendable, Codable {
    public var media: MediaRef

    public init(media: MediaRef) {
        self.media = media
    }
}

/// `GET /media/:id`.
public struct MediaURLResponse: Equatable, Sendable, Codable {
    public var url: URL
    public var expiresAt: Date

    public init(url: URL, expiresAt: Date) {
        self.url = url
        self.expiresAt = expiresAt
    }
}
