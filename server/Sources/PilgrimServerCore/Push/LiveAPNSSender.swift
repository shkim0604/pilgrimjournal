import APNS
import APNSCore
import Crypto
import Foundation
import NIOCore
import PilgrimAPI
import Vapor

/// The APNs message body: exactly the outbox row's `PushPayload` (`aps` + `pilgrim`).
struct PilgrimAPNSMessage: APNSMessage {
    var payload: PushPayload

    func encode(to encoder: any Encoder) throws {
        try payload.encode(to: encoder)
    }
}

/// Sends through Apple's HTTP/2 APNs API with token (`.p8`) authentication: one client per APNs
/// host, both signed with the same key.
public final class LiveAPNSSender: APNSSending {
    private let production: APNSClient<JSONDecoder, JSONEncoder>
    private let sandbox: APNSClient<JSONDecoder, JSONEncoder>

    /// - Parameters:
    ///   - privateKeyPEM: the APNs `.p8` key.
    public init(
        privateKeyPEM: String, keyID: String, teamID: String,
        eventLoopGroup: any EventLoopGroup
    ) throws {
        let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        func client(_ environment: APNSCore.APNSEnvironment) -> APNSClient<JSONDecoder, JSONEncoder>
        {
            APNSClient(
                configuration: APNSClientConfiguration(
                    authenticationMethod: .jwt(
                        privateKey: key, keyIdentifier: keyID, teamIdentifier: teamID),
                    environment: environment),
                eventLoopGroupProvider: .shared(eventLoopGroup),
                responseDecoder: JSONDecoder(),
                requestEncoder: PilgrimJSON.encoder)
        }
        self.production = client(.production)
        self.sandbox = client(.development)
    }

    public var isConfigured: Bool { true }

    public func send(_ delivery: APNSDelivery) async -> APNSDeliveryResult {
        let client = delivery.environment == .production ? production : sandbox
        let request = APNSRequest(
            message: PilgrimAPNSMessage(payload: delivery.payload),
            deviceToken: delivery.deviceToken,
            pushType: .alert,
            expiration: .none,
            priority: .immediately,
            apnsID: nil,
            topic: delivery.topic,
            collapseID: delivery.collapseID)
        do {
            _ = try await client.send(request)
            return .delivered
        } catch let error as APNSError {
            return .classify(status: error.responseStatus, reason: error.reason?.reason)
        } catch {
            return .retryLater("network: \(String(describing: error).prefix(200))")
        }
    }

    public func shutdown() async {
        try? await production.shutdown()
        try? await sandbox.shutdown()
    }
}

extension Application {
    /// Builds the real sender when `APNS_KEY_ID`, `APNS_PRIVATE_KEY` and `APPLE_TEAM_ID` are all
    /// set, and shuts its HTTP clients down with the application.
    func installLiveAPNSSenderIfConfigured() throws {
        let config = pilgrimConfig
        guard let keyID = config.apnsKeyID, let keyText = config.apnsPrivateKey,
            let teamID = config.appleTeamID
        else {
            if config.isProduction {
                logger.warning("APNs is not configured; pushes stay queued")
            }
            return
        }
        let sender = try LiveAPNSSender(
            privateKeyPEM: try PEMSetting.pem(from: keyText), keyID: keyID, teamID: teamID,
            eventLoopGroup: eventLoopGroup)
        apnsSender = sender
        lifecycle.use(APNSSenderLifecycle(sender: sender))
    }
}

private struct APNSSenderLifecycle: LifecycleHandler {
    let sender: LiveAPNSSender

    func shutdownAsync(_ application: Application) async {
        await sender.shutdown()
    }
}
