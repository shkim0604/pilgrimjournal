import Foundation

/// A group sticker: a member's square photo, usable for reactions and comments in that group only.
public struct StickerResponse: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var groupId: UUID
    public var name: String?
    public var media: MediaRef
    public var createdBy: UserSummary?
    public var createdAt: Date
    public var isMine: Bool

    public init(
        id: UUID, groupId: UUID, name: String?, media: MediaRef, createdBy: UserSummary?,
        createdAt: Date, isMine: Bool
    ) {
        self.id = id
        self.groupId = groupId
        self.name = name
        self.media = media
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.isMine = isMine
    }
}

/// `POST /groups/:id/stickers` → 201 `StickerResponse`. `mediaId` is a `sticker` upload.
public struct CreateStickerRequest: Equatable, Sendable, Codable {
    public var clientId: UUID
    public var mediaId: UUID
    /// ≤ 20 characters.
    public var name: String?

    public init(clientId: UUID, mediaId: UUID, name: String? = nil) {
        self.clientId = clientId
        self.mediaId = mediaId
        self.name = name
    }
}
