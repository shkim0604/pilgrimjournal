import Fluent

/// design.md "prayer_item_answers": which prayer items the post's author marked answered, by the
/// item's index in `posts.items` (posts are never edited, so an index stays the same item).
struct CreatePrayerItemAnswers: AsyncMigration {
    var name: String { "0007_CreatePrayerItemAnswers" }

    func prepare(on database: any Database) async throws {
        try await SchemaSQL.run(
            [
                """
                CREATE TABLE prayer_item_answers (
                    post_id uuid NOT NULL REFERENCES posts(id) ON DELETE CASCADE,
                    item_index smallint NOT NULL CHECK (item_index BETWEEN 0 AND 9),
                    answered_at timestamptz NOT NULL,
                    PRIMARY KEY (post_id, item_index)
                )
                """,
                "CREATE INDEX prayer_item_answers_answered_idx ON prayer_item_answers (answered_at)",
            ], on: database)
    }

    func revert(on database: any Database) async throws {
        try await SchemaSQL.run(["DROP TABLE IF EXISTS prayer_item_answers"], on: database)
    }
}
