#if PILGRIM_SWIFTDATA
import Foundation
import SwiftData

public struct JournalStoreChange: Equatable, Sendable {
    public var entryIDs: Set<UUID>
    public var requiresFullRefresh: Bool
    public var token: String

    public init(
        entryIDs: Set<UUID>,
        requiresFullRefresh: Bool,
        token: String = UUID().uuidString
    ) {
        self.entryIDs = entryIDs
        self.requiresFullRefresh = requiresFullRefresh
        self.token = token
    }
}

@MainActor
public enum JournalStoreChangeExtractor {
    /// Entity names of the canonical (CloudKit-mirrored) models, used to
    /// classify already-deleted identifiers without touching
    /// `context.model(for:)` (see below). SwiftData's default entity name
    /// for a `@Model` type with no explicit name override is the type name
    /// itself, which is what `PersistentIdentifier.entityName` also
    /// reports — none of our models set a custom name.
    private static let canonicalEntityNames: Set<String> = Set(
        PilgrimJournalSchemaV1.canonicalModels.map { String(describing: $0) }
    )

    public static func extract(from notification: Notification) -> JournalStoreChange? {
        guard notification.name == ModelContext.didSave,
            let context = notification.object as? ModelContext
        else {
            return nil
        }

        func identifierSet(for key: ModelContext.NotificationKey) -> Set<PersistentIdentifier> {
            let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
            if let values = value as? Set<PersistentIdentifier> { return values }
            if let values = value as? [PersistentIdentifier] { return Set(values) }
            return []
        }

        var entryIDs = Set<UUID>()
        var sawCanonicalChange = false

        // Inserted/updated identifiers can still be resolved through the
        // context, so keep mapping them to the entry they belong to for a
        // targeted refresh.
        for identifier in identifierSet(for: .insertedIdentifiers)
            .union(identifierSet(for: .updatedIdentifiers))
        {
            switch context.model(for: identifier) {
            case let entry as JournalEntryEntity:
                sawCanonicalChange = true
                entryIDs.insert(entry.stableID)
            case let revision as EntryRevisionEntity:
                sawCanonicalChange = true
                entryIDs.insert(revision.entryID)
            case let attachment as AttachmentEntity:
                sawCanonicalChange = true
                entryIDs.insert(attachment.entryID)
            case is ClassificationRuleEntity, is RestoreEpochEntity:
                sawCanonicalChange = true
            default:
                break
            }
        }

        // Deleted identifiers can NOT be reliably resolved through
        // `context.model(for:)` — the row is already gone. Classify by
        // `entityName` instead, and treat any canonical deletion as
        // requiring a full refresh: a deleted row can't be mapped back to
        // an entry UUID for a targeted one. Without this, a permanent
        // delete in one window/scene produced no refresh signal anywhere
        // else, because the old code fell through to `default` for
        // unresolved deletions.
        var sawCanonicalDeletion = false
        for identifier in identifierSet(for: .deletedIdentifiers)
        where canonicalEntityNames.contains(identifier.entityName) {
            sawCanonicalChange = true
            sawCanonicalDeletion = true
        }

        guard sawCanonicalChange else { return nil }
        return JournalStoreChange(
            entryIDs: entryIDs,
            requiresFullRefresh: entryIDs.isEmpty || sawCanonicalDeletion
        )
    }
}
#endif
