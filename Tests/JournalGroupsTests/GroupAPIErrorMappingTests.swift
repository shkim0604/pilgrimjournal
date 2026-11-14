#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
import XCTest

final class GroupAPIErrorMappingTests: XCTestCase {
    private func failure(
        _ handler: @escaping FakeHTTPTransport.Handler,
        call: (URLSessionGroupAPI) async throws -> Void = { _ = try await $0.groups() }
    ) async -> GroupAPIError? {
        let (api, _) = Fixture.api(transport: FakeHTTPTransport(handler: handler))
        do {
            try await call(api)
            return nil
        } catch {
            return error as? GroupAPIError
        }
    }

    func testErrorEnvelopeBecomesServerError() async throws {
        let error = await failure { request in
            let body = """
                {"error":{"code":"INVITE_FULL","message":"invite has no remaining uses",\
                "field":null,"limit":null,"retryAfter":null}}
                """
            return (Data(body.utf8), Fixture.http(request, status: 409))
        }
        XCTAssertEqual(
            error,
            .server(
                status: 409,
                error: APIError(code: .inviteFull, message: "invite has no remaining uses")))
        XCTAssertEqual(error?.category, .rejected(.inviteFull))
        XCTAssertEqual(
            error?.localizedMessage, "이 초대는 인원이 다 찼어요. 관리자에게 새 초대를 요청해 주세요")
    }

    func testUnknownCodeDecodesAsUnknown() async throws {
        let error = await failure { request in
            (
                Data(#"{"error":{"code":"BRAND_NEW","message":"x"}}"#.utf8),
                Fixture.http(request, status: 418)
            )
        }
        XCTAssertEqual(error?.code, .unknown)
        XCTAssertEqual(error?.localizedMessage, GroupStrings.somethingWentWrong)
    }

    func testRateLimitReadsRetryAfterHeader() async throws {
        let error = await failure { request in
            try Fixture.error(request, .rateLimited, headers: ["Retry-After": "42"])
        }
        XCTAssertEqual(error?.category, .rateLimited(retryAfter: 42))
        XCTAssertEqual(error?.isRetryable, true)
    }

    func testUpgradeRequiredWithAndWithoutBody() async throws {
        let withBody = await failure { request in try Fixture.error(request, .clientUpgradeRequired)
        }
        XCTAssertEqual(withBody?.isUpgradeRequired, true)
        XCTAssertEqual(withBody?.localizedMessage, "그룹을 쓰려면 앱을 업데이트해 주세요")

        let withoutBody = await failure { request in
            (Data("Upgrade Required".utf8), Fixture.http(request, status: 426))
        }
        XCTAssertEqual(withoutBody?.code, .clientUpgradeRequired)
        XCTAssertEqual(withoutBody?.isUpgradeRequired, true)
    }

    func testUpgradeRequiredOnAuthIsNotASessionProblem() async throws {
        let transport = FakeHTTPTransport { request in
            try Fixture.error(request, .clientUpgradeRequired)
        }
        let (api, store) = Fixture.api(transport: transport)
        do {
            _ = try await api.me()
            XCTFail("expected 426")
        } catch let error as GroupAPIError {
            XCTAssertTrue(error.isUpgradeRequired)
        }
        XCTAssertNotNil(store.allCredentials[Fixture.account])
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testTunnelErrorPageMeansUnreachable() async throws {
        let error = await failure { request in
            (Data("<html>Bad gateway</html>".utf8), Fixture.http(request, status: 502))
        }
        XCTAssertEqual(error?.category, .unreachable)
        XCTAssertEqual(error?.isRetryable, true)
        XCTAssertEqual(error?.localizedMessage, "그룹 서버에 연결할 수 없어요. 다시 시도해 주세요")
    }

    func testTransportFailures() async throws {
        let cases: [(any Error, GroupAPIError)] = [
            (URLError(.notConnectedToInternet), .offline),
            (URLError(.networkConnectionLost), .offline),
            (URLError(.cannotConnectToHost), .offline),
            (URLError(.timedOut), .timedOut),
            (URLError(.cancelled), .cancelled),
            (CancellationError(), .cancelled),
        ]
        for (thrown, expected) in cases {
            let error = await failure { _ in throw thrown }
            XCTAssertEqual(error, expected, "\(thrown)")
        }
        XCTAssertEqual(GroupAPIError.offline.category, .unreachable)
        XCTAssertEqual(GroupAPIError.timedOut.isUnreachable, true)
    }

    func testUndecodableSuccessBodyIsInvalidResponse() async throws {
        let error = await failure { request in
            (Data("not json".utf8), Fixture.http(request, status: 200))
        }
        XCTAssertEqual(error, .invalidResponse(status: 200))
        XCTAssertEqual(error?.category, .unexpected)
    }

    func testUnexpectedStatusWithoutBody() async throws {
        let error = await failure { request in Fixture.empty(request, status: 404) }
        XCTAssertEqual(error, .invalidResponse(status: 404))
    }

    func testCancellingTheCallingTask() async throws {
        let transport = FakeHTTPTransport { request in
            try await Task.sleep(for: .seconds(10))
            return try Fixture.json(request, [GroupSummary]())
        }
        let (api, _) = Fixture.api(transport: transport)
        let task = Task { try await api.groups() }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? GroupAPIError, .cancelled)
        }
    }

    func testEveryCodeHasAMessage() {
        for code in APIErrorCode.allCases {
            let error = GroupAPIError.server(code)
            XCTAssertFalse(error.localizedMessage.isEmpty, code.rawValue)
            XCTAssertEqual(error.errorDescription, error.localizedMessage)
        }
        XCTAssertEqual(GroupAPIError.notSignedIn.localizedMessage, "그룹에 다시 로그인해 주세요")
        XCTAssertEqual(GroupAPIError.server(.notFound).category, .notFound)
        XCTAssertEqual(GroupAPIError.server(.signupRequired).category, .signupRequired)
        XCTAssertEqual(GroupAPIError.server(.refreshTokenReused).category, .signInRequired)
        XCTAssertFalse(GroupStrings.appleAccountMismatch.isEmpty)
    }
}
#endif
