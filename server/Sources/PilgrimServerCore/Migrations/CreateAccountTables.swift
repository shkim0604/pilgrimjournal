import Fluent

/// design.md "Postgres 스키마 / 계정": users, apple_tokens, apple_token_revocations,
/// refresh_tokens, devices, subscriptions, appstore_notifications.
///
/// `users.profile_media_id` gets its foreign key in `CreateContentTables`, after `media` exists.
struct CreateAccountTables: AsyncMigration {
    var name: String { "0001_CreateAccountTables" }

    func prepare(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                """
                CREATE TABLE users (
                    id uuid PRIMARY KEY,
                    apple_sub text NOT NULL UNIQUE,
                    display_name text NULL,
                    profile_media_id uuid NULL,
                    time_zone text NOT NULL DEFAULT 'Asia/Seoul',
                    locale text NULL,
                    daily_report_enabled boolean NOT NULL DEFAULT true,
                    daily_report_minute smallint NOT NULL DEFAULT 1320
                        CHECK (daily_report_minute BETWEEN 0 AND 1439),
                    suspended_at timestamptz NULL,
                    suspended_until timestamptz NULL,
                    suspension_reason text NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                """
                CREATE TABLE apple_tokens (
                    id uuid PRIMARY KEY,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    client_id text NOT NULL,
                    refresh_token_ciphertext bytea NOT NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (user_id, client_id)
                )
                """,
                """
                CREATE TABLE apple_token_revocations (
                    id uuid PRIMARY KEY,
                    client_id text NOT NULL,
                    refresh_token_ciphertext bytea NOT NULL,
                    attempts integer NOT NULL DEFAULT 0,
                    next_attempt_at timestamptz NOT NULL,
                    last_error text NULL,
                    completed_at timestamptz NULL,
                    created_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                """
                CREATE INDEX apple_token_revocations_pending_idx
                    ON apple_token_revocations (next_attempt_at) WHERE completed_at IS NULL
                """,
                """
                CREATE TABLE refresh_tokens (
                    id uuid PRIMARY KEY,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    family_id uuid NOT NULL,
                    token_hash bytea NOT NULL UNIQUE,
                    installation_id uuid NOT NULL,
                    issued_at timestamptz NOT NULL DEFAULT now(),
                    expires_at timestamptz NOT NULL,
                    used_at timestamptz NULL,
                    replaced_by_id uuid NULL,
                    revoked_at timestamptz NULL
                )
                """,
                "CREATE INDEX refresh_tokens_user_idx ON refresh_tokens (user_id)",
                "CREATE INDEX refresh_tokens_family_idx ON refresh_tokens (family_id)",
                "CREATE INDEX refresh_tokens_expires_idx ON refresh_tokens (expires_at)",
                """
                CREATE TABLE devices (
                    id uuid PRIMARY KEY,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    installation_id uuid NOT NULL UNIQUE,
                    apns_token text NULL,
                    apns_environment text NOT NULL
                        CHECK (apns_environment IN ('sandbox', 'production')),
                    bundle_id text NOT NULL,
                    platform text NOT NULL CHECK (platform IN ('ios', 'macos')),
                    locale text NULL,
                    time_zone text NULL,
                    app_version text NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                "CREATE INDEX devices_user_idx ON devices (user_id)",
                "CREATE INDEX devices_apns_token_idx ON devices (apns_token)",
                """
                CREATE TABLE subscriptions (
                    id uuid PRIMARY KEY,
                    user_id uuid NULL REFERENCES users(id) ON DELETE CASCADE,
                    original_transaction_id text NOT NULL UNIQUE,
                    product_id text NOT NULL,
                    status text NOT NULL CHECK (status IN
                        ('active', 'gracePeriod', 'billingRetry', 'expired', 'revoked')),
                    expires_at timestamptz NULL,
                    environment text NOT NULL CHECK (environment IN ('Production', 'Sandbox')),
                    bundle_id text NOT NULL,
                    app_account_token uuid NULL,
                    last_transaction_id text NULL,
                    storefront text NULL,
                    removal_processed_at timestamptz NULL,
                    last_checked_at timestamptz NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                "CREATE INDEX subscriptions_user_idx ON subscriptions (user_id)",
                "CREATE INDEX subscriptions_status_expires_idx ON subscriptions (status, expires_at)",
                """
                CREATE TABLE appstore_notifications (
                    id uuid PRIMARY KEY,
                    notification_type text NOT NULL,
                    subtype text NULL,
                    original_transaction_id text NULL,
                    signed_date timestamptz NULL,
                    received_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                "CREATE INDEX appstore_notifications_received_idx ON appstore_notifications (received_at)",
            ], on: database)
    }

    func revert(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                "DROP TABLE IF EXISTS appstore_notifications",
                "DROP TABLE IF EXISTS subscriptions",
                "DROP TABLE IF EXISTS devices",
                "DROP TABLE IF EXISTS refresh_tokens",
                "DROP TABLE IF EXISTS apple_token_revocations",
                "DROP TABLE IF EXISTS apple_tokens",
                "DROP TABLE IF EXISTS users",
            ], on: database)
    }
}
