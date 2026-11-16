import Fluent
import Foundation
import PilgrimAPI
import SQLKit

extension MediaURLSigner {
    /// The signer for this server's `MEDIA_URL_SECRET` and `PUBLIC_BASE_URL`.
    public init(config: AppConfig) {
        self.init(secret: config.mediaURLSecret, baseURL: config.publicBaseURL)
    }

    /// `media` as a `MediaRef` with a fresh signed URL (design.md 7절 "내려받기").
    public func ref(for media: Media, now: Date = Date()) throws -> MediaRef {
        let id = try media.requireID()
        let signed = signedURL(for: id, now: now)
        return MediaRef(
            id: id, width: media.width, height: media.height, byteCount: media.byteCount,
            url: signed.url, urlExpiresAt: signed.expiresAt)
    }
}

/// The attach rule for photos (design.md 7절): only the uploader may attach an upload, only once,
/// only for the purpose and group it was uploaded for. Posts and comments claim theirs through
/// `MediaAttachment` (Posts), profile photos through `PATCH /me` (Account); this is the same
/// conditional `UPDATE` for the attachments that only set `attached_at` (stickers).
enum MediaClaim {
    /// Marks the upload attached if every rule holds, in one conditional `UPDATE` so two requests
    /// can never claim the same upload. Returns false (nothing changed) otherwise: the caller
    /// answers 409 `MEDIA_NOT_ATTACHABLE`.
    static func claim(
        _ mediaID: UUID, purpose: MediaPurpose, uploader: UUID, groupID: UUID?, now: Date,
        on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw APIError(code: .internal, message: "SQL database required")
        }
        let group: SQLQueryString =
            if let groupID { "group_id = \(bind: groupID)" } else { "group_id IS NULL" }
        let rows = try await sql.raw(
            """
            UPDATE media SET attached_at = \(bind: now)
            WHERE id = \(bind: mediaID)
              AND uploader_id = \(bind: uploader)
              AND purpose = \(bind: purpose.rawValue)
              AND \(group)
              AND attached_at IS NULL
              AND post_id IS NULL
              AND comment_id IS NULL
            RETURNING id
            """
        ).all()
        return !rows.isEmpty
    }

    static func notAttachable(field: String) -> APIError {
        APIError(
            code: .mediaNotAttachable,
            message: "media is not an unattached upload of yours for this purpose", field: field)
    }
}
