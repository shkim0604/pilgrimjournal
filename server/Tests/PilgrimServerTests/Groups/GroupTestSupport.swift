import Fluent
import Foundation
import NIOCore
import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// Request helpers for the Groups, Invites and Votes route tests (S2).
extension ServerTestCase {
    /// Sends a request as `user` with an optional `PilgrimJSON` body.
    func send(
        _ method: HTTPMethod, _ path: String, as user: User? = nil,
        json body: (any Encodable)? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> XCTHTTPResponse {
        var headers = try headers(as: user)
        var buffer: ByteBuffer?
        if let body {
            headers.contentType = .json
            buffer = ByteBuffer(data: try PilgrimJSON.encode(body))
        }
        return try await app.sendRequest(
            method, path, headers: headers, body: buffer, file: file, line: line)
    }

    /// Asserts the status and, for errors, the `APIErrorCode`.
    func assertError(
        _ response: XCTHTTPResponse, _ code: APIErrorCode, file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            Int(response.status.code), code.httpStatus, response.body.string, file: file,
            line: line)
        XCTAssertEqual(try errorBody(response).code, code, file: file, line: line)
    }
}

struct EmptyJSON: Codable, Equatable, Sendable {}

// Eager versions of the XCTest assertions: their arguments may contain `await`, which XCTest's
// autoclosures do not allow.

func expectEqual<T: Equatable>(
    _ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertEqual(a, b, message, file: file, line: line)
}

func expectEqual<T: FloatingPoint>(
    _ a: T, _ b: T, accuracy: T, _ message: String = "", file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(a, b, accuracy: accuracy, message, file: file, line: line)
}

func expectLessThanOrEqual<T: Comparable>(
    _ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertLessThanOrEqual(a, b, message, file: file, line: line)
}

func expectNil(
    _ value: Any?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNil(value, message, file: file, line: line)
}

func expectNotNil(
    _ value: Any?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertNotNil(value, message, file: file, line: line)
}

func expectTrue(
    _ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(value, message, file: file, line: line)
}

func expectFalse(
    _ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertFalse(value, message, file: file, line: line)
}

func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// A fixed generator for vote-closing tests.
struct FixedRandom: RandomNumberGenerator {
    var value: UInt64

    mutating func next() -> UInt64 { value }
}
