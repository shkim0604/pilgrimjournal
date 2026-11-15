import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// `GET/PATCH/DELETE /me` and `PUT/DELETE /me/devices/:installationId`.
///
/// `/me` works before sign-up (that is how sign-up is saved). Changing the profile or registering
/// a device is refused while suspended; reading `/me`, removing a device and deleting the account
/// are not.
enum AccountRoutes {
    static func register(_ app: Application) {
        let routes = app.pilgrimRoutes
        let me = routes.authenticated.grouped("me")
        let loaded = me.grouped(
            AccountStateMiddleware(requiresSignup: false, allowsSuspended: true))
        let editable = me.grouped(
            AccountStateMiddleware(requiresSignup: false, allowsSuspended: false))

        loaded.get(use: getMe)
        editable.patch(use: updateMe)
        me.delete(use: deleteMe)
        editable.put("devices", ":installationId", use: registerDevice)
        me.delete("devices", ":installationId", use: removeDevice)
    }

    @Sendable static func getMe(_ req: Request) async throws -> Response {
        let user = try await req.currentUser()
        return try .pilgrimJSON(
            try await MeResponseBuilder.response(for: user, on: req.db, config: req.pilgrimConfig))
    }

    // MARK: - PATCH /me

    struct ProfileChanges: Sendable {
        var displayName: String?
        var photo: PhotoChange
        var timeZone: String?
        var dailyReportEnabled: Bool?
        var dailyReportMinute: Int?

        enum PhotoChange: Sendable {
            case keep
            case set(UUID)
            case remove
        }
    }

    /// Validates `UpdateMeRequest` without touching the database.
    static func validate(_ body: UpdateMeRequest) throws -> ProfileChanges {
        if body.profilePhotoId != nil, body.removeProfilePhoto == true {
            throw APIError.validationFailed(
                field: "profilePhotoId", "profilePhotoId and removeProfilePhoto are exclusive")
        }
        var changes = ProfileChanges(photo: .keep)
        if let raw = body.displayName {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.count > APILimits.displayName.upperBound {
                throw APIError.limitExceeded(
                    field: "displayName", limit: APILimits.displayName.upperBound)
            }
            guard APILimits.isValidDisplayName(name) else {
                throw APIError.validationFailed(
                    field: "displayName", "display name must be 1–30 characters on one line")
            }
            changes.displayName = name
        }
        if let photoID = body.profilePhotoId {
            changes.photo = .set(photoID)
        } else if body.removeProfilePhoto == true {
            changes.photo = .remove
        }
        if let zone = body.timeZone {
            guard zone == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(zone),
                TimeZone(identifier: zone) != nil
            else {
                throw APIError.validationFailed(field: "timeZone", "unknown time zone")
            }
            changes.timeZone = zone
        }
        changes.dailyReportEnabled = body.dailyReportEnabled
        changes.dailyReportMinute = body.dailyReportTime?.minutesSinceMidnight
        return changes
    }

    @Sendable static func updateMe(_ req: Request) async throws -> Response {
        let changes = try validate(try req.content.decode(UpdateMeRequest.self))
        let userID = try req.userID
        let now = Date()
        let user = try await req.db.transaction { tx -> User in
            try await apply(changes, userID: userID, on: tx, now: now)
        }
        req.cacheCurrentUser(user)
        return try .pilgrimJSON(
            try await MeResponseBuilder.response(
                for: user, on: req.db, config: req.pilgrimConfig, now: now))
    }

    static func apply(_ changes: ProfileChanges, userID: UUID, on tx: any Database, now: Date)
        async throws -> User
    {
        let sql = try PushOutbox.sqlDatabase(tx)
        guard
            try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR UPDATE")
                .first() != nil,
            let user = try await User.find(userID, on: tx)
        else { throw APIError.unauthenticated("account no longer exists") }

        if let name = changes.displayName { user.displayName = name }
        if let zone = changes.timeZone { user.timeZone = zone }
        if let enabled = changes.dailyReportEnabled { user.dailyReportEnabled = enabled }
        if let minute = changes.dailyReportMinute { user.dailyReportMinute = minute }

        let oldPhotoID = user.$profileMedia.id
        var replacedPhotoID: UUID?
        switch changes.photo {
        case .keep:
            break
        case .remove:
            user.$profileMedia.id = nil
            replacedPhotoID = oldPhotoID
        case .set(let photoID) where photoID == oldPhotoID:
            break
        case .set(let photoID):
            guard
                try await sql.raw("SELECT id FROM media WHERE id = \(bind: photoID) FOR UPDATE")
                    .first() != nil,
                let media = try await Media.find(photoID, on: tx)
            else { throw APIError.notFound("media not found") }
            guard media.$uploader.id == userID else { throw APIError.notFound("media not found") }
            guard media.purpose == .profile, media.attachedAt == nil, media.$post.id == nil,
                media.$comment.id == nil
            else {
                throw APIError(
                    code: .mediaNotAttachable, message: "media is not an unattached profile photo")
            }
            media.attachedAt = now
            try await media.save(on: tx)
            user.$profileMedia.id = photoID
            replacedPhotoID = oldPhotoID
        }
        try await user.save(on: tx)
        if let replacedPhotoID {
            // The `media_after_delete` trigger queues the file for deletion.
            try await Media.query(on: tx).filter(\.$id == replacedPhotoID).delete()
        }
        return user
    }

    // MARK: - DELETE /me

    @Sendable static func deleteMe(_ req: Request) async throws -> Response {
        let result = try await AccountDeletion.delete(
            userID: try req.userID, on: req.db, dayLength: req.pilgrimConfig.dayLength)
        return try .pilgrimJSON(result)
    }

    // MARK: - Devices

    static func installationID(_ req: Request) throws -> UUID {
        guard let text = req.parameters.get("installationId"), let id = UUID(uuidString: text)
        else { throw APIError.invalidRequest("installationId must be a UUID") }
        return id
    }

    /// Lowercased hex APNs token, or nil. Throws 422 for anything that is not hex.
    static func normalizedAPNsToken(_ token: String?) throws -> String? {
        guard let token else { return nil }
        let hex = token.lowercased()
        guard (8...400).contains(hex.count), hex.count.isMultiple(of: 2),
            hex.allSatisfy({ $0.isHexDigit && $0.isASCII })
        else { throw APIError.validationFailed(field: "apnsToken", "apnsToken must be hex") }
        return hex
    }

    @Sendable static func registerDevice(_ req: Request) async throws -> HTTPStatus {
        let installationID = try installationID(req)
        let body = try req.content.decode(DeviceRegistrationRequest.self)
        guard req.pilgrimConfig.allowedBundleIDs.contains(body.bundleId) else {
            throw APIError.validationFailed(field: "bundleId", "unknown bundleId")
        }
        let token = try normalizedAPNsToken(body.apnsToken)
        let userID = try req.userID
        try await req.db.transaction { tx in
            let sql = try PushOutbox.sqlDatabase(tx)
            if let token {
                // A token belongs to one installation; an older row with it would double-send.
                try await sql.raw(
                    """
                    UPDATE devices SET apns_token = NULL, updated_at = now()
                    WHERE apns_token = \(bind: token) AND installation_id <> \(bind: installationID)
                    """
                ).run()
            }
            // The installation may move to another user (sign-out, then a different sign-in).
            try await sql.raw(
                """
                INSERT INTO devices (id, user_id, installation_id, apns_token, apns_environment,
                    bundle_id, platform, locale, time_zone, app_version)
                VALUES (\(bind: UUID()), \(bind: userID), \(bind: installationID), \(bind: token),
                    \(bind: body.apnsEnvironment.rawValue), \(bind: body.bundleId),
                    \(bind: body.platform.rawValue), \(bind: body.locale), \(bind: body.timeZone),
                    \(bind: body.appVersion))
                ON CONFLICT (installation_id) DO UPDATE SET
                    user_id = EXCLUDED.user_id,
                    apns_token = EXCLUDED.apns_token,
                    apns_environment = EXCLUDED.apns_environment,
                    bundle_id = EXCLUDED.bundle_id,
                    platform = EXCLUDED.platform,
                    locale = EXCLUDED.locale,
                    time_zone = EXCLUDED.time_zone,
                    app_version = EXCLUDED.app_version,
                    updated_at = now()
                """
            ).run()
        }
        return .noContent
    }

    @Sendable static func removeDevice(_ req: Request) async throws -> HTTPStatus {
        let installationID = try installationID(req)
        try await Device.query(on: req.db)
            .filter(\.$installationID == installationID)
            .filter(\.$user.$id == (try req.userID))
            .delete()
        return .noContent
    }
}
