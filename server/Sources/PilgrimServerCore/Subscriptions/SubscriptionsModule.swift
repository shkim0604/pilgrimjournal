import PilgrimAPI
import Vapor

/// Subscriptions module — owned by task S8 (openspec/changes/add-private-groups/tasks.md).
///
/// - `POST /api/v1/subscriptions/verify` (signed in, not suspended; sign-up not required) →
///   `EntitlementResponse`
/// - `GET /api/v1/me/entitlement` (signed in; also while suspended, like `GET /me`) →
///   `EntitlementResponse`
/// - `POST /api/appstore/notifications` (on `routes.root`: no client header, no auth; the
///   signature is the authentication) → 200, 400 when it does not verify
/// - the `subscriptions` worker job (10 min): expiry handling while `SUBSCRIPTION_REQUIRED=true`,
///   hourly re-check of stale rows when the In-App Purchase key is configured
///
/// The entitlement every other module should ask is `SubscriptionEntitlement`;
/// `SubscriptionRequiredMiddleware` is the 402 gate for routes outside `GroupAccountGate`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum SubscriptionsModule {
    static func register(_ app: Application) throws {
        app.subscriptionServices = try SubscriptionServices.make(
            config: app.pilgrimConfig, client: app.client, logger: app.logger)

        let routes = app.pilgrimRoutes
        routes.authenticated
            .grouped(AccountStateMiddleware(requiresSignup: false, allowsSuspended: false))
            .post("subscriptions", "verify", use: verify)
        routes.authenticated
            .grouped(AccountStateMiddleware(requiresSignup: false, allowsSuspended: true))
            .get("me", "entitlement", use: entitlement)
        routes.root.post("api", "appstore", "notifications", use: notification)

        app.workerJobs.register(SubscriptionWorker.job())
    }

    @Sendable static func verify(_ req: Request) async throws -> Response {
        let body = try req.content.decode(VerifySubscriptionRequest.self)
        let user = try await req.currentUser()
        return try .pilgrimJSON(
            try await SubscriptionService.verify(
                body, caller: try user.requireID(),
                verifier: req.application.subscriptionServices.verifier,
                subscriptionRequired: req.pilgrimConfig.subscriptionRequired, on: req.db))
    }

    @Sendable static func entitlement(_ req: Request) async throws -> Response {
        let user = try await req.currentUser()
        return try .pilgrimJSON(
            try await SubscriptionEntitlement.response(
                for: try user.requireID(),
                subscriptionRequired: req.pilgrimConfig.subscriptionRequired, on: req.db))
    }

    @Sendable static func notification(_ req: Request) async throws -> HTTPStatus {
        let body: AppStoreNotificationRequest
        do {
            body = try req.content.decode(AppStoreNotificationRequest.self)
        } catch {
            throw APIError.invalidRequest("expected { signedPayload }")
        }
        let outcome = try await SubscriptionService.receiveNotification(
            signedPayload: body.signedPayload,
            verifier: req.application.subscriptionServices.verifier, on: req.db)
        req.logger.info(
            "App Store notification", metadata: ["outcome": .string("\(outcome)")])
        return .ok
    }
}

/// The `subscriptions` worker loop (design.md "worker": 10 minutes).
enum SubscriptionWorker {
    static let period: Duration = .seconds(10 * 60)
    static let recheckPeriod: TimeInterval = 60 * 60

    /// Built fresh per application: the hourly re-check keeps its last-run time in the job.
    static func job() -> WorkerJob {
        let recheckGate = PeriodGate(period: recheckPeriod)
        return .periodic(
            name: "subscriptions", lockKey: WorkerLockKey.subscriptions, period: period
        ) { context in
            try await run(context, recheckGate: recheckGate)
        }
    }

    static func run(_ context: WorkerContext, recheckGate: PeriodGate) async throws {
        let config = context.config
        if config.subscriptionRequired {
            try await SubscriptionRemovalSweep.run(
                on: context.db, dayLength: config.dayLength, now: context.now,
                logger: context.logger)
        }
        let services = context.application.subscriptionServices
        if let client = services.statusClient, recheckGate.isDue(at: context.now) {
            try await SubscriptionRecheckSweep.run(
                on: context.db, client: client, verifier: services.verifier, now: context.now,
                logger: context.logger)
            recheckGate.markRan(at: context.now)
        }
    }
}
