import Fluent

/// design.md "Postgres 스키마 / 그룹": groups, invites, memberships, group_bans, admin_votes,
/// ballots. Admin is `groups.admin_id` only; memberships have no role column.
struct CreateGroupTables: AsyncMigration {
    var name: String { "0002_CreateGroupTables" }

    func prepare(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                """
                CREATE TABLE groups (
                    id uuid PRIMARY KEY,
                    name text NOT NULL,
                    created_by_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
                    admin_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
                    status text NOT NULL DEFAULT 'active'
                        CHECK (status IN ('active', 'voting', 'pendingDeletion')),
                    delete_at timestamptz NULL,
                    deletion_reason text NULL
                        CHECK (deletion_reason IN ('noVotes', 'adminDeleted')),
                    client_id uuid NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (created_by_id, client_id)
                )
                """,
                "CREATE INDEX groups_status_delete_at_idx ON groups (status, delete_at)",
                "CREATE INDEX groups_admin_idx ON groups (admin_id)",
                """
                CREATE TABLE invites (
                    id uuid PRIMARY KEY,
                    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    code text NOT NULL UNIQUE,
                    created_by_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
                    max_uses integer NOT NULL CHECK (max_uses BETWEEN 1 AND 100),
                    use_count integer NOT NULL DEFAULT 0
                        CHECK (use_count >= 0 AND use_count <= max_uses),
                    expires_at timestamptz NOT NULL,
                    revoked_at timestamptz NULL,
                    client_id uuid NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (created_by_id, client_id)
                )
                """,
                "CREATE INDEX invites_group_idx ON invites (group_id)",
                "CREATE INDEX invites_expires_idx ON invites (expires_at)",
                """
                CREATE TABLE memberships (
                    id uuid PRIMARY KEY,
                    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    joined_at timestamptz NOT NULL DEFAULT now(),
                    last_seen_at timestamptz NULL,
                    new_post_push_enabled boolean NOT NULL DEFAULT true,
                    daily_report_enabled boolean NOT NULL DEFAULT true,
                    invite_id uuid NULL REFERENCES invites(id) ON DELETE SET NULL,
                    UNIQUE (group_id, user_id)
                )
                """,
                "CREATE INDEX memberships_user_idx ON memberships (user_id)",
                """
                CREATE TABLE group_bans (
                    id uuid PRIMARY KEY,
                    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    banned_by_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (group_id, user_id)
                )
                """,
                """
                CREATE TABLE admin_votes (
                    id uuid PRIMARY KEY,
                    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    round smallint NOT NULL CHECK (round IN (1, 2)),
                    candidate_ids uuid[] NOT NULL,
                    eligible_ids uuid[] NOT NULL,
                    started_at timestamptz NOT NULL DEFAULT now(),
                    ends_at timestamptz NOT NULL,
                    status text NOT NULL CHECK (status IN ('open', 'closed')),
                    outcome text NULL CHECK (outcome IN
                        ('elected', 'runoff', 'random', 'noVotes', 'restarted', 'groupDeleted')),
                    elected_user_id uuid NULL REFERENCES users(id) ON DELETE SET NULL,
                    closed_at timestamptz NULL
                )
                """,
                """
                CREATE UNIQUE INDEX admin_votes_one_open_per_group
                    ON admin_votes (group_id) WHERE status = 'open'
                """,
                "CREATE INDEX admin_votes_status_ends_idx ON admin_votes (status, ends_at)",
                """
                CREATE TABLE ballots (
                    id uuid PRIMARY KEY,
                    vote_id uuid NOT NULL REFERENCES admin_votes(id) ON DELETE CASCADE,
                    voter_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    candidate_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    updated_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (vote_id, voter_id)
                )
                """,
            ], on: database)
    }

    func revert(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                "DROP TABLE IF EXISTS ballots",
                "DROP TABLE IF EXISTS admin_votes",
                "DROP TABLE IF EXISTS group_bans",
                "DROP TABLE IF EXISTS memberships",
                "DROP TABLE IF EXISTS invites",
                "DROP TABLE IF EXISTS groups",
            ], on: database)
    }
}
