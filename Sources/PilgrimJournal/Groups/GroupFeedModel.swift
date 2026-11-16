import Combine
import Foundation
import JournalGroups
import PilgrimAPI

/// The text a group screen shows for a failed `GroupAPI` call. The server's `error.code` picks
/// it; the server's own `message` is never shown.
enum GroupContentError {
    static let offlineMessage = String(localized: "그룹 서버에 연결할 수 없어요. 다시 시도해 주세요")
    static let goneMessage = String(localized: "이 글은 더 이상 볼 수 없어요")

    static func message(for error: any Error) -> String {
        guard let error = error as? GroupAPIError else {
            return String(localized: "요청을 처리하지 못했어요. 다시 시도해 주세요")
        }
        switch error {
        case .offline, .timedOut:
            return offlineMessage
        case .notSignedIn:
            return String(localized: "그룹에 다시 로그인해 주세요")
        case .invalidResponse, .cancelled:
            return String(localized: "요청을 처리하지 못했어요. 다시 시도해 주세요")
        case .server(_, let apiError):
            return message(for: apiError)
        }
    }

    private static func message(for error: APIError) -> String {
        switch error.code {
        case .notFound:
            return goneMessage
        case .groupPendingDeletion:
            return String(localized: "삭제 예정인 그룹이라 새로 쓸 수 없어요")
        case .adminVoteInProgress:
            return String(localized: "새 관리자를 뽑는 중이라 지금은 할 수 없어요")
        case .stickerLimitReached:
            return String(localized: "이 그룹의 스티커는 30개까지예요")
        case .limitExceeded:
            if error.field == "key" {
                return String(localized: "반응은 한 글에 10개까지 남길 수 있어요")
            }
            if error.field == "mediaIds" {
                return String(localized: "사진은 4장까지 붙일 수 있어요")
            }
            return String(localized: "입력한 내용이 너무 길어요")
        case .validationFailed, .invalidRequest:
            return String(localized: "입력한 내용을 확인해 주세요")
        case .mediaInvalid, .mediaNotAttachable:
            return String(localized: "이 사진은 올릴 수 없어요")
        case .mediaTooLarge:
            return String(localized: "사진이 너무 커요")
        case .extendNotAllowed:
            return String(localized: "독후감만 토론을 연장할 수 있어요")
        case .rateLimited:
            return String(localized: "잠시 후 다시 시도해 주세요")
        case .forbidden:
            return String(localized: "이 작업을 할 권한이 없어요")
        case .cannotTargetSelf:
            return String(localized: "자기 자신에게는 할 수 없어요")
        case .removedFromGroup:
            return String(localized: "이 그룹에서 내보내졌어요")
        case .signupRequired:
            return String(localized: "그룹 가입을 먼저 마쳐 주세요")
        case .accountSuspended:
            return String(localized: "계정이 일시 정지되었어요")
        case .clientUpgradeRequired:
            return String(localized: "그룹을 쓰려면 앱을 업데이트해 주세요")
        case .unauthenticated, .tokenExpired, .refreshTokenInvalid, .refreshTokenReused:
            return String(localized: "그룹에 다시 로그인해 주세요")
        case .serviceUnavailable, .internal:
            return offlineMessage
        default:
            return String(localized: "요청을 처리하지 못했어요. 다시 시도해 주세요")
        }
    }

    /// The post (or what was asked for) no longer exists for this user: expired, taken down,
    /// hidden or blocked.
    static func isGone(_ error: any Error) -> Bool {
        (error as? GroupAPIError)?.code == .notFound
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? GroupAPIError) == .cancelled
    }
}

/// A change one group screen made that the others showing the same content should apply at
/// once, instead of waiting for the next poll.
enum GroupContentEvent: Equatable, Sendable {
    case postCreated(PostResponse)
    case postUpdated(PostResponse)
    case postRemoved(postID: UUID)
    /// The user hid or blocked this person: their posts leave every feed.
    case authorHidden(userID: UUID)
}

@MainActor
protocol GroupContentObserver: AnyObject {
    func apply(_ event: GroupContentEvent)
}

/// Delivers `GroupContentEvent`s between the feed, the detail column and the composer, which
/// ContentView builds independently. Observers are held weakly.
@MainActor
final class GroupContentEvents {
    static let shared = GroupContentEvents()

    private final class WeakObserver {
        weak var value: (any GroupContentObserver)?
        init(_ value: any GroupContentObserver) { self.value = value }
    }

    private var observers: [WeakObserver] = []

    func add(_ observer: any GroupContentObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        observers.append(WeakObserver(observer))
    }

    func send(_ event: GroupContentEvent) {
        observers.removeAll { $0.value == nil }
        for observer in observers {
            observer.value?.apply(event)
        }
    }
}

/// One group's feed: newest first, cursor-paged, refreshed every 15 seconds while on screen.
///
/// Expired posts are dropped on the client as soon as `expiresAt` passes (the server also stops
/// returning them), so a post never lingers until the next poll.
@MainActor
final class GroupFeedModel: ObservableObject, GroupContentObserver {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    static let pollInterval: Duration = .seconds(15)

    /// Every loaded post, expired or not, in server order.
    @Published private(set) var loadedPosts: [PostResponse] = []
    /// nil = 전체.
    @Published var kindFilter: PostKind?
    @Published private(set) var nextCursor: String?
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var isLoadingMore = false
    /// A failed refresh while posts are already on screen; the posts stay.
    @Published private(set) var refreshError: String?
    @Published private(set) var isPolling = false

    let groupID: UUID
    let api: any GroupAPI
    private let now: () -> Date
    private let pageSize: Int
    private let pollInterval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var isRefreshing = false
    /// Older pages were loaded with `loadMore()`; a refresh keeps them below the first page.
    private var hasPagedBeyondFirst = false

    init(
        api: any GroupAPI,
        groupID: UUID,
        now: @escaping () -> Date = { Date() },
        pageSize: Int = Page<PostResponse>.defaultLimit,
        pollInterval: Duration = GroupFeedModel.pollInterval,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        events: GroupContentEvents? = .shared
    ) {
        self.api = api
        self.groupID = groupID
        self.now = now
        self.pageSize = pageSize
        self.pollInterval = pollInterval
        self.sleep = sleep
        events?.add(self)
    }

    /// The posts the feed shows: not expired, matching the kind filter.
    var posts: [PostResponse] {
        let current = now()
        return loadedPosts.filter { post in
            post.expiresAt > current && (kindFilter == nil || post.kind == kindFilter)
        }
    }

    var hasMore: Bool { nextCursor != nil }

    /// First load when the feed appears: the first page, then tells the server the group was
    /// seen so the sidebar's unread count matches.
    func start() async {
        await refresh()
        if loadState == .loaded {
            try? await api.markSeen(groupID: groupID)
        }
    }

    /// Reloads the first page and merges it into what is loaded.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        if loadedPosts.isEmpty, loadState != .loaded { loadState = .loading }
        do {
            let page = try await api.posts(groupID: groupID, cursor: nil, limit: pageSize)
            merge(firstPage: page)
            loadState = .loaded
            refreshError = nil
        } catch {
            if GroupContentError.isCancellation(error) {
                if loadState == .loading { loadState = .idle }
                return
            }
            let message = GroupContentError.message(for: error)
            if loadedPosts.isEmpty {
                loadState = .failed(message)
            } else {
                refreshError = message
            }
        }
    }

    /// Loads the next older page.
    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await api.posts(groupID: groupID, cursor: cursor, limit: pageSize)
            for post in page.items {
                if let index = loadedPosts.firstIndex(where: { $0.id == post.id }) {
                    loadedPosts[index] = post
                } else {
                    loadedPosts.append(post)
                }
            }
            nextCursor = page.nextCursor
            hasPagedBeyondFirst = true
        } catch {
            if GroupContentError.isCancellation(error) { return }
            refreshError = GroupContentError.message(for: error)
        }
    }

    /// Loads the next page when the last shown post appears.
    func loadMoreIfNeeded(after post: PostResponse) async {
        guard post.id == posts.last?.id else { return }
        await loadMore()
    }

    /// Refreshes every `pollInterval` until the calling task is cancelled (the view's `.task`
    /// ends when the feed leaves the screen).
    func pollWhileVisible() async {
        isPolling = true
        defer { isPolling = false }
        while !Task.isCancelled {
            do {
                try await sleep(pollInterval)
            } catch {
                break
            }
            if Task.isCancelled { break }
            await refresh()
        }
    }

    func apply(_ event: GroupContentEvent) {
        switch event {
        case .postCreated(let post):
            guard post.groupId == groupID else { return }
            if let index = loadedPosts.firstIndex(where: { $0.id == post.id }) {
                loadedPosts[index] = post
            } else {
                loadedPosts.insert(post, at: 0)
            }
        case .postUpdated(let post):
            guard let index = loadedPosts.firstIndex(where: { $0.id == post.id }) else { return }
            loadedPosts[index] = post
        case .postRemoved(let postID):
            loadedPosts.removeAll { $0.id == postID }
        case .authorHidden(let userID):
            loadedPosts.removeAll { $0.author.id == userID }
        }
    }

    private func merge(firstPage page: Page<PostResponse>) {
        guard hasPagedBeyondFirst, let oldest = page.items.last else {
            loadedPosts = page.items
            nextCursor = page.nextCursor
            hasPagedBeyondFirst = false
            return
        }
        let firstPageIDs = Set(page.items.map(\.id))
        let older = loadedPosts.filter { post in
            !firstPageIDs.contains(post.id) && Self.isOlder(post, than: oldest)
        }
        loadedPosts = page.items + older
    }

    /// The server's feed order: `createdAt` descending, then the ID.
    static func isOlder(_ post: PostResponse, than other: PostResponse) -> Bool {
        if post.createdAt != other.createdAt { return post.createdAt < other.createdAt }
        return post.id.pilgrimString < other.id.pilgrimString
    }
}
