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
    public static func extract(from notification: Notification) -> JournalStoreChange? {
        guard notification.name == ModelContext.didSave,
              let context = notification.object as? ModelContext else {
            return nil
        }

        var identifiers = Set<PersistentIdentifier>()
        for key in [
            ModelContext.NotificationKey.insertedIdentifiers,
            .updatedIdentifiers,
            .deletedIdentifiers,
        ] {
            let value = notification.userInfo?[key]
                ?? notification.userInfo?[key.rawValue]
            if let values = value as? Set<PersistentIdentifier> {
                identifiers.formUnion(values)
            } else if let values = value as? [PersistentIdentifier] {
                identifiers.formUnion(values)
            }
        }

        var entryIDs = Set<UUID>()
        var sawCanonicalChange = false
        for identifier in identifiers {
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

        guard sawCanonicalChange else { return nil }
        return JournalStoreChange(
            entryIDs: entryIDs,
            requiresFullRefresh: entryIDs.isEmpty
        )
    }
}
#endif
