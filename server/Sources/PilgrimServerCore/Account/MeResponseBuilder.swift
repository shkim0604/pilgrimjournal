import Fluent
import Foundation
import PilgrimAPI

/// Builds `MeResponse` (`GET /me`, `PATCH /me`, `AuthSessionResponse.user`).
public enum MeResponseBuilder {
    public static func response(
        for user: User, on db: any Database, config: AppConfig, now: Date = Date()
    ) async throws -> MeResponse {
        let userID = try user.requireID()
        var photo: MediaRef?
        if let mediaID = user.$profileMedia.id, let media = try await Media.find(mediaID, on: db) {
            let signer = MediaURLSigner(secret: config.mediaURLSecret, baseURL: config.publicBaseURL)
            let signed = signer.signedURL(for: mediaID, now: now)
            photo = MediaRef(
                id: mediaID, width: media.width, height: media.height, byteCount: media.byteCount,
                url: signed.url, urlExpiresAt: signed.expiresAt)
        }
        return MeResponse(
            id: userID, displayName: user.displayName, profilePhoto: photo,
            profileComplete: user.profileComplete, timeZone: user.timeZone,
            dailyReportEnabled: user.dailyReportEnabled, dailyReportTime: user.dailyReportTime,
            // An indefinite suspension has no end date; report it as far in the future.
            suspendedUntil: user.isSuspended(at: now) ? (user.suspendedUntil ?? .distantFuture) : nil,
            createdAt: user.createdAt ?? now,
            entitlement: try await entitlement(for: userID, on: db, config: config, now: now))
    }

    /// `EntitlementResponse.notRequired` while `SUBSCRIPTION_REQUIRED=false` and the user has no
    /// subscription; otherwise the user's best subscription row (S8 owns the full policy).
    static func entitlement(
        for userID: UUID, on db: any Database, config: AppConfig, now: Date
    ) async throws -> EntitlementResponse {
        let subscriptions = try await AppStoreSubscription.query(on: db)
            .filter(\.$user.$id == userID)
            .sort(\.$expiresAt, .descending)
            .all()
        let best =
            subscriptions.first {
                EntitlementPolicy.isActive(status: $0.status, expiresAt: $0.expiresAt, now: now)
            } ?? subscriptions.first
        guard let best else {
            return config.subscriptionRequired
                ? EntitlementResponse(subscriptionRequired: true, active: false, status: .none)
                : .notRequired
        }
        let active = EntitlementPolicy.isActive(
            status: best.status, expiresAt: best.expiresAt, now: now)
        return EntitlementResponse(
            subscriptionRequired: config.subscriptionRequired,
            active: active || !config.subscriptionRequired, status: best.status,
            productId: best.productID, expiresAt: best.expiresAt)
    }
}
