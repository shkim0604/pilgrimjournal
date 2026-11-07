import Foundation

/// Who last edited one side of a shared entry, used to pick a winner when both sides
/// changed the same thing. Same ordering as `RevisionResolver`: later time, then the
/// lexicographically larger device ID.
public struct SharedEditStamp: Equatable, Sendable {
    public var updatedAt: Date
    public var deviceID: String

    public init(updatedAt: Date, deviceID: String) {
        self.updatedAt = updatedAt
        self.deviceID = deviceID
    }

    func wins(over other: SharedEditStamp) -> Bool {
        if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
        return other.deviceID.lexicographicallyPrecedes(deviceID)
    }
}

/// Merges a shared entry edited on this device (`local`) with the version another family
/// member saved to CloudKit (`remote`), relative to the last version both had (`base`).
///
/// Title and body merge line by line, tags merge as a set, and every other field takes
/// whichever side changed it. When both sides changed the same line or field differently,
/// the later edit wins and the losing side comes back as `overwritten`, so the caller can
/// keep it in the entry's history instead of losing it.
public enum SharedEntryMerge {
    public struct Result: Equatable, Sendable {
        public var draft: JournalEntryDraft
        public var overwritten: JournalEntryDraft?

        public init(draft: JournalEntryDraft, overwritten: JournalEntryDraft?) {
            self.draft = draft
            self.overwritten = overwritten
        }
    }

    public static func merge(
        base: JournalEntryDraft?,
        local: JournalEntryDraft,
        localStamp: SharedEditStamp,
        remote: JournalEntryDraft,
        remoteStamp: SharedEditStamp
    ) -> Result {
        let localWins = localStamp.wins(over: remoteStamp)
        let (winner, loser) = localWins ? (local, remote) : (remote, local)
        guard let base else {
            return Result(draft: winner, overwritten: winner == loser ? nil : loser)
        }

        var hasConflicts = false
        func text(_ field: KeyPath<JournalEntryDraft, String>) -> String {
            let result = ThreeWayTextMerge.merge(
                base: base[keyPath: field],
                local: local[keyPath: field],
                remote: remote[keyPath: field],
                winner: localWins ? .local : .remote
            )
            hasConflicts = hasConflicts || result.hasConflicts
            return result.text
        }
        func value<Value: Equatable>(_ field: KeyPath<JournalEntryDraft, Value>) -> Value {
            let (b, l, r) = (base[keyPath: field], local[keyPath: field], remote[keyPath: field])
            if l == r || r == b { return l }
            if l == b { return r }
            hasConflicts = true
            return winner[keyPath: field]
        }

        let baseTags = Set(base.tags)
        let localTags = Set(local.tags)
        let remoteTags = Set(remote.tags)
        let tags = baseTags.intersection(localTags).intersection(remoteTags)
            .union(localTags.subtracting(baseTags))
            .union(remoteTags.subtracting(baseTags))

        let draft = JournalEntryDraft(
            id: local.id ?? remote.id,
            kind: value(\.kind),
            title: text(\.title),
            body: text(\.body),
            occurredAt: value(\.occurredAt),
            originalTimeZone: value(\.originalTimeZone),
            tags: tags.sorted(),
            isStarred: value(\.isStarred),
            isPinned: value(\.isPinned),
            details: value(\.details),
            sourceUUID: value(\.sourceUUID),
            sourceMetadata: value(\.sourceMetadata)
        )
        return Result(draft: draft, overwritten: hasConflicts ? loser : nil)
    }
}
