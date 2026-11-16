import Foundation

/// A cursor page (design.md 2절 "페이징"). `nextCursor` is opaque to the app.
public struct Page<Item: Codable & Sendable & Equatable>: Equatable, Sendable, Codable {
    public var items: [Item]
    public var nextCursor: String?

    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    /// `limit` when the query omits it.
    public static var defaultLimit: Int { 20 }
    /// The largest `limit` the server accepts; larger values are clamped.
    public static var maximumLimit: Int { 50 }
}

/// The `{}` body of `POST /groups/:id/seen` and `POST /invites/:code/accept`.
public struct EmptyBody: Equatable, Sendable, Codable {
    public init() {}
}

/// The two bundle IDs the server accepts (`aud`, `X-Pilgrim-Client`, APNs topic).
public enum BundleIDs {
    public static let release = "com.dhouse.PilgrimJournal"
    public static let debug = "com.dhouse.PilgrimJournal.debug"
    public static let all: Set<String> = [release, debug]
}

/// HTTP header names shared by the app, the server and the admin console.
public enum PilgrimHeader {
    /// `X-Pilgrim-Client`, required on every `/api/v1/*` request (see `ClientHeader`).
    public static let client = ClientHeader.name
    /// Operator routes (`/internal/admin/v1`): the shared admin token.
    public static let adminToken = "X-Admin-Token"
    /// Operator routes: the console user's name, written to `moderation_log`.
    public static let adminActor = "X-Admin-Actor"
}

/// API base paths.
public enum APIPaths {
    public static let version1 = "/api/v1"
    public static let admin = "/internal/admin/v1"
    public static let health = "/api/health"
    public static let mediaFiles = "/api/media-files"
    public static let appStoreNotifications = "/api/appstore/notifications"
    public static let invitePage = "/i"
    public static let productionBaseURL = URL(string: "https://pilgrim.delight-house.org")!
}

/// A member as other members see them.
public struct UserSummary: Equatable, Hashable, Sendable, Codable {
    public var id: UUID
    public var displayName: String
    public var profilePhoto: MediaRef?

    public init(id: UUID, displayName: String, profilePhoto: MediaRef? = nil) {
        self.id = id
        self.displayName = displayName
        self.profilePhoto = profilePhoto
    }
}

/// `GET /api/health` (outside v1, no auth).
public struct HealthResponse: Equatable, Sendable, Codable {
    public enum Status: String, Sendable, Codable {
        case ok, degraded
    }

    public var status: Status
    public var database: Bool
    public var worker: WorkerHealth
    public var version: String

    public init(status: Status, database: Bool, worker: WorkerHealth, version: String) {
        self.status = status
        self.database = database
        self.worker = worker
        self.version = version
    }
}

public struct WorkerHealth: Equatable, Sendable, Codable {
    public var lastBeatAt: Date?
    public var healthy: Bool

    public init(lastBeatAt: Date?, healthy: Bool) {
        self.lastBeatAt = lastBeatAt
        self.healthy = healthy
    }

    /// Every worker loop must have beaten within this window for `healthy` to be true.
    public static let staleAfter: TimeInterval = 120
}
