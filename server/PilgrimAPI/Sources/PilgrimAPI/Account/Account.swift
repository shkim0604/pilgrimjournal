import Foundation

/// `GET /me`, `PATCH /me`, and `AuthSessionResponse.user`.
public struct MeResponse: Equatable, Sendable, Codable {
    public var id: UUID
    /// nil until sign-up stores a name.
    public var displayName: String?
    public var profilePhoto: MediaRef?
    /// false → the app shows the sign-up screen (terms, name, photo) and saves with `PATCH /me`.
    public var profileComplete: Bool
    /// IANA time zone name.
    public var timeZone: String
    public var dailyReportEnabled: Bool
    public var dailyReportTime: LocalTime
    public var suspendedUntil: Date?
    public var createdAt: Date
    public var entitlement: EntitlementResponse

    public init(
        id: UUID, displayName: String?, profilePhoto: MediaRef? = nil, profileComplete: Bool,
        timeZone: String, dailyReportEnabled: Bool, dailyReportTime: LocalTime,
        suspendedUntil: Date? = nil, createdAt: Date, entitlement: EntitlementResponse
    ) {
        self.id = id
        self.displayName = displayName
        self.profilePhoto = profilePhoto
        self.profileComplete = profileComplete
        self.timeZone = timeZone
        self.dailyReportEnabled = dailyReportEnabled
        self.dailyReportTime = dailyReportTime
        self.suspendedUntil = suspendedUntil
        self.createdAt = createdAt
        self.entitlement = entitlement
    }
}

/// `PATCH /me`. Omitted fields stay unchanged.
public struct UpdateMeRequest: Equatable, Sendable, Codable {
    public var displayName: String?
    /// A `profile` upload to attach as the new photo.
    public var profilePhotoId: UUID?
    public var removeProfilePhoto: Bool?
    public var timeZone: String?
    public var dailyReportEnabled: Bool?
    public var dailyReportTime: LocalTime?

    public init(
        displayName: String? = nil, profilePhotoId: UUID? = nil, removeProfilePhoto: Bool? = nil,
        timeZone: String? = nil, dailyReportEnabled: Bool? = nil, dailyReportTime: LocalTime? = nil
    ) {
        self.displayName = displayName
        self.profilePhotoId = profilePhotoId
        self.removeProfilePhoto = removeProfilePhoto
        self.timeZone = timeZone
        self.dailyReportEnabled = dailyReportEnabled
        self.dailyReportTime = dailyReportTime
    }
}

/// `DELETE /me`. `alreadyDeleted` answers a retry after the user is already gone (idempotent).
public struct AccountDeletionResponse: Equatable, Sendable, Codable {
    public var deletedAt: Date?
    public var alreadyDeleted: Bool
    /// Groups this user administered that now elect a new admin.
    public var groupsHandedToVote: [UUID]
    /// Groups deleted because no member was left.
    public var groupsDeleted: [UUID]

    public init(
        deletedAt: Date?, alreadyDeleted: Bool, groupsHandedToVote: [UUID] = [],
        groupsDeleted: [UUID] = []
    ) {
        self.deletedAt = deletedAt
        self.alreadyDeleted = alreadyDeleted
        self.groupsHandedToVote = groupsHandedToVote
        self.groupsDeleted = groupsDeleted
    }
}

public enum APNSEnvironment: String, Sendable, Codable, CaseIterable {
    case sandbox, production
}

/// `PUT /me/devices/:installationId` → 204.
public struct DeviceRegistrationRequest: Equatable, Sendable, Codable {
    /// Hex APNs device token; nil when notifications are not allowed.
    public var apnsToken: String?
    public var apnsEnvironment: APNSEnvironment
    public var bundleId: String
    public var platform: ClientPlatform
    public var locale: String
    public var timeZone: String
    public var appVersion: String

    public init(
        apnsToken: String?, apnsEnvironment: APNSEnvironment, bundleId: String,
        platform: ClientPlatform, locale: String, timeZone: String, appVersion: String
    ) {
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
        self.bundleId = bundleId
        self.platform = platform
        self.locale = locale
        self.timeZone = timeZone
        self.appVersion = appVersion
    }
}

/// `GET /me/hides`.
public struct HidesResponse: Equatable, Sendable, Codable {
    public var posts: [HiddenPost]
    public var users: [HiddenUser]

    public init(posts: [HiddenPost], users: [HiddenUser]) {
        self.posts = posts
        self.users = users
    }
}

public struct HiddenPost: Equatable, Sendable, Codable {
    public var postId: UUID
    public var groupId: UUID
    public var groupName: String
    public var title: String?
    public var hiddenAt: Date

    public init(postId: UUID, groupId: UUID, groupName: String, title: String?, hiddenAt: Date) {
        self.postId = postId
        self.groupId = groupId
        self.groupName = groupName
        self.title = title
        self.hiddenAt = hiddenAt
    }
}

public struct HiddenUser: Equatable, Sendable, Codable {
    public var user: UserSummary
    public var hiddenAt: Date

    public init(user: UserSummary, hiddenAt: Date) {
        self.user = user
        self.hiddenAt = hiddenAt
    }
}
