import Vapor

/// Auth module — owned by task S1 (openspec/changes/add-private-groups/tasks.md).
///
/// `POST /api/v1/auth/apple|refresh|logout|dev`. Install the JWT verifier as `app.accessTokenVerifier` here; register `auth/dev` only when `app.pilgrimConfig.devLoginEnabled`. Unauthenticated routes go on `routes.v1`, `logout` on `routes.authenticated`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
enum AuthModule {
    static func register(_ app: Application) throws {
    }
}
