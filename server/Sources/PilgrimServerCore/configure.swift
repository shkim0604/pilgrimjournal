import Fluent
import FluentPostgresDriver
import Foundation
import PilgrimAPI
import Vapor

/// Configures the application for `serve`, `worker` and `migrate` alike.
///
/// Order: settings → JSON coding → database and migrations → middleware and route groups →
/// shared services → module registrars → health route. Each module (`<Folder>/<Folder>Module.swift`)
/// adds its routes and worker jobs in its own `register(_:)`, so parallel tasks only edit their
/// own folder.
public func configure(_ app: Application, config: AppConfig) async throws {
    try config.validate()
    app.pilgrimConfig = config

    app.http.server.configuration.hostname = config.httpHost
    app.http.server.configuration.port = config.httpPort
    // Uploads are at most 500KB; leave room for multipart framing.
    app.routes.defaultMaxBodySize = "2mb"

    ContentConfiguration.global.use(encoder: PilgrimJSON.encoder, for: .json)
    ContentConfiguration.global.use(decoder: PilgrimJSON.decoder, for: .json)

    try configureDatabase(app, config: config)
    app.migrations.add(PilgrimMigrations.all)

    // Replace Vapor's default error middleware with the PilgrimAPI error envelope.
    app.middleware = Middlewares()
    app.middleware.use(RouteLoggingMiddleware(logLevel: .debug))
    app.middleware.use(APIErrorMiddleware(exposesInternalMessages: !config.isProduction))

    let v1 = app.grouped("api", "v1")
        .grouped(
            ClientGateMiddleware(
                minimumVersion: config.minimumClientVersion,
                allowedBundleIDs: config.allowedBundleIDs))
    let unauthenticated = v1.grouped(
        RateLimitMiddleware(bucket: "unauthenticated", scope: .ip) {
            $0.rateLimits.unauthenticatedPerIP
        })
    let authenticated = v1.grouped(UserAuthMiddleware())
        .grouped(RateLimitMiddleware(bucket: "other", scope: .user) { $0.rateLimits.other })
    app.pilgrimRoutes = PilgrimRoutes(
        root: app.routes,
        v1: unauthenticated,
        authenticated: authenticated,
        admin: app.grouped("internal", "admin", "v1"))

    app.mediaStore = LocalDiskMediaStore(rootPath: config.mediaRoot)
    _ = app.rateLimiter
    let jobs = app.workerJobs
    jobs.register(.processHeartbeat)

    try AuthModule.register(app)
    try AccountModule.register(app)
    try GroupsModule.register(app)
    try InvitesModule.register(app)
    try VotesModule.register(app)
    try PostsModule.register(app)
    try ModerationModule.register(app)
    try MediaModule.register(app)
    try StickersModule.register(app)
    try DailyReportModule.register(app)
    try SubscriptionsModule.register(app)
    try PushModule.register(app)
    try WebModule.register(app)
    try WorkerModule.register(app)
    try InternalModule.register(app)

    HealthRoutes.register(app)

    app.asyncCommands.use(WorkerCommand(), as: "worker")
}

/// Reads the configuration from the process environment (`APP_ENV`, `DATABASE_URL`, …) and
/// configures the application.
public func configure(_ app: Application) async throws {
    try await configure(app, config: AppConfig(environment: ProcessInfo.processInfo.environment))
}

private func configureDatabase(_ app: Application, config: AppConfig) throws {
    var postgres = try SQLPostgresConfiguration(url: config.databaseURL)
    postgres.coreConfiguration.options.connectTimeout = .seconds(5)
    app.databases.use(
        .postgres(
            configuration: postgres,
            maxConnectionsPerEventLoop: 4,
            connectionPoolTimeout: .seconds(10),
            encodingContext: .init(jsonEncoder: PilgrimJSON.encoder),
            decodingContext: .init(jsonDecoder: PilgrimJSON.decoder)),
        as: .psql)
}
