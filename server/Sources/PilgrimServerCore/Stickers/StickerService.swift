import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// Making and removing group stickers (design.md 8절).
enum StickerService {
    /// Inserts the sticker for `request`. Call inside the create transaction
    /// (`Idempotency.findOrCreate`): it locks the group row, so the 30-sticker count and the
    /// insert cannot interleave with another request for the same group.
    static func create(
        _ request: CreateStickerRequest, in groupID: UUID, by creator: UUID, now: Date,
        on db: any Database
    ) async throws -> Sticker {
        try await GroupService.lockGroup(groupID, on: db)
        let group = try await ContentAccess.group(groupID, on: db)
        try ContentAccess.requireWritable(group)
        let name = try StickerRules.normalizedName(request.name)
        let count = try await Sticker.query(on: db).filter(\.$group.$id == groupID).count()
        guard count < APILimits.stickersPerGroup else {
            throw APIError(
                code: .stickerLimitReached,
                message: "a group holds at most \(APILimits.stickersPerGroup) stickers",
                limit: APILimits.stickersPerGroup)
        }
        guard
            try await MediaClaim.claim(
                request.mediaId, purpose: .sticker, uploader: creator, groupID: groupID, now: now,
                on: db)
        else { throw MediaClaim.notAttachable(field: "mediaId") }
        let sticker = Sticker(
            groupID: groupID, createdByID: creator, mediaID: request.mediaId, name: name,
            clientID: request.clientId)
        try await sticker.create(on: db)
        return sticker
    }

    /// Deletes a sticker (no permission check; callers decide who may). In one transaction:
    /// - comments that used it keep `had_sticker` and lose `sticker_id`, so they stay and show
    ///   "지워진 스티커" (`CommentResponse.stickerRemoved`);
    /// - reactions with it are removed (they would also go with the foreign key's cascade);
    /// - the sticker row, then its photo row — whose `media_after_delete` trigger queues the
    ///   file for the worker.
    ///
    /// 404 when the sticker is already gone.
    static func delete(_ stickerID: UUID, on db: any Database) async throws {
        try await db.transaction { tx in
            guard let sticker = try await Sticker.find(stickerID, on: tx) else {
                throw APIError.notFound()
            }
            guard let sql = tx as? any SQLDatabase else {
                throw APIError(code: .internal, message: "SQL database required")
            }
            try await sql.raw(
                """
                UPDATE comments SET had_sticker = true, sticker_id = NULL
                WHERE sticker_id = \(bind: stickerID)
                """
            ).run()
            try await sql.raw("DELETE FROM reactions WHERE sticker_id = \(bind: stickerID)").run()
            let mediaID = sticker.$media.id
            try await sticker.delete(on: tx)
            try await Media.query(on: tx).filter(\.$id == mediaID).delete()
        }
    }
}

/// Request rules for stickers that need no database.
enum StickerRules {
    /// The optional name, trimmed: nil when absent or blank; at most 20 characters (graphemes,
    /// 422 `LIMIT_EXCEEDED`) on one line (422 `VALIDATION_FAILED`).
    static func normalizedName(_ name: String?) throws -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        guard !trimmed.contains(where: \.isNewline) else {
            throw APIError.validationFailed(field: "name", "a sticker name is one line")
        }
        guard trimmed.count <= APILimits.stickerNameMax else {
            throw APIError.limitExceeded(field: "name", limit: APILimits.stickerNameMax)
        }
        return trimmed
    }
}
