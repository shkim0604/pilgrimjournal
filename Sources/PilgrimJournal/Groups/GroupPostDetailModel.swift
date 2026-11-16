import Combine
import Foundation
import JournalGroups
import PilgrimAPI

/// One post with its comments, reactions and the group's stickers, plus every action the
/// detail column offers: react, comment, extend a book report's discussion, take down, hide,
/// block and report.
///
/// Comments are only shown here; they are never pushed (the Daily Report gathers them).
@MainActor
final class GroupPostDetailModel: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded
        /// Expired, taken down, hidden or blocked: "이 글은 더 이상 볼 수 없어요".
        case gone
        case failed(String)
    }

    /// The system emoji offered in the reaction picker.
    static let reactionEmoji = ["🙏", "❤️", "🙌", "😢", "😊", "👍", "🔥", "✨"]

    @Published private(set) var state: State = .loading
    @Published private(set) var post: PostResponse?
    @Published private(set) var comments: [CommentResponse] = []
    @Published private(set) var commentsCursor: String?
    @Published private(set) var stickers: [StickerResponse] = []
    /// A transient message (failure or limit) shown above the comment bar.
    @Published var notice: String?
    @Published private(set) var isWorking = false

    // Comment composer
    @Published var commentText = ""
    @Published var commentSticker: StickerResponse?
    @Published private(set) var commentPhotos: [GroupComposerPhoto] = []
    @Published private(set) var isSendingComment = false

    let postID: UUID
    let groupID: UUID
    /// The user runs this group (false while an admin vote is open).
    let isAdmin: Bool
    let api: any GroupAPI
    private let uploader: GroupPhotoUploader
    private let policy: PostExpiryPolicy
    private let events: GroupContentEvents?
    private var commentClientID = UUID()
    private var extendClientID: UUID?
    private var stickerClientID = UUID()

    init(
        api: any GroupAPI,
        postID: UUID,
        groupID: UUID,
        isAdmin: Bool,
        prepareImage: @escaping GroupImagePreparer = GroupImagePreparation.identity,
        policy: PostExpiryPolicy = PostExpiryPolicy(),
        events: GroupContentEvents? = .shared
    ) {
        self.api = api
        self.postID = postID
        self.groupID = groupID
        self.isAdmin = isAdmin
        self.uploader = GroupPhotoUploader(api: api, prepare: prepareImage)
        self.policy = policy
        self.events = events
    }

    // MARK: Loading

    func load() async {
        if post == nil { state = .loading }
        do {
            let post = try await api.post(id: postID)
            self.post = post
            state = .loaded
        } catch {
            if GroupContentError.isCancellation(error) { return }
            if GroupContentError.isGone(error) {
                markGone()
            } else if post == nil {
                state = .failed(GroupContentError.message(for: error))
            } else {
                notice = GroupContentError.message(for: error)
            }
            return
        }
        await reloadComments()
        if let stickers = try? await api.stickers(groupID: groupID) {
            self.stickers = stickers
        }
    }

    func reloadComments() async {
        do {
            let page = try await api.comments(postID: postID, cursor: nil, limit: nil)
            comments = page.items
            commentsCursor = page.nextCursor
        } catch {
            handle(error)
        }
    }

    func loadMoreComments() async {
        guard let cursor = commentsCursor else { return }
        do {
            let page = try await api.comments(postID: postID, cursor: cursor, limit: nil)
            let known = Set(comments.map(\.id))
            comments.append(contentsOf: page.items.filter { !known.contains($0.id) })
            commentsCursor = page.nextCursor
        } catch {
            handle(error)
        }
    }

    // MARK: Reactions

    /// Distinct reactions the user put on this post.
    var myReactionCount: Int { post?.reactions.filter(\.reactedByMe).count ?? 0 }

    func hasReacted(_ key: ReactionKey) -> Bool {
        post?.reactions.contains { $0.key == key && $0.reactedByMe } ?? false
    }

    /// Whether `key` can be added (removing is always possible).
    func canAddReaction(_ key: ReactionKey) -> Bool {
        hasReacted(key) || myReactionCount < APILimits.reactionsPerUserPerPost
    }

    /// Adds the reaction, or removes it when the user already reacted with it. A user has at
    /// most 10 distinct reactions per post.
    func toggleReaction(_ key: ReactionKey) async {
        guard post != nil else { return }
        let remove = hasReacted(key)
        guard remove || myReactionCount < APILimits.reactionsPerUserPerPost else {
            notice = String(localized: "반응은 한 글에 10개까지 남길 수 있어요")
            return
        }
        do {
            let summaries =
                remove
                ? try await api.removeReaction(postID: postID, key: key)
                : try await api.react(postID: postID, ReactionRequest(key: key))
            post?.reactions = summaries
            publishUpdate()
        } catch {
            handle(error)
        }
    }

    func sticker(for key: ReactionKey) -> StickerResponse? {
        guard case .sticker(let id) = key else { return nil }
        return stickers.first { $0.id == id }
    }

    // MARK: Discussion extension

    /// Only book reports are extended, by any member.
    var canExtend: Bool { post?.kind == .bookReport }

    /// The new end the confirmation shows: the current `expiresAt` + 7 days.
    var extendedExpiryPreview: Date? {
        guard canExtend, let post else { return nil }
        return policy.extended(post.expiresAt)
    }

    /// `POST /posts/:id/extend`. A retry after a failure reuses the same `clientId`, so one
    /// confirmation never extends twice.
    @discardableResult
    func extendDiscussion() async -> Bool {
        guard canExtend else { return false }
        let clientID = extendClientID ?? UUID()
        extendClientID = clientID
        isWorking = true
        defer { isWorking = false }
        do {
            post = try await api.extendPost(id: postID, ExtendPostRequest(clientId: clientID))
            extendClientID = nil
            publishUpdate()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: Take down, hide, block

    var canDeletePost: Bool { post.map { $0.isMine || isAdmin } ?? false }

    /// Deletes the post for everyone (author or admin). Returns whether the detail should close.
    @discardableResult
    func deletePost() async -> Bool {
        guard canDeletePost else { return false }
        return await perform {
            try await self.api.deletePost(id: self.postID)
        } onSuccess: {
            self.events?.send(.postRemoved(postID: self.postID))
            self.markGone()
        }
    }

    /// Hides this post on the user's devices.
    @discardableResult
    func hidePost() async -> Bool {
        await perform {
            try await self.api.hidePost(id: self.postID)
        } onSuccess: {
            self.events?.send(.postRemoved(postID: self.postID))
            self.markGone()
        }
    }

    /// Hides everything this person posts, in every group, on the user's devices.
    @discardableResult
    func hide(_ user: UserSummary) async -> Bool {
        await perform {
            try await self.api.hideUser(id: user.id)
        } onSuccess: {
            self.removeEverything(by: user.id)
        }
    }

    /// Blocks this person both ways.
    @discardableResult
    func block(_ user: UserSummary) async -> Bool {
        await perform {
            try await self.api.block(userID: user.id)
        } onSuccess: {
            self.removeEverything(by: user.id)
        }
    }

    var postAuthor: UserSummary? { post?.author }

    // MARK: Comments

    var trimmedCommentText: String {
        commentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSendComment: Bool {
        !isSendingComment && commentText.count <= APILimits.commentBodyMax
            && (!trimmedCommentText.isEmpty || commentSticker != nil || !commentPhotos.isEmpty)
    }

    func addCommentPhotos(_ data: [Data]) {
        let room = APILimits.photosPerComment - commentPhotos.count
        if data.count > room { notice = String(localized: "사진은 4장까지 붙일 수 있어요") }
        guard room > 0 else { return }
        commentPhotos.append(contentsOf: data.prefix(room).map { GroupComposerPhoto(data: $0) })
    }

    func removeCommentPhoto(_ id: UUID) {
        commentPhotos.removeAll { $0.id == id }
    }

    /// Posts the comment; a failure keeps the text, sticker and photos for a retry with the
    /// same `clientId`.
    @discardableResult
    func sendComment() async -> Bool {
        guard canSendComment else { return false }
        isSendingComment = true
        defer { isSendingComment = false }
        do {
            var mediaIDs: [UUID] = []
            for photo in commentPhotos {
                if let mediaID = photo.mediaID {
                    mediaIDs.append(mediaID)
                    continue
                }
                let media = try await uploader.upload(photo, purpose: .comment, groupID: groupID)
                if let index = commentPhotos.firstIndex(where: { $0.id == photo.id }) {
                    commentPhotos[index].mediaID = media.id
                }
                mediaIDs.append(media.id)
            }
            let comment = try await api.createComment(
                postID: postID,
                CreateCommentRequest(
                    clientId: commentClientID, body: trimmedCommentText, mediaIds: mediaIDs,
                    stickerId: commentSticker?.id))
            if !comments.contains(where: { $0.id == comment.id }) {
                comments.append(comment)
                post?.commentCount += 1
            }
            commentText = ""
            commentSticker = nil
            commentPhotos = []
            commentClientID = UUID()
            notice = nil
            publishUpdate()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func canDelete(_ comment: CommentResponse) -> Bool { comment.isMine || isAdmin }

    @discardableResult
    func deleteComment(_ comment: CommentResponse) async -> Bool {
        guard canDelete(comment) else { return false }
        return await perform {
            try await self.api.deleteComment(id: comment.id)
        } onSuccess: {
            self.comments.removeAll { $0.id == comment.id }
            if let count = self.post?.commentCount { self.post?.commentCount = max(0, count - 1) }
            self.publishUpdate()
        }
    }

    // MARK: Stickers

    var canCreateSticker: Bool { stickers.count < APILimits.stickersPerGroup }

    func canDelete(_ sticker: StickerResponse) -> Bool { sticker.isMine || isAdmin }

    /// Makes a group sticker from an already square-cropped JPEG (`GroupStickerCropper`).
    @discardableResult
    func createSticker(jpeg: Data, name: String?) async -> StickerResponse? {
        guard canCreateSticker else {
            notice = String(localized: "이 그룹의 스티커는 30개까지예요")
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let media = try await uploader.upload(
                GroupComposerPhoto(id: stickerClientID, data: jpeg), purpose: .sticker,
                groupID: groupID)
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sticker = try await api.createSticker(
                groupID: groupID,
                CreateStickerRequest(
                    clientId: stickerClientID, mediaId: media.id,
                    name: trimmed.isEmpty ? nil : trimmed))
            stickerClientID = UUID()
            if !stickers.contains(where: { $0.id == sticker.id }) { stickers.append(sticker) }
            return sticker
        } catch {
            handle(error)
            return nil
        }
    }

    /// Deletes a sticker (its creator or the admin): reactions with it disappear and comments
    /// that used it show "지워진 스티커".
    @discardableResult
    func deleteSticker(_ sticker: StickerResponse) async -> Bool {
        guard canDelete(sticker) else { return false }
        return await perform {
            try await self.api.deleteSticker(id: sticker.id)
        } onSuccess: {
            self.stickers.removeAll { $0.id == sticker.id }
            self.post?.reactions.removeAll { $0.key == .sticker(sticker.id) }
            for index in self.comments.indices where self.comments[index].sticker?.id == sticker.id
            {
                self.comments[index].sticker = nil
                self.comments[index].stickerRemoved = true
            }
            if self.commentSticker?.id == sticker.id { self.commentSticker = nil }
            self.publishUpdate()
        }
    }

    // MARK: Helpers

    private func perform(
        _ action: @escaping () async throws -> Void, onSuccess: () -> Void
    ) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await action()
            onSuccess()
            return true
        } catch {
            handle(error)
            return false
        }
    }

    private func handle(_ error: any Error) {
        if GroupContentError.isCancellation(error) { return }
        notice = GroupContentError.message(for: error)
    }

    private func markGone() {
        post = nil
        comments = []
        state = .gone
    }

    private func removeEverything(by userID: UUID) {
        events?.send(.authorHidden(userID: userID))
        if post?.author.id == userID {
            markGone()
            return
        }
        let before = comments.count
        comments.removeAll { $0.author.id == userID }
        if let count = post?.commentCount {
            post?.commentCount = max(0, count - (before - comments.count))
        }
        publishUpdate()
    }

    private func publishUpdate() {
        guard let post else { return }
        events?.send(.postUpdated(post))
    }
}
