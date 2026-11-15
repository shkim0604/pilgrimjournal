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

/// Records revocations and answers `result`.
final class FakeAppleTokenRevoker: AppleTokenRevoking {
    private let state = NIOLockedValueBox<
        (calls: [(token: String, clientID: String)], result: AppleRevocationResult)
    >(
        ([], .revoked))

    var calls: [(token: String, clientID: String)] { state.withLockedValue { $0.calls } }

    func answer(_ result: AppleRevocationResult) {
        state.withLockedValue { $0.result = result }
    }

    func revoke(refreshToken: String, clientID: String, now: Date) async -> AppleRevocationResult {
        state.withLockedValue { state in
            state.calls.append((refreshToken, clientID))
            return state.result
        }
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
