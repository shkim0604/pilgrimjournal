import Fluent

/// design.md "posts.items": prayer items carry `section` (a prayer note's heading) instead of
/// `who`. Moves the value of every stored item, keeping the order.
struct RenamePrayerItemWho: AsyncMigration {
    var name: String { "0006_RenamePrayerItemWho" }

    func prepare(on database: any Database) async throws {
        try await SchemaSQL.run([Self.rename(from: "who", to: "section")], on: database)
    }

    func revert(on database: any Database) async throws {
        try await SchemaSQL.run([Self.rename(from: "section", to: "who")], on: database)
    }

    static func rename(from old: String, to new: String) -> String {
        """
        UPDATE posts SET items = (
            SELECT jsonb_agg(
                CASE WHEN e.item ? '\(old)'
                    THEN (e.item - '\(old)') || jsonb_build_object('\(new)', e.item -> '\(old)')
                    ELSE e.item END
                ORDER BY e.position)
            FROM jsonb_array_elements(posts.items) WITH ORDINALITY AS e(item, position))
        WHERE items IS NOT NULL AND jsonb_typeof(items) = 'array' AND jsonb_array_length(items) > 0
        """
    }
}
