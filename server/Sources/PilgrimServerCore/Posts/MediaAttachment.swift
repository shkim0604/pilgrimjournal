import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// Attaches uploaded photos to a new post or comment (design.md 7절: "미디어는 올린 사람만 붙일
/// 수 있고 한 곳에만 붙는다").
///
/// Uploading (`POST /uploads`) is the Media module's; this only claims existing rows. Each ID is
/// claimed with one conditional `UPDATE`, so two requests can never attach the same photo: a
/// photo that is missing, someone else's, uploaded for another purpose or group, or already
/// attached is 409 `MEDIA_NOT_ATTACHABLE`, and the surrounding transaction rolls back.
enum MediaAttachment {
    enum Target: Sendable {
        case post(UUID)
        case comment(UUID)

        var purpose: MediaPurpose {
            switch self {
            case .post: .post
            case .comment: .comment
            }
        }
    }

    /// Claims `mediaIDs` in order (`sort_order` 0, 1, …). Call inside the create transaction.
    static func attach(
        _ mediaIDs: [UUID], to target: Target, uploader: UUID, groupID: UUID, now: Date,
        on db: any Database
    ) async throws {
        guard !mediaIDs.isEmpty else { return }
        let sql = try ContentAccess.sql(db)
        for (index, mediaID) in mediaIDs.enumerated() {
            let assignment: SQLQueryString =
                switch target {
                case .post(let postID): "post_id = \(bind: postID)"
                case .comment(let commentID): "comment_id = \(bind: commentID)"
                }
            let rows = try await sql.raw(
                """
                UPDATE media SET \(assignment), sort_order = \(bind: index), \
                attached_at = \(bind: now)
                WHERE id = \(bind: mediaID)
                  AND uploader_id = \(bind: uploader)
                  AND purpose = \(bind: target.purpose.rawValue)
                  AND group_id = \(bind: groupID)
                  AND attached_at IS NULL
                  AND post_id IS NULL
                  AND comment_id IS NULL
                RETURNING id
                """
            ).all()
            guard !rows.isEmpty else {
                throw APIError(
                    code: .mediaNotAttachable,
                    message: "photo \(index) cannot be attached here", field: "mediaIds")
            }
        }
    }
}
