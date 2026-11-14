import Fluent

/// design.md "Postgres 스키마 / 콘텐츠": posts, post_extensions, media, stickers, comments,
/// reactions, media_file_deletions and the `media_after_delete` trigger.
///
/// `media`, `stickers` and `comments` reference each other (media → comments → stickers →
/// media), so `media.comment_id` and `users.profile_media_id` get their foreign keys after the
/// tables exist.
///
/// Whenever a `media` row is deleted — directly, by post expiry, or by any cascade (account,
/// group) — the trigger queues its file in `media_file_deletions` and the worker removes the file.
struct CreateContentTables: AsyncMigration {
    var name: String { "0003_CreateContentTables" }

    func prepare(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                """
                CREATE TABLE posts (
                    id uuid PRIMARY KEY,
                    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    author_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    kind text NOT NULL CHECK (kind IN ('prayer', 'bookReport', 'testimony')),
                    title text NULL,
                    body text NULL,
                    items jsonb NULL,
                    book_title text NULL,
                    book_author text NULL,
                    deadline text NULL CHECK (deadline ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
                    visible_days smallint NULL CHECK (visible_days IN (3, 7, 14, 30)),
                    time_zone text NOT NULL,
                    language text NULL,
                    expires_at timestamptz NOT NULL,
                    extension_count integer NOT NULL DEFAULT 0,
                    client_id uuid NOT NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (author_id, client_id)
                )
                """,
                "CREATE INDEX posts_feed_idx ON posts (group_id, created_at DESC, id DESC)",
                "CREATE INDEX posts_expires_idx ON posts (expires_at)",
                "CREATE INDEX posts_author_idx ON posts (author_id)",
                """
                CREATE TABLE post_extensions (
                    id uuid PRIMARY KEY,
                    post_id uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    client_id uuid NOT NULL,
                    previous_expires_at timestamptz NOT NULL,
                    new_expires_at timestamptz NOT NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (user_id, client_id)
                )
                """,
                "CREATE INDEX post_extensions_post_idx ON post_extensions (post_id)",
                """
                CREATE TABLE media (
                    id uuid PRIMARY KEY,
                    uploader_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    purpose text NOT NULL
                        CHECK (purpose IN ('post', 'comment', 'profile', 'sticker')),
                    group_id uuid NULL REFERENCES groups(id) ON DELETE CASCADE,
                    post_id uuid NULL REFERENCES posts(id) ON DELETE CASCADE,
                    comment_id uuid NULL,
                    sort_order smallint NOT NULL DEFAULT 0,
                    file_path text NOT NULL,
                    content_type text NOT NULL DEFAULT 'image/jpeg',
                    byte_count integer NOT NULL,
                    width integer NOT NULL,
                    height integer NOT NULL,
                    sha256 bytea NOT NULL,
                    client_id uuid NOT NULL,
                    attached_at timestamptz NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (uploader_id, client_id)
                )
                """,
                "CREATE INDEX media_post_idx ON media (post_id)",
                "CREATE INDEX media_comment_idx ON media (comment_id)",
                "CREATE INDEX media_unattached_idx ON media (created_at) WHERE attached_at IS NULL",
                """
                CREATE TABLE stickers (
                    id uuid PRIMARY KEY,
                    group_id uuid NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
                    created_by_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    media_id uuid NOT NULL UNIQUE REFERENCES media(id) ON DELETE CASCADE,
                    name text NULL,
                    client_id uuid NOT NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (created_by_id, client_id)
                )
                """,
                "CREATE INDEX stickers_group_idx ON stickers (group_id)",
                """
                CREATE TABLE comments (
                    id uuid PRIMARY KEY,
                    post_id uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                    author_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    body text NOT NULL DEFAULT '',
                    sticker_id uuid NULL REFERENCES stickers(id) ON DELETE SET NULL,
                    had_sticker boolean NOT NULL DEFAULT false,
                    client_id uuid NOT NULL,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    UNIQUE (author_id, client_id)
                )
                """,
                "CREATE INDEX comments_post_idx ON comments (post_id, created_at, id)",
                """
                CREATE TABLE reactions (
                    id uuid PRIMARY KEY,
                    post_id uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                    user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    emoji text NULL,
                    sticker_id uuid NULL REFERENCES stickers(id) ON DELETE CASCADE,
                    created_at timestamptz NOT NULL DEFAULT now(),
                    CHECK ((emoji IS NULL) <> (sticker_id IS NULL))
                )
                """,
                """
                CREATE UNIQUE INDEX reactions_emoji_unique
                    ON reactions (post_id, user_id, emoji) WHERE emoji IS NOT NULL
                """,
                """
                CREATE UNIQUE INDEX reactions_sticker_unique
                    ON reactions (post_id, user_id, sticker_id) WHERE sticker_id IS NOT NULL
                """,
                "CREATE INDEX reactions_post_idx ON reactions (post_id)",
                """
                ALTER TABLE media ADD CONSTRAINT media_comment_id_fkey
                    FOREIGN KEY (comment_id) REFERENCES comments(id) ON DELETE CASCADE
                """,
                """
                ALTER TABLE users ADD CONSTRAINT users_profile_media_id_fkey
                    FOREIGN KEY (profile_media_id) REFERENCES media(id) ON DELETE SET NULL
                """,
                """
                CREATE TABLE media_file_deletions (
                    id uuid PRIMARY KEY,
                    file_path text NOT NULL,
                    attempts integer NOT NULL DEFAULT 0,
                    created_at timestamptz NOT NULL DEFAULT now()
                )
                """,
                """
                CREATE FUNCTION media_after_delete() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    INSERT INTO media_file_deletions (id, file_path, attempts, created_at)
                    VALUES (gen_random_uuid(), OLD.file_path, 0, now());
                    RETURN OLD;
                END
                $$
                """,
                """
                CREATE TRIGGER media_after_delete AFTER DELETE ON media
                    FOR EACH ROW EXECUTE FUNCTION media_after_delete()
                """,
            ], on: database)
    }

    func revert(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                "DROP TRIGGER IF EXISTS media_after_delete ON media",
                "DROP FUNCTION IF EXISTS media_after_delete()",
                "DROP TABLE IF EXISTS media_file_deletions",
                "ALTER TABLE users DROP CONSTRAINT IF EXISTS users_profile_media_id_fkey",
                "ALTER TABLE media DROP CONSTRAINT IF EXISTS media_comment_id_fkey",
                "DROP TABLE IF EXISTS reactions",
                "DROP TABLE IF EXISTS comments",
                "DROP TABLE IF EXISTS stickers",
                "DROP TABLE IF EXISTS media",
                "DROP TABLE IF EXISTS post_extensions",
                "DROP TABLE IF EXISTS posts",
            ], on: database)
    }
}
