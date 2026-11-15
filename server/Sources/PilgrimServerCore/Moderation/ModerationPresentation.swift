import Fluent
import Foundation
import PilgrimAPI

/// Builds the API shapes the moderation and operator routes return (`UserSummary`, `MediaRef`,
/// `StickerResponse`, …) from Fluent rows.
struct ModerationPresenter: Sendable {
    let signer: MediaURLSigner
    let now: Date

    init(config: AppConfig, now: Date = Date()) {
        self.signer = MediaURLSigner(secret: config.mediaURLSecret, baseURL: config.publicBaseURL)
        self.now = now
    }

    func mediaRef(_ media: Media) throws -> MediaRef {
        let id = try media.requireID()
        let signed = signer.signedURL(for: id, now: now)
        return MediaRef(
            id: id, width: media.width, height: media.height, byteCount: media.byteCount,
            url: signed.url, urlExpiresAt: signed.expiresAt)
    }

    /// `user` must have `$profileMedia` eager-loaded, or the photo is looked up.
    func userSummary(_ user: User, on db: any Database) async throws -> UserSummary {
        let photo: Media?
        if let loaded = user.$profileMedia.value {
            photo = loaded
        } else if let mediaID = user.$profileMedia.id {
            photo = try await Media.find(mediaID, on: db)
        } else {
            photo = nil
        }
        return UserSummary(
            id: try user.requireID(), displayName: user.displayName ?? "",
            profilePhoto: try photo.map(mediaRef))
    }

    func adminUserRef(_ user: User) throws -> AdminUserRef {
        AdminUserRef(
            id: try user.requireID(), displayName: user.displayName,
            suspendedUntil: Self.suspendedUntil(user, now: now))
    }

    /// `AdminUserRef.suspendedUntil`: nil when not suspended, `Date.distantFuture` for an
    /// indefinite suspension (the contract has no separate flag).
    static func suspendedUntil(_ user: User, now: Date) -> Date? {
        guard user.isSuspended(at: now) else { return nil }
        return user.suspendedUntil ?? .distantFuture
    }

    func sticker(_ sticker: Sticker, on db: any Database) async throws -> StickerResponse? {
        guard let media = try await Media.find(sticker.$media.id, on: db) else { return nil }
        let creator = try await User.find(sticker.$createdBy.id, on: db)
        return StickerResponse(
            id: try sticker.requireID(), groupId: sticker.$group.id, name: sticker.name,
            media: try mediaRef(media),
            createdBy: try await creator.asyncMap { try await userSummary($0, on: db) },
            createdAt: sticker.createdAt ?? now, isMine: false)
    }
}

extension Optional {
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self {
        case .some(let value): try await transform(value)
        case .none: nil
        }
    }
}
