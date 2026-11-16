import Crypto
import Foundation
import NIOConcurrencyHelpers
import PilgrimAPI
import Vapor
import XCTest

@testable import PilgrimServerCore

/// `LiveAppleAuthorizationClient.revoke` against canned `/auth/revoke` answers: Apple's JSON
/// error body decides whether the revocation worker retries (no database).
final class AppleRevocationClientTests: XCTestCase {
    private func client(answering status: HTTPResponseStatus, body: String?) throws -> (
        LiveAppleAuthorizationClient, RevokeEndpointStub
    ) {
        let stub = RevokeEndpointStub(status: status, body: body)
        let signer = try AppleClientSecretSigner(
            teamID: "TEAM123456", keyID: "KEY1234567",
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let live = LiveAppleAuthorizationClient(
            client: stub, secretSigner: signer, logger: Logger(label: "test"))
        return (live, stub)
    }

    private func revocationError(
        status: HTTPResponseStatus, body: String?, file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AppleRevocationError {
        let (live, _) = try client(answering: status, body: body)
        do {
            try await live.revoke(refreshToken: "r", clientID: BundleIDs.release)
        } catch let error as AppleRevocationError {
            return error
        }
        XCTFail("revoke did not throw", file: file, line: line)
        throw AppleRevocationError(status: 0)
    }

    func testSuccessPostsTheRefreshTokenForm() async throws {
        let (live, stub) = try client(answering: .ok, body: nil)
        try await live.revoke(refreshToken: "refresh-1", clientID: BundleIDs.release)
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, .POST)
        XCTAssertEqual(request.url.string, LiveAppleAuthorizationClient.revokeURL.string)
        let form = request.body.map { String(buffer: $0) } ?? ""
        XCTAssertTrue(form.contains("token=refresh-1"), form)
        XCTAssertTrue(form.contains("token_type_hint=refresh_token"), form)
    }

    func testInvalidGrantIsPermanent() async throws {
        let error = try await revocationError(
            status: .badRequest, body: #"{"error":"invalid_grant"}"#)
        XCTAssertEqual(error, AppleRevocationError(status: 400, code: "invalid_grant"))
        XCTAssertTrue(error.isPermanent)
        XCTAssertEqual(error.description, "Apple /auth/revoke answered HTTP 400 (invalid_grant)")
    }

    func testOtherErrorsAreRetried() async throws {
        let invalidClient = try await revocationError(
            status: .badRequest, body: #"{"error":"invalid_client"}"#)
        XCTAssertEqual(invalidClient.code, "invalid_client")
        XCTAssertFalse(invalidClient.isPermanent, "a fixed key or client secret clears it")

        let serverError = try await revocationError(status: .internalServerError, body: "oops")
        XCTAssertEqual(serverError, AppleRevocationError(status: 500))
        XCTAssertFalse(serverError.isPermanent)
        XCTAssertEqual(serverError.description, "Apple /auth/revoke answered HTTP 500")

        let noBody = try await revocationError(status: .badRequest, body: nil)
        XCTAssertNil(noBody.code)
        XCTAssertFalse(noBody.isPermanent)
    }

    func testErrorBodyParsing() {
        XCTAssertEqual(
            AppleRevocationError(status: 400, body: Data(#"{"error":""}"#.utf8)).code, nil)
        XCTAssertEqual(
            AppleRevocationError(status: 400, body: Data(#"{"other":1}"#.utf8)).code, nil)
        XCTAssertEqual(AppleRevocationError(status: 400, body: Data("[]".utf8)).code, nil)
        XCTAssertEqual(
            AppleRevocationError(
                status: 400,
                body: Data(#"{"error":"invalid_grant","error_description":"x"}"#.utf8)
            ).code, "invalid_grant")
    }
}

/// A Vapor `Client` that answers every request with one canned response and records requests.
private final class RevokeEndpointStub: Client {
    private let status: HTTPResponseStatus
    private let body: String?
    private let recorded = NIOLockedValueBox<[ClientRequest]>([])

    init(status: HTTPResponseStatus, body: String?) {
        self.status = status
        self.body = body
    }

    var requests: [ClientRequest] { recorded.withLockedValue { $0 } }

    var eventLoop: any EventLoop { MultiThreadedEventLoopGroup.singleton.any() }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        recorded.withLockedValue { $0.append(request) }
        var headers = HTTPHeaders()
        headers.contentType = .json
        let response = ClientResponse(
            status: status, headers: headers, body: body.map { ByteBuffer(string: $0) })
        return eventLoop.makeSucceededFuture(response)
    }
}
