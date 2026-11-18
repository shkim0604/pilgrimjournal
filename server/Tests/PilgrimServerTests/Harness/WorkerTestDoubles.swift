import Foundation
import NIOConcurrencyHelpers
import PilgrimAPI

@testable import PilgrimServerCore

/// Records every delivery and answers from `results` (by device token), `.delivered` otherwise.
final class FakeAPNSSender: APNSSending {
    private let state = NIOLockedValueBox<
        (deliveries: [APNSDelivery], results: [String: APNSDeliveryResult])
    >(
        ([], [:]))
    let isConfigured: Bool

    init(isConfigured: Bool = true) {
        self.isConfigured = isConfigured
    }

    var deliveries: [APNSDelivery] { state.withLockedValue { $0.deliveries } }

    func answer(_ result: APNSDeliveryResult, forToken token: String) {
        state.withLockedValue { $0.results[token] = result }
    }

    func send(_ delivery: APNSDelivery) async -> APNSDeliveryResult {
        state.withLockedValue { state in
            state.deliveries.append(delivery)
            return state.results[delivery.deviceToken] ?? .delivered
        }
    }
}

/// Never answers token `hang` until cancelled (a request whose connection died); delivers others.
final class HangingAPNSSender: APNSSending {
    private let cancelled = NIOLockedValueBox(false)
    let isConfigured = true

    var wasCancelled: Bool { cancelled.withLockedValue { $0 } }

    func send(_ delivery: APNSDelivery) async -> APNSDeliveryResult {
        guard delivery.deviceToken == "hang" else { return .delivered }
        try? await Task.sleep(for: .seconds(3600))
        cancelled.withLockedValue { $0 = Task.isCancelled }
        return .retryLater("cancelled")
    }
}

/// Records `revoke` calls and fails them while `failure` is set. `exchange` always fails.
final class FakeAppleRevoker: AppleAuthorizationClient {
    private let state = NIOLockedValueBox<
        (calls: [(token: String, clientID: String)], failure: AppleRevocationError?)
    >(([], nil))

    var calls: [(token: String, clientID: String)] { state.withLockedValue { $0.calls } }

    /// `code` is the `error` of Apple's JSON body (`invalid_grant`, …).
    func fail(status: Int?, code: String? = nil) {
        state.withLockedValue {
            $0.failure = status.map { AppleRevocationError(status: $0, code: code) }
        }
    }

    func exchange(authorizationCode: String, clientID: String) async throws
        -> AppleTokenExchange
    {
        throw APIError(code: .appleCodeExchangeFailed, message: "fake")
    }

    func revoke(refreshToken: String, clientID: String) async throws {
        let failure = state.withLockedValue { state in
            state.calls.append((refreshToken, clientID))
            return state.failure
        }
        if let failure { throw failure }
    }
}

/// A `RandomSource` that returns `values` in turn (then repeats the last one).
func fixedRandom(_ values: [UInt64]) -> RandomSource {
    let index = NIOLockedValueBox(0)
    return {
        index.withLockedValue { position in
            defer { position += 1 }
            return values[min(position, values.count - 1)]
        }
    }
}
