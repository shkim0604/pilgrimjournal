import Fluent
import Foundation
import PilgrimAPI

@testable import PilgrimServerCore

/// Builders for test data. Everything is saved immediately and returned for further use.
struct TestFixtures {
    let db: any Database

    /// A signed-up user (display name set) unless `displayName` is nil.
    @discardableResult
    func user(
        _ displayName: String? = "테스트", timeZone: String = "Asia/Seoul"
    ) async throws -> User {
        let user = User(
            appleSub: "dev:\(UUID().uuidString.lowercased())", displayName: displayName,
            timeZone: timeZone)
        try await user.create(on: db)
        return user
    }

    /// A group whose admin (and creator) is `admin`, with `members` joined as well.
    @discardableResult
    func group(
        _ name: String = "수요 기도모임", admin: User, members: [User] = []
    ) async throws -> Group {
        let group = Group(name: name, createdByID: try admin.requireID(), clientID: UUID())
        try await group.create(on: db)
        for user in [admin] + members {
            try await Membership(groupID: try group.requireID(), userID: try user.requireID())
                .create(on: db)
        }
        return group
    }

    func join(_ user: User, _ group: Group) async throws {
        try await Membership(groupID: try group.requireID(), userID: try user.requireID())
            .create(on: db)
    }

    /// A post; by default a testimony that expires in a week.
    @discardableResult
    func post(
        by author: User, in group: Group, kind: PostKind = .testimony, body: String = "본문",
        expiresAt: Date = Date().addingTimeInterval(7 * 86_400),
        items: [PrayerItem]? = nil
    ) async throws -> Post {
        let post = Post(
            groupID: try group.requireID(), authorID: try author.requireID(), kind: kind,
            timeZone: "Asia/Seoul", expiresAt: expiresAt, clientID: UUID())
        post.body = body
        post.prayerItems = items
        try await post.create(on: db)
        return post
    }

    /// A media row (no file is written) attached to `post` when given.
    @discardableResult
    func media(
        uploadedBy uploader: User, in group: Group?, purpose: MediaPurpose = .post,
        post: Post? = nil
    ) async throws -> Media {
        let id = UUID()
        let media = Media(
            id: id, uploaderID: try uploader.requireID(), purpose: purpose,
            groupID: try group?.requireID(), filePath: MediaPaths.relativePath(for: id),
            byteCount: 1_024, width: 800, height: 600, sha256: Data(repeating: 0xAB, count: 32),
            clientID: UUID())
        if let post {
            media.$post.id = try post.requireID()
            media.attachedAt = Date()
        }
        try await media.create(on: db)
        return media
    }

    func block(_ blocker: User, _ blocked: User) async throws {
        try await Block(blockerID: try blocker.requireID(), blockedID: try blocked.requireID())
            .create(on: db)
    }

    func hide(post: Post, by user: User) async throws {
        try await Hide(userID: try user.requireID(), postID: try post.requireID()).create(on: db)
    }

    func hide(user target: User, by user: User) async throws {
        try await Hide(userID: try user.requireID(), targetUserID: try target.requireID())
            .create(on: db)
    }
}
