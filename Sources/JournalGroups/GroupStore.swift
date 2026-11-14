import Foundation
import PilgrimAPI

/// The in-memory cache behind the group screens: the group list, each group's feed (newest
/// first, cursor-paged), post details, comment threads (oldest first) and unread counts.
///
/// A value type with no I/O and no observation, so it is fully testable; the app's
/// `@MainActor` models own one and publish it. Every read that takes `now` hides posts whose
/// `expiresAt <= now` (the server stops serving them at that moment), and
/// `removeExpired(now:)` drops them for good.
public struct GroupStore: Equatable, Sendable {
    public struct Feed: Equatable, Sendable {
        /// Newest first.
        public var posts: [PostResponse] = []
        /// The cursor for the next older page; nil once the end is reached.
        public var nextCursor: String?
        /// Whether the first page has been loaded at least once.
        public var isLoaded = false

        public init(posts: [PostResponse] = [], nextCursor: String? = nil, isLoaded: Bool = false) {
            self.posts = posts
            self.nextCursor = nextCursor
            self.isLoaded = isLoaded
        }

        public var hasMore: Bool { nextCursor != nil }
    }

    public struct CommentThread: Equatable, Sendable {
        /// Oldest first.
        public var comments: [CommentResponse] = []
        public var nextCursor: String?
        public var isLoaded = false

        public init(
            comments: [CommentResponse] = [], nextCursor: String? = nil, isLoaded: Bool = false
        ) {
            self.comments = comments
            self.nextCursor = nextCursor
            self.isLoaded = isLoaded
        }

        public var hasMore: Bool { nextCursor != nil }
    }

    /// In the server's order.
    public private(set) var groups: [GroupSummary] = []
    public private(set) var groupDetails: [UUID: GroupDetail] = [:]
    public private(set) var feeds: [UUID: Feed] = [:]
    /// Posts opened on their own (a notification, a Daily Report row) that may not be in a feed.
    public private(set) var postDetails: [UUID: PostResponse] = [:]
    public private(set) var threads: [UUID: CommentThread] = [:]

    public init() {}

    // MARK: Groups

    /// The `GET /groups` answer. Groups that are gone take their feeds and threads with them.
    public mutating func replaceGroups(_ summaries: [GroupSummary]) {
        let kept = Set(summaries.map(\.id))
        for id in Set(groups.map(\.id)).union(feeds.keys).union(groupDetails.keys)
        where !kept.contains(id) {
            dropGroupContent(id)
        }
        groups = summaries
        for summary in summaries {
            groupDetails[summary.id]?.apply(summary)
        }
    }

    /// A group from `GET /groups/:id`, create, rename, accept or transfer.
    public mutating func upsertGroup(_ detail: GroupDetail) {
        groupDetails[detail.id] = detail
        upsertSummary(detail.summary)
    }

    public mutating func upsertSummary(_ summary: GroupSummary) {
        if let index = groups.firstIndex(where: { $0.id == summary.id }) {
            groups[index] = summary
        } else {
            groups.append(summary)
        }
        groupDetails[summary.id]?.apply(summary)
    }

    /// After leaving, deletion, `NOT_FOUND` or `REMOVED_FROM_GROUP`.
    public mutating func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        dropGroupContent(id)
    }

    public func group(id: UUID) -> GroupSummary? {
        groups.first { $0.id == id }
    }

    private mutating func dropGroupContent(_ id: UUID) {
        groupDetails[id] = nil
        let postIDs = Set((feeds[id]?.posts ?? []).map(\.id))
            .union(postDetails.values.filter { $0.groupId == id }.map(\.id))
        feeds[id] = nil
        for postID in postIDs {
            postDetails[postID] = nil
            threads[postID] = nil
        }
    }

    // MARK: Unread

    public func unreadCount(groupID: UUID) -> Int {
        group(id: groupID)?.unreadCount ?? 0
    }

    public var totalUnreadCount: Int {
        groups.reduce(0) { $0 + max(0, $1.unreadCount) }
    }

    /// After `POST /groups/:id/seen`: no unread posts in that group.
    public mutating func markSeen(groupID: UUID) {
        if let index = groups.firstIndex(where: { $0.id == groupID }) {
            groups[index].unreadCount = 0
        }
        groupDetails[groupID]?.unreadCount = 0
        if var feed = feeds[groupID] {
            for index in feed.posts.indices { feed.posts[index].isUnread = false }
            feeds[groupID] = feed
        }
        for (id, post) in postDetails where post.groupId == groupID {
            postDetails[id]?.isUnread = false
        }
    }

    // MARK: Feeds

    /// The visible feed of a group at `now`.
    public func posts(groupID: UUID, now: Date) -> [PostResponse] {
        (feeds[groupID]?.posts ?? []).filter { $0.expiresAt > now }
    }

    public func feed(groupID: UUID) -> Feed? {
        feeds[groupID]
    }

    /// The first page (`cursor = nil`), from opening the feed, pull-to-refresh or polling.
    ///
    /// Posts newer than the page's oldest item come from the page alone, so a post deleted,
    /// hidden or expired on the server disappears. Older pages already loaded are kept with
    /// their cursor; a page without `nextCursor` is the whole feed.
    public mutating func applyFirstPage(_ page: Page<PostResponse>, groupID: UUID, now: Date) {
        let incoming = Self.sortedNewestFirst(page.items.filter { $0.expiresAt > now })
        var feed = feeds[groupID] ?? Feed()
        if page.nextCursor == nil || page.items.isEmpty {
            feed.posts = incoming
            feed.nextCursor = page.nextCursor
        } else {
            let oldest = Self.sortedNewestFirst(page.items).last!
            let pageIDs = Set(page.items.map(\.id))
            let older = feed.posts.filter {
                !pageIDs.contains($0.id) && Self.isNewer(oldest, than: $0) && $0.expiresAt > now
            }
            feed.posts = incoming + older
            feed.nextCursor = older.isEmpty ? page.nextCursor : feed.nextCursor
        }
        feed.isLoaded = true
        feeds[groupID] = feed
        for post in incoming where postDetails[post.id] != nil { postDetails[post.id] = post }
    }

    /// A following page (`cursor = feed.nextCursor`). Duplicates replace what is cached.
    public mutating func applyNextPage(_ page: Page<PostResponse>, groupID: UUID, now: Date) {
        var feed = feeds[groupID] ?? Feed()
        var byID = Dictionary(feed.posts.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for post in page.items { byID[post.id] = post }
        feed.posts = Self.sortedNewestFirst(byID.values.filter { $0.expiresAt > now })
        feed.nextCursor = page.nextCursor
        feed.isLoaded = true
        feeds[groupID] = feed
    }

    /// A post from create, detail, extend or a reaction change. Lands in its group's feed when
    /// that feed is loaded.
    public mutating func upsertPost(_ post: PostResponse) {
        if postDetails[post.id] != nil || feeds[post.groupId]?.isLoaded != true {
            postDetails[post.id] = post
        }
        guard var feed = feeds[post.groupId], feed.isLoaded else { return }
        if let index = feed.posts.firstIndex(where: { $0.id == post.id }) {
            feed.posts[index] = post
        } else {
            feed.posts = Self.sortedNewestFirst(feed.posts + [post])
        }
        feeds[post.groupId] = feed
    }

    /// The post by ID, nil when unknown or expired at `now`.
    public func post(id: UUID, now: Date) -> PostResponse? {
        let found =
            postDetails[id]
            ?? feeds.values.lazy.compactMap { $0.posts.first { $0.id == id } }.first
        guard let found, found.expiresAt > now else { return nil }
        return found
    }

    /// After delete, hide, report-and-hide or a `NOT_FOUND` on the post.
    public mutating func removePost(id: UUID) {
        postDetails[id] = nil
        threads[id] = nil
        for (groupID, var feed) in feeds {
            let before = feed.posts.count
            feed.posts.removeAll { $0.id == id }
            if feed.posts.count != before { feeds[groupID] = feed }
        }
    }

    /// After hiding or blocking a person: their posts and comments disappear everywhere.
    public mutating func removeContent(byAuthor userID: UUID) {
        let postIDs = Set(
            feeds.values.flatMap(\.posts).filter { $0.author.id == userID }.map(\.id)
                + postDetails.values.filter { $0.author.id == userID }.map(\.id))
        for id in postIDs { removePost(id: id) }
        for (postID, var thread) in threads {
            let removed = thread.comments.filter { $0.author.id == userID }.count
            guard removed > 0 else { continue }
            thread.comments.removeAll { $0.author.id == userID }
            threads[postID] = thread
            adjustCommentCount(postID: postID, by: -removed)
        }
    }

    public mutating func updateReactions(postID: UUID, _ reactions: [ReactionSummary]) {
        mutatePost(id: postID) { $0.reactions = reactions }
    }

    /// Drops every post with `expiresAt <= now`. Returns the IDs removed, so an open detail
    /// screen can switch to "이 글은 더 이상 볼 수 없어요".
    @discardableResult
    public mutating func removeExpired(now: Date) -> Set<UUID> {
        var removed = Set<UUID>()
        for (groupID, var feed) in feeds {
            let expired = feed.posts.filter { $0.expiresAt <= now }.map(\.id)
            guard !expired.isEmpty else { continue }
            removed.formUnion(expired)
            feed.posts.removeAll { $0.expiresAt <= now }
            feeds[groupID] = feed
        }
        for (id, post) in postDetails where post.expiresAt <= now {
            removed.insert(id)
            postDetails[id] = nil
        }
        for id in removed { threads[id] = nil }
        return removed
    }

    /// When the next post in the cache expires (to schedule the next `removeExpired`).
    public func nextExpiry(after now: Date) -> Date? {
        (feeds.values.flatMap(\.posts) + postDetails.values)
            .map(\.expiresAt)
            .filter { $0 > now }
            .min()
    }

    // MARK: Comments

    public func comments(postID: UUID) -> [CommentResponse] {
        threads[postID]?.comments ?? []
    }

    public func thread(postID: UUID) -> CommentThread? {
        threads[postID]
    }

    /// The first (oldest) page replaces the thread.
    public mutating func applyFirstCommentPage(_ page: Page<CommentResponse>, postID: UUID) {
        threads[postID] = CommentThread(
            comments: Self.sortedOldestFirst(page.items), nextCursor: page.nextCursor,
            isLoaded: true)
    }

    public mutating func applyNextCommentPage(_ page: Page<CommentResponse>, postID: UUID) {
        var thread = threads[postID] ?? CommentThread()
        var byID = Dictionary(
            thread.comments.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for comment in page.items { byID[comment.id] = comment }
        thread.comments = Self.sortedOldestFirst(Array(byID.values))
        thread.nextCursor = page.nextCursor
        thread.isLoaded = true
        threads[postID] = thread
    }

    /// A comment the user just wrote (or a retry that returned the first one).
    public mutating func upsertComment(_ comment: CommentResponse) {
        var thread = threads[comment.postId] ?? CommentThread()
        if let index = thread.comments.firstIndex(where: { $0.id == comment.id }) {
            thread.comments[index] = comment
        } else {
            thread.comments = Self.sortedOldestFirst(thread.comments + [comment])
            adjustCommentCount(postID: comment.postId, by: 1)
        }
        threads[comment.postId] = thread
    }

    public mutating func removeComment(id: UUID, postID: UUID) {
        guard var thread = threads[postID],
            let index = thread.comments.firstIndex(where: { $0.id == id })
        else { return }
        thread.comments.remove(at: index)
        threads[postID] = thread
        adjustCommentCount(postID: postID, by: -1)
    }

    // MARK: Helpers

    private mutating func adjustCommentCount(postID: UUID, by delta: Int) {
        mutatePost(id: postID) { $0.commentCount = max(0, $0.commentCount + delta) }
    }

    private mutating func mutatePost(id: UUID, _ change: (inout PostResponse) -> Void) {
        if var post = postDetails[id] {
            change(&post)
            postDetails[id] = post
        }
        for (groupID, var feed) in feeds {
            guard let index = feed.posts.firstIndex(where: { $0.id == id }) else { continue }
            change(&feed.posts[index])
            feeds[groupID] = feed
        }
    }

    /// The server's feed order: `(createdAt, id)` descending.
    static func isNewer(_ lhs: PostResponse, than rhs: PostResponse) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.pilgrimString > rhs.id.pilgrimString
    }

    static func sortedNewestFirst(_ posts: some Sequence<PostResponse>) -> [PostResponse] {
        posts.sorted(by: isNewer)
    }

    static func sortedOldestFirst(_ comments: [CommentResponse]) -> [CommentResponse] {
        comments.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.pilgrimString < $1.id.pilgrimString
        }
    }
}

extension GroupDetail {
    fileprivate mutating func apply(_ summary: GroupSummary) {
        name = summary.name
        status = summary.status
        memberCount = summary.memberCount
        isAdmin = summary.isAdmin
        admin = summary.admin
        unreadCount = summary.unreadCount
        latestPostAt = summary.latestPostAt
        notifications = summary.notifications
        voteEndsAt = summary.voteEndsAt
        deleteAt = summary.deleteAt
    }
}
