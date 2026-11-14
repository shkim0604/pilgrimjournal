#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI

/// A scripted `HTTPTransport` that records every request.
final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        return try await handler(request)
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func requests(path suffix: String) -> [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix(suffix) == true }
    }
}

/// A thread-safe counter for handlers.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    var value: Int { lock.withLock { count } }
}

enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let account = "journal-user-hash"
    static let installationID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    static let userID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    static let client = ClientHeader(
        platform: .ios, version: ClientVersion("1.3.0")!, build: "31",
        bundleID: BundleIDs.release)

    static let configuration = GroupServerConfiguration.production(client: client)

    static func credential(
        access: String = "access-1", refresh: String = "refresh-1",
        accessExpiresIn: TimeInterval = 600, refreshExpiresIn: TimeInterval = 86_400
    ) -> GroupCredential {
        GroupCredential(
            accessToken: access, accessTokenExpiresAt: now + accessExpiresIn,
            refreshToken: refresh, refreshTokenExpiresAt: now + refreshExpiresIn, userId: userID)
    }

    static func me() -> MeResponse {
        MeResponse(
            id: userID, displayName: "민지", profileComplete: true, timeZone: "Asia/Seoul",
            dailyReportEnabled: true, dailyReportTime: .defaultDailyReport, createdAt: now,
            entitlement: EntitlementResponse(
                subscriptionRequired: false, active: true, status: .none))
    }

    static func session(access: String, refresh: String) -> AuthSessionResponse {
        AuthSessionResponse(
            accessToken: access, accessTokenExpiresAt: now + SessionLifetime.accessToken,
            refreshToken: refresh, refreshTokenExpiresAt: now + SessionLifetime.refreshToken,
            user: me())
    }

    static let author = UserSummary(id: UUID(), displayName: "요한")

    static func post(
        id: UUID = UUID(), groupID: UUID, createdAt: Date, expiresAt: Date? = nil,
        author: UserSummary = author, commentCount: Int = 0, isUnread: Bool = false
    ) -> PostResponse {
        PostResponse(
            id: id, groupId: groupID, kind: .testimony, author: author, isMine: false,
            body: "간증", timeZone: "Asia/Seoul", createdAt: createdAt,
            expiresAt: expiresAt ?? createdAt + 7 * 86_400, commentCount: commentCount,
            isUnread: isUnread)
    }

    static func comment(id: UUID = UUID(), postID: UUID, createdAt: Date, author: UserSummary)
        -> CommentResponse
    {
        CommentResponse(
            id: id, postId: postID, author: author, isMine: false, body: "아멘", media: [],
            sticker: nil, stickerRemoved: false, createdAt: createdAt)
    }

    static func group(id: UUID = UUID(), name: String = "수요 기도모임", unread: Int = 0)
        -> GroupSummary
    {
        GroupSummary(
            id: id, name: name, status: .active, memberCount: 3, isAdmin: false, admin: nil,
            unreadCount: unread, latestPostAt: nil, notifications: GroupNotificationSettings())
    }

    static func mediaRef(id: UUID = UUID(), expiresAt: Date) -> MediaRef {
        MediaRef(
            id: id, width: 100, height: 100, byteCount: 1_000,
            url: URL(string: "https://pilgrim.delight-house.org/api/media-files/\(id)?exp=1")!,
            urlExpiresAt: expiresAt)
    }

    // MARK: Responses

    static func http(_ request: URLRequest, status: Int, headers: [String: String] = [:])
        -> HTTPURLResponse
    {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers)!
    }

    static func json(_ request: URLRequest, _ value: some Encodable, status: Int = 200) throws
        -> (Data, HTTPURLResponse)
    {
        (
            try PilgrimJSON.encode(value),
            http(request, status: status, headers: ["Content-Type": "application/json"])
        )
    }

    static func error(
        _ request: URLRequest, _ code: APIErrorCode, status: Int? = nil,
        headers: [String: String] = [:]
    ) throws -> (Data, HTTPURLResponse) {
        let body = APIErrorBody(error: APIError(code: code, message: code.rawValue))
        return (
            try PilgrimJSON.encode(body),
            http(request, status: status ?? code.httpStatus, headers: headers)
        )
    }

    static func empty(_ request: URLRequest, status: Int = 204) -> (Data, HTTPURLResponse) {
        (Data(), http(request, status: status))
    }

    /// A client over `transport`, signed in with `credential` unless it is nil.
    static func api(
        credential: GroupCredential? = Fixture.credential(),
        store: InMemoryGroupCredentialStore? = nil,
        configuration: GroupServerConfiguration = Fixture.configuration,
        transport: FakeHTTPTransport
    ) -> (URLSessionGroupAPI, InMemoryGroupCredentialStore) {
        let store =
            store
            ?? InMemoryGroupCredentialStore(
                credentials: credential.map { [account: $0] } ?? [:],
                installationID: installationID)
        let api = URLSessionGroupAPI(
            configuration: configuration, credentialStore: store, credentialAccount: account,
            transport: transport, now: { Fixture.now })
        return (api, store)
    }
}

extension URLRequest {
    var bodyString: String {
        httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var authorization: String? { value(forHTTPHeaderField: "Authorization") }
}
#endif
