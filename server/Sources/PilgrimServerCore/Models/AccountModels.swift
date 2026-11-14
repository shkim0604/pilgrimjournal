import Fluent
import Foundation
import PilgrimAPI

// Fluent models for design.md "Postgres 스키마 / 계정". Column names, types and constraints are
// in `Migrations/CreateAccountTables.swift`; keep the two in step.
//
// Fluent models are reference types the ORM mutates in place; like the Vapor template they are
// `@unchecked Sendable` and must not be shared across tasks while being changed.

public final class User: Model, @unchecked Sendable {
    public static let schema = "users"

    @ID(key: .id) public var id: UUID?
    /// Apple's `sub`, or `dev:<name>` for development sign-in.
    @Field(key: "apple_sub") public var appleSub: String
    /// nil until the user finishes sign-up (`profileComplete == false`).
    @OptionalField(key: "display_name") public var displayName: String?
    @OptionalParent(key: "profile_media_id") public var profileMedia: Media?
    /// IANA time zone name.
    @Field(key: "time_zone") public var timeZone: String
    @OptionalField(key: "locale") public var locale: String?
    @Field(key: "daily_report_enabled") public var dailyReportEnabled: Bool
    /// Minutes after local midnight (API: `LocalTime`). Default 1320 = 22:00.
    @Field(key: "daily_report_minute") public var dailyReportMinute: Int
    @OptionalField(key: "suspended_at") public var suspendedAt: Date?
    /// nil with `suspendedAt` set = suspended indefinitely.
    @OptionalField(key: "suspended_until") public var suspendedUntil: Date?
    @OptionalField(key: "suspension_reason") public var suspensionReason: String?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) public var updatedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), appleSub: String, displayName: String? = nil,
        timeZone: String = "Asia/Seoul", locale: String? = nil
    ) {
        self.id = id
        self.appleSub = appleSub
        self.displayName = displayName
        self.timeZone = timeZone
        self.locale = locale
        self.dailyReportEnabled = true
        self.dailyReportMinute = 1_320
    }

    public var profileComplete: Bool { displayName != nil }

    public var dailyReportTime: LocalTime {
        LocalTime(minutesSinceMidnight: dailyReportMinute) ?? .defaultDailyReport
    }

    /// Whether the account is suspended at `now`.
    public func isSuspended(at now: Date = Date()) -> Bool {
        guard suspendedAt != nil else { return false }
        guard let until = suspendedUntil else { return true }
        return until > now
    }
}

public final class AppleToken: Model, @unchecked Sendable {
    public static let schema = "apple_tokens"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "user_id") public var user: User
    /// The bundle ID the code was exchanged with.
    @Field(key: "client_id") public var clientID: String
    /// AES-256-GCM `nonce ‖ ciphertext ‖ tag` of Apple's refresh token (`APPLE_TOKEN_ENC_KEY`).
    @Field(key: "refresh_token_ciphertext") public var refreshTokenCiphertext: Data
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) public var updatedAt: Date?

    public init() {}

    public init(id: UUID = UUID(), userID: UUID, clientID: String, ciphertext: Data) {
        self.id = id
        self.$user.id = userID
        self.clientID = clientID
        self.refreshTokenCiphertext = ciphertext
    }
}

/// Apple refresh tokens waiting for `/auth/revoke` after an account deletion (no user FK).
public final class AppleTokenRevocation: Model, @unchecked Sendable {
    public static let schema = "apple_token_revocations"

    @ID(key: .id) public var id: UUID?
    @Field(key: "client_id") public var clientID: String
    @Field(key: "refresh_token_ciphertext") public var refreshTokenCiphertext: Data
    @Field(key: "attempts") public var attempts: Int
    @Field(key: "next_attempt_at") public var nextAttemptAt: Date
    @OptionalField(key: "last_error") public var lastError: String?
    @OptionalField(key: "completed_at") public var completedAt: Date?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?

    public init() {}

    public init(id: UUID = UUID(), clientID: String, ciphertext: Data, nextAttemptAt: Date = Date())
    {
        self.id = id
        self.clientID = clientID
        self.refreshTokenCiphertext = ciphertext
        self.attempts = 0
        self.nextAttemptAt = nextAttemptAt
    }
}

/// One rotating refresh token. Only the SHA-256 of the token is stored.
public final class RefreshToken: Model, @unchecked Sendable {
    public static let schema = "refresh_tokens"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "user_id") public var user: User
    /// Every rotation of one sign-in shares the family (`sid` claim).
    @Field(key: "family_id") public var familyID: UUID
    @Field(key: "token_hash") public var tokenHash: Data
    @Field(key: "installation_id") public var installationID: UUID
    @Field(key: "issued_at") public var issuedAt: Date
    @Field(key: "expires_at") public var expiresAt: Date
    @OptionalField(key: "used_at") public var usedAt: Date?
    @OptionalField(key: "replaced_by_id") public var replacedByID: UUID?
    @OptionalField(key: "revoked_at") public var revokedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), userID: UUID, familyID: UUID, tokenHash: Data, installationID: UUID,
        issuedAt: Date, expiresAt: Date
    ) {
        self.id = id
        self.$user.id = userID
        self.familyID = familyID
        self.tokenHash = tokenHash
        self.installationID = installationID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public final class Device: Model, @unchecked Sendable {
    public static let schema = "devices"

    @ID(key: .id) public var id: UUID?
    @Parent(key: "user_id") public var user: User
    @Field(key: "installation_id") public var installationID: UUID
    /// Hex APNs token; nil until notifications are allowed (or after APNs rejected it).
    @OptionalField(key: "apns_token") public var apnsToken: String?
    @Enum(key: "apns_environment") public var apnsEnvironment: APNSEnvironment
    /// The APNs topic for this device.
    @Field(key: "bundle_id") public var bundleID: String
    @Enum(key: "platform") public var platform: ClientPlatform
    @OptionalField(key: "locale") public var locale: String?
    @OptionalField(key: "time_zone") public var timeZone: String?
    @OptionalField(key: "app_version") public var appVersion: String?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) public var updatedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), userID: UUID, installationID: UUID, apnsToken: String? = nil,
        apnsEnvironment: APNSEnvironment, bundleID: String, platform: ClientPlatform
    ) {
        self.id = id
        self.$user.id = userID
        self.installationID = installationID
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
        self.bundleID = bundleID
        self.platform = platform
    }
}

/// An App Store subscription keyed by its original transaction (`subscriptions`).
public final class AppStoreSubscription: Model, @unchecked Sendable {
    public static let schema = "subscriptions"

    public enum Environment: String, Codable, Sendable, CaseIterable {
        case production = "Production"
        case sandbox = "Sandbox"
    }

    @ID(key: .id) public var id: UUID?
    @OptionalParent(key: "user_id") public var user: User?
    @Field(key: "original_transaction_id") public var originalTransactionID: String
    @Field(key: "product_id") public var productID: String
    /// Never `.none` (the CHECK refuses it); `.none` is only an API value.
    @Enum(key: "status") public var status: SubscriptionStatus
    @OptionalField(key: "expires_at") public var expiresAt: Date?
    @Enum(key: "environment") public var environment: Environment
    @Field(key: "bundle_id") public var bundleID: String
    @OptionalField(key: "app_account_token") public var appAccountToken: UUID?
    @OptionalField(key: "last_transaction_id") public var lastTransactionID: String?
    @OptionalField(key: "storefront") public var storefront: String?
    @OptionalField(key: "removal_processed_at") public var removalProcessedAt: Date?
    @OptionalField(key: "last_checked_at") public var lastCheckedAt: Date?
    @Timestamp(key: "created_at", on: .create) public var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) public var updatedAt: Date?

    public init() {}

    public init(
        id: UUID = UUID(), userID: UUID?, originalTransactionID: String, productID: String,
        status: SubscriptionStatus, expiresAt: Date?, environment: Environment, bundleID: String
    ) {
        self.id = id
        self.$user.id = userID
        self.originalTransactionID = originalTransactionID
        self.productID = productID
        self.status = status
        self.expiresAt = expiresAt
        self.environment = environment
        self.bundleID = bundleID
    }
}

/// App Store Server Notifications V2 already handled; `id` is the `notificationUUID`.
public final class AppStoreNotification: Model, @unchecked Sendable {
    public static let schema = "appstore_notifications"

    @ID(custom: .id, generatedBy: .user) public var id: UUID?
    @Field(key: "notification_type") public var notificationType: String
    @OptionalField(key: "subtype") public var subtype: String?
    @OptionalField(key: "original_transaction_id") public var originalTransactionID: String?
    @OptionalField(key: "signed_date") public var signedDate: Date?
    @Field(key: "received_at") public var receivedAt: Date

    public init() {}

    public init(
        notificationUUID: UUID, notificationType: String, subtype: String? = nil,
        originalTransactionID: String? = nil, signedDate: Date? = nil, receivedAt: Date = Date()
    ) {
        self.id = notificationUUID
        self.notificationType = notificationType
        self.subtype = subtype
        self.originalTransactionID = originalTransactionID
        self.signedDate = signedDate
        self.receivedAt = receivedAt
    }
}
