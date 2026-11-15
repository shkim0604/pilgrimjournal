import Fluent
import Foundation
import PilgrimAPI
import Vapor
import XCTVapor

@testable import PilgrimServerCore

// Request and fixture helpers for the Posts module tests (S3). Kept here rather than in the
// shared harness so parallel tasks do not edit the same file.

/// `PilgrimAPI.Page` (FluentKit has a `Page` too).
typealias APIPage = PilgrimAPI.Page

extension ServerTestCase {
    /// Sends `/api/v1/<path>` (a path, optionally with a percent-encoded query) as `user`.
    func send(
        _ method: HTTPMethod, _ path: String, as user: User?, body: Data? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> XCTHTTPResponse {
        var headers = try headers(as: user)
        var buffer: ByteBuffer?
        if let body {
            headers.contentType = .json
            buffer = ByteBuffer(data: body)
        }
        // Built by hand: `sendRequest` would percent-encode a `?query` as part of the path.
        let request = XCTHTTPRequest(
            method: method, url: URI(string: "/api/v1/\(path)"), headers: headers,
            body: buffer ?? ByteBufferAllocator().buffer(capacity: 0))
        do {
            return try await app.testable().performTest(request: request)
        } catch {
            XCTFail("\(method) \(path): \(error)", file: file, line: line)
            throw error
        }
    }

    func send(
        _ method: HTTPMethod, _ path: String, as user: User?, json: some Encodable,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> XCTHTTPResponse {
        try await send(
            method, path, as: user, body: try PilgrimJSON.encode(json), file: file, line: line)
    }

    /// Asserts the status (a plain function, so the response can be awaited in the argument).
    func assertStatus(
        _ response: XCTHTTPResponse, _ status: HTTPResponseStatus,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(response.status, status, response.body.string, file: file, line: line)
    }

    /// Asserts the status and, for an error, the code.
    func assertError(
        _ response: XCTHTTPResponse, _ status: UInt, _ code: APIErrorCode,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(response.status.code, status, response.body.string, file: file, line: line)
        XCTAssertEqual(try errorBody(response).code, code, file: file, line: line)
    }
}

extension DatabaseTestCase {
    func createPost(
        _ request: CreatePostRequest, in group: Group, as user: User,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> XCTHTTPResponse {
        try await send(
            .POST, "groups/\(try group.requireID())/posts", as: user, json: request, file: file,
            line: line)
    }

    /// A sticker of `group` made by `creator` (with its media row; no file is written).
    @discardableResult
    func makeSticker(by creator: User, in group: Group) async throws -> Sticker {
        let media = try await fixtures.media(uploadedBy: creator, in: group, purpose: .sticker)
        media.attachedAt = Date()
        try await media.save(on: db)
        let sticker = Sticker(
            groupID: try group.requireID(), createdByID: try creator.requireID(),
            mediaID: try media.requireID(), name: "기쁨", clientID: UUID())
        try await sticker.create(on: db)
        return sticker
    }

    func setStatus(_ status: GroupStatus, of group: Group) async throws {
        group.status = status
        if status == .voting { group.$admin.id = nil }
        if status == .pendingDeletion { group.deleteAt = Date().addingTimeInterval(7 * 86_400) }
        try await group.save(on: db)
    }
}

enum PostRequests {
    static func testimony(_ body: String = "간증 본문", clientId: UUID = UUID(), media: [UUID] = [])
        -> CreatePostRequest
    {
        CreatePostRequest(
            clientId: clientId, kind: .testimony, body: body, timeZone: "Asia/Seoul",
            mediaIds: media)
    }

    static func prayer(
        items: [PrayerItem] = [PrayerItem(text: "가족의 건강")], deadline: LocalDate? = nil,
        visibleDays: Int? = nil, clientId: UUID = UUID()
    ) -> CreatePostRequest {
        CreatePostRequest(
            clientId: clientId, kind: .prayer, items: items, deadline: deadline,
            visibleDays: visibleDays, timeZone: "Asia/Seoul")
    }

    static func bookReport(clientId: UUID = UUID()) -> CreatePostRequest {
        CreatePostRequest(
            clientId: clientId, kind: .bookReport, body: "읽고 느낀 점",
            book: BookInfo(title: "고백록", author: "아우구스티누스"), timeZone: "Asia/Seoul")
    }
}
