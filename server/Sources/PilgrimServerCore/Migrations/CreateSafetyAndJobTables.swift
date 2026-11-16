import Fluent

/// design.md "Postgres 스키마 / 안전": hides, blocks, reports, moderation_log.
struct CreateSafetyTables: AsyncMigration {
    var name: String { "0004_CreateSafetyTables" }

    func prepare(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                """
                CREATE TABLE hides (
                    id uuid PRIMARY KEY,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    post_id uuid NULL REFERENCES posts(id) ON DELETE CASCADE,
                    target_user_id uuid NULL REFERENCES users(id) ON DELETE CASCADE,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    CHECK ((post_id IS NULL) <> (target_user_id IS NULL))
                )
                """,
                """
                CREATE UNIQUE INDEX hides_post_unique
                    ON hides (user_id, post_id) WHERE post_id IS NOT NULL
                """,
                """
                CREATE UNIQUE INDEX hides_user_unique
                    ON hides (user_id, target_user_id) WHERE target_user_id IS NOT NULL
                """,
                """
                CREATE TABLE blocks (
                    id uuid PRIMARY KEY,
                    blocker_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    blocked_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (blocker_id, blocked_id),
                    CHECK (blocker_id <> blocked_id)
                )
                """,
                "CREATE INDEX blocks_blocked_idx ON blocks (blocked_id)",
                """
                CREATE TABLE reports (
                    id uuid PRIMARY KEY,
                    reporter_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
                    group_id uuid NULL REFERENCES groups(id) ON DELETE SET NULL,
                    target_type text NOT NULL
                        CHECK (target_type IN ('post', 'comment', 'sticker', 'user')),
                    target_id uuid NOT NULL,
                    target_user_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
                    reason text NOT NULL,
                    note text NULL,
                    snapshot jsonb NOT NULL,
                    status text NOT NULL DEFAULT 'open'
                        CHECK (status IN ('open', 'dismissed', 'actioned')),
                    resolved_at timestamptz NULL,
                    resolved_by text NULL,
                    client_id uuid NOT NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (reporter_id, client_id)
                )
                """,
                "CREATE INDEX reports_status_created_idx ON reports (status, created_at)",
                "CREATE INDEX reports_created_idx ON reports (created_at)",
                """
                CREATE TABLE moderation_log (
                    id uuid PRIMARY KEY,
                    actor text NOT NULL,
                    action text NOT NULL CHECK (action IN ('deletePost', 'deleteComment',
                        'deleteSticker', 'suspendUser', 'unsuspendUser', 'resolveReport')),
                    target_type text NOT NULL,
                    target_id uuid NOT NULL,
                    report_id uuid NULL,
                    note text NULL,
                    created_at timestamptz NOT NULL DEFAULT now()
                )
                """,
            ], on: database)
    }

    func revert(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                "DROP TABLE IF EXISTS moderation_log",
                "DROP TABLE IF EXISTS reports",
                "DROP TABLE IF EXISTS blocks",
                "DROP TABLE IF EXISTS hides",
            ], on: database)
    }
}

/// design.md "Postgres 스키마 / 작업": push_outbox, daily_report_log, worker_heartbeat.
struct CreateJobTables: AsyncMigration {
    var name: String { "0005_CreateJobTables" }

    func prepare(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                """
                CREATE TABLE push_outbox (
                    id uuid PRIMARY KEY,
                    recipient_user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    kind text NOT NULL,
                    payload jsonb NOT NULL,
                    collapse_id text NULL,
                    attempts integer NOT NULL DEFAULT 0,
                    next_attempt_at timestamptz NOT NULL DEFAULT now(),
                    sent_at timestamptz NULL,
                    failed_at timestamptz NULL,
                    last_error text NULL,
                    created_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                """
                CREATE INDEX push_outbox_pending_idx ON push_outbox (next_attempt_at)
                    WHERE sent_at IS NULL AND failed_at IS NULL
                """,
                "CREATE INDEX push_outbox_recipient_idx ON push_outbox (recipient_user_id)",
                """
                CREATE TABLE daily_report_log (
                    id uuid PRIMARY KEY,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    report_date text NOT NULL
                        CHECK (report_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
                    window_start timestamptz NOT NULL,
                    window_end timestamptz NOT NULL,
                    status text NOT NULL CHECK (status IN ('sent', 'skipped')),
                    item_count integer NOT NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (user_id, report_date)
                )
                """,
                """
                CREATE TABLE worker_heartbeat (
                    id uuid PRIMARY KEY,
                    loop text NOT NULL UNIQUE,
                    last_beat_at timestamptz NOT NULL,
                    last_error text NULL,
                    last_error_at timestamptz NULL
                )
                """,
            ], on: database)
    }

    func revert(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                "DROP TABLE IF EXISTS worker_heartbeat",
                "DROP TABLE IF EXISTS daily_report_log",
                "DROP TABLE IF EXISTS push_outbox",
            ], on: database)
    }
}

/// Every migration, in order. `configure` adds these; later tasks must not add schema changes
/// without a design.md change first (tasks.md 머리말).
enum PilgrimMigrations {
    static var all: [any Migration] {
        [
            CreateAccountTables(),
            CreateGroupTables(),
            CreateContentTables(),
            CreateSafetyTables(),
            CreateJobTables(),
        ]
    }

    /// Every table the migrations create, children first (tests truncate them between cases).
    static let tables: [String] = [
        "worker_heartbeat", "daily_report_log", "push_outbox",
        "moderation_log", "reports", "blocks", "hides",
        "media_file_deletions", "reactions", "comments", "stickers", "media", "post_extensions",
        "posts",
        "ballots", "admin_votes", "group_bans", "memberships", "invites", "groups",
        "appstore_notifications", "subscriptions", "devices", "refresh_tokens",
        "apple_token_revocations", "apple_tokens", "users",
    ]
}
