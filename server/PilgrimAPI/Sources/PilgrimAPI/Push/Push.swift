import Foundation

/// APNs localization keys (design.md 10절). An exception to the Korean-key String Catalog rule:
/// the server sends these ASCII keys, and the app's catalog holds the `ko`/`en` text. Never
/// rename one without renaming the catalog entry.
public enum PushLocKey {
    public static let groupPushTitle = "GROUP_PUSH_TITLE"
    public static let newPostPrayer = "GROUP_NEW_POST_PRAYER"
    public static let newPostBookReport = "GROUP_NEW_POST_BOOK_REPORT"
    public static let newPostTestimony = "GROUP_NEW_POST_TESTIMONY"
    public static let dailyReportTitle = "DAILY_REPORT_TITLE"
    public static let dailyReportBody = "DAILY_REPORT_BODY"
    public static let adminVoteStarted = "ADMIN_VOTE_STARTED"
    public static let adminVoteRunoff = "ADMIN_VOTE_RUNOFF"
    public static let adminVoteDecided = "ADMIN_VOTE_DECIDED"
    public static let groupDeletionScheduled = "GROUP_DELETION_SCHEDULED"

    public static let all: [String] = [
        groupPushTitle, newPostPrayer, newPostBookReport, newPostTestimony, dailyReportTitle,
        dailyReportBody, adminVoteStarted, adminVoteRunoff, adminVoteDecided,
        groupDeletionScheduled,
    ]

    public static func newPost(_ kind: PostKind) -> String {
        switch kind {
        case .prayer: newPostPrayer
        case .bookReport: newPostBookReport
        case .testimony: newPostTestimony
        }
    }
}

/// `pilgrim.kind`: what a notification is about and which screen tapping it opens.
public enum PushKind: String, Sendable, Codable, CaseIterable {
    case newPost, dailyReport, voteStarted, voteRunoff, voteDecided, groupDeletionScheduled
}

/// The APNs payload the worker sends. Lock screens never carry post content: only the group name
/// and a person's name go in `loc-args`.
public struct PushPayload: Equatable, Sendable, Codable {
    public var aps: APS
    public var pilgrim: Info

    public init(aps: APS, pilgrim: Info) {
        self.aps = aps
        self.pilgrim = pilgrim
    }

    public struct APS: Equatable, Sendable, Codable {
        public var alert: Alert
        public var sound: String?
        public var threadId: String?

        public init(alert: Alert, sound: String? = "default", threadId: String? = nil) {
            self.alert = alert
            self.sound = sound
            self.threadId = threadId
        }

        private enum CodingKeys: String, CodingKey {
            case alert, sound
            case threadId = "thread-id"
        }
    }

    public struct Alert: Equatable, Sendable, Codable {
        public var titleLocKey: String
        public var titleLocArgs: [String]
        public var locKey: String
        public var locArgs: [String]

        public init(titleLocKey: String, titleLocArgs: [String], locKey: String, locArgs: [String])
        {
            self.titleLocKey = titleLocKey
            self.titleLocArgs = titleLocArgs
            self.locKey = locKey
            self.locArgs = locArgs
        }

        private enum CodingKeys: String, CodingKey {
            case titleLocKey = "title-loc-key"
            case titleLocArgs = "title-loc-args"
            case locKey = "loc-key"
            case locArgs = "loc-args"
        }
    }

    /// The app-specific part, used to route a tap.
    public struct Info: Equatable, Sendable, Codable {
        /// Payload format version.
        public var v: Int
        public var kind: PushKind
        public var groupId: UUID?
        public var postId: UUID?

        public init(v: Int = 1, kind: PushKind, groupId: UUID? = nil, postId: UUID? = nil) {
            self.v = v
            self.kind = kind
            self.groupId = groupId
            self.postId = postId
        }
    }

    public static func threadID(groupID: UUID) -> String { "group-\(groupID.pilgrimString)" }
    public static let dailyReportThreadID = "daily-report"

    public static func newPost(
        groupID: UUID, postID: UUID, kind: PostKind, groupName: String, authorName: String
    ) -> PushPayload {
        PushPayload(
            aps: APS(
                alert: Alert(
                    titleLocKey: PushLocKey.groupPushTitle, titleLocArgs: [groupName],
                    locKey: PushLocKey.newPost(kind), locArgs: [authorName]),
                threadId: threadID(groupID: groupID)),
            pilgrim: Info(kind: .newPost, groupId: groupID, postId: postID))
    }

    public static func dailyReport(itemCount: Int) -> PushPayload {
        PushPayload(
            aps: APS(
                alert: Alert(
                    titleLocKey: PushLocKey.dailyReportTitle, titleLocArgs: [],
                    locKey: PushLocKey.dailyReportBody, locArgs: [String(itemCount)]),
                threadId: dailyReportThreadID),
            pilgrim: Info(kind: .dailyReport))
    }

    /// Admin-vote and deletion notices sent to every member of a group.
    public enum GroupEvent: Equatable, Sendable {
        case voteStarted
        case voteRunoff
        case voteDecided(newAdminName: String)
        case deletionScheduled

        var kind: PushKind {
            switch self {
            case .voteStarted: .voteStarted
            case .voteRunoff: .voteRunoff
            case .voteDecided: .voteDecided
            case .deletionScheduled: .groupDeletionScheduled
            }
        }

        var locKey: String {
            switch self {
            case .voteStarted: PushLocKey.adminVoteStarted
            case .voteRunoff: PushLocKey.adminVoteRunoff
            case .voteDecided: PushLocKey.adminVoteDecided
            case .deletionScheduled: PushLocKey.groupDeletionScheduled
            }
        }

        var locArgs: [String] {
            if case .voteDecided(let name) = self { return [name] }
            return []
        }
    }

    public static func group(_ event: GroupEvent, groupID: UUID, groupName: String) -> PushPayload {
        PushPayload(
            aps: APS(
                alert: Alert(
                    titleLocKey: PushLocKey.groupPushTitle, titleLocArgs: [groupName],
                    locKey: event.locKey, locArgs: event.locArgs),
                threadId: threadID(groupID: groupID)),
            pilgrim: Info(kind: event.kind, groupId: groupID))
    }
}
