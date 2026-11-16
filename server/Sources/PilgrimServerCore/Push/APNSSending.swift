import Foundation
import PilgrimAPI
import Vapor

/// One notification to one device (design.md 10절). The body on the wire is exactly `payload`
/// encoded with `PilgrimJSON` (`aps` with `loc-key`/`loc-args` only, plus the `pilgrim` routing
/// info) — never a post's title, body or prayer items.
public struct APNSDelivery: Equatable, Sendable {
    /// Hex APNs device token.
    public var deviceToken: String
    /// `apns-topic`: the device's bundle ID (Release or Debug app).
    public var topic: String
    /// Which APNs host: `sandbox` for Xcode builds, `production` for TestFlight and the App Store.
    public var environment: APNSEnvironment
    public var payload: PushPayload
    /// `apns-collapse-id`. The outbox row's ID unless the row has its own, so a retried row
    /// replaces the copy a device already got instead of showing twice.
    public var collapseID: String?

    public init(
        deviceToken: String, topic: String, environment: APNSEnvironment, payload: PushPayload,
        collapseID: String?
    ) {
        self.deviceToken = deviceToken
        self.topic = topic
        self.environment = environment
        self.payload = payload
        self.collapseID = collapseID
    }
}

/// What APNs said about one delivery.
public enum APNSDeliveryResult: Equatable, Sendable {
    case delivered
    /// 410, `BadDeviceToken`, `Unregistered`, `DeviceTokenNotForTopic`: forget the token.
    case invalidToken(String)
    /// 5xx, 429, provider-token trouble or a network error: try the row again later.
    case retryLater(String)
    /// Any other refusal (for example `PayloadTooLarge`): retrying will not help.
    case rejected(String)

    /// Maps an APNs error response to a result (Apple's "Handling notification responses from
    /// APNs").
    public static func classify(status: Int, reason: String?) -> APNSDeliveryResult {
        let label = reason.map { "\(status) \($0)" } ?? "\(status)"
        if status == 410 || invalidTokenReasons.contains(reason ?? "") {
            return .invalidToken(label)
        }
        if status >= 500 || status == 429 || status == 403 {
            // 403 is an expired or invalid provider token (our key or clock), not the device.
            return .retryLater(label)
        }
        return .rejected(label)
    }

    public static let invalidTokenReasons: Set<String> = [
        "BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic",
    ]
}

/// Sends notifications to APNs. The worker uses `VaporAPNSSender`; tests install a fake with
/// `app.apnsSender = …` after `configure`.
public protocol APNSSending: Sendable {
    /// False when no APNs key is set up: the push loop then drops due rows (development) or
    /// leaves them queued and reports an error (production).
    var isConfigured: Bool { get }
    func send(_ delivery: APNSDelivery) async -> APNSDeliveryResult
}

/// Used when `APNS_KEY_ID` / `APNS_PRIVATE_KEY` / `APPLE_TEAM_ID` are not all set.
public struct UnconfiguredAPNSSender: APNSSending {
    public init() {}

    public var isConfigured: Bool { false }

    public func send(_ delivery: APNSDelivery) async -> APNSDeliveryResult {
        .retryLater("APNs is not configured")
    }
}

extension Application {
    private struct APNSSenderKey: StorageKey {
        typealias Value = any APNSSending
    }

    /// The APNs sender the `pushOutbox` loop uses. `PushModule.register` installs the real one
    /// when the APNs key is configured; tests may replace it after `configure`.
    public var apnsSender: any APNSSending {
        get { storage[APNSSenderKey.self] ?? UnconfiguredAPNSSender() }
        set { storage[APNSSenderKey.self] = newValue }
    }
}

/// Reads a `.p8` key setting: either the PEM text itself (literal `\n` sequences allowed, for
/// one-line `.env` values) or a path to the `.p8` file.
enum PEMSetting {
    static func pem(from value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("-----BEGIN") {
            return trimmed.replacingOccurrences(of: "\\n", with: "\n")
        }
        let path = (trimmed as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN")
        else {
            throw ConfigurationError("cannot read a PEM private key from \(trimmed)")
        }
        return text
    }
}
