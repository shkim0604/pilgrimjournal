import Foundation

@MainActor
public struct KindDeletionService {
    public init() {}

    public static func body(_ body: String, appending carryOver: String?) -> String {
        guard let carryOver else { return body }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return carryOver }
        return body + "\n\n---\n" + carryOver
    }

    /// Moves every non-trashed entry of `kind` to `target` and returns the updated records.
    public func moveEntries(
        from kind: JournalKind,
        to target: JournalKind,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date
    ) throws -> [JournalEntryRecord] {
        var entries: [JournalEntryRecord] = []
        var cursor: JournalTimelineCursor?
        repeat {
            let page = try repository.page(
                kind: kind, includeDeleted: false, after: cursor, limit: 500)
            entries.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil
        return try Self.move(
            entries, to: target, repository: repository, deviceID: deviceID, at: date)
    }

    /// Retargets classification rules that point at `kind` and returns how many changed.
    public func retargetRules(
        from kind: JournalKind,
        to target: JournalKind,
        repository: any JournalRepository,
        at date: Date
    ) throws -> Int {
        try Self.retarget(
            try repository.classificationRules().filter { $0.targetKind == kind },
            to: { _ in target }, repository: repository, at: date)
    }

    fileprivate static func move(
        _ entries: [JournalEntryRecord],
        to target: (JournalEntryRecord) -> JournalKind,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date
    ) throws -> [JournalEntryRecord] {
        var updated: [JournalEntryRecord] = []
        for entry in entries {
            var draft = entry.draft
            let carryOver = entry.kind.builtIn.flatMap {
                entry.details.carryOverLines(from: $0, timeZoneIdentifier: entry.originalTimeZone)
            }
            draft.body = body(entry.body, appending: carryOver)
            draft.kind = target(entry)
            updated.append(try repository.save(draft, deviceID: deviceID, at: date))
        }
        return updated
    }

    fileprivate static func move(
        _ entries: [JournalEntryRecord],
        to target: JournalKind,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date
    ) throws -> [JournalEntryRecord] {
        try move(entries, to: { _ in target }, repository: repository, deviceID: deviceID, at: date)
    }

    fileprivate static func retarget(
        _ rules: [ClassificationRuleRecord],
        to target: (ClassificationRuleRecord) -> JournalKind,
        repository: any JournalRepository,
        at date: Date
    ) throws -> Int {
        for var rule in rules {
            rule.targetKind = target(rule)
            rule.updatedAt = date
            try repository.saveClassificationRule(rule)
        }
        return rules.count
    }
}

@MainActor
public struct KindReconciler {
    public init() {}

    /// Moves entries and rules whose kind the catalog marks deleted. Unknown IDs are left alone.
    public func reconcile(
        catalog: KindCatalog,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date
    ) throws -> [JournalEntryRecord] {
        guard catalog.hasDeletedKinds else { return [] }
        var stale: [(JournalEntryRecord, JournalKind)] = []
        var cursor: JournalTimelineCursor?
        repeat {
            let page = try repository.page(
                kind: nil, includeDeleted: false, after: cursor, limit: 500)
            for entry in page.entries {
                if let target = catalog.resolvedTarget(for: entry.kind) {
                    stale.append((entry, target))
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        let targets = Dictionary(uniqueKeysWithValues: stale.map { ($0.0.id, $0.1) })
        let moved = try KindDeletionService.move(
            stale.map(\.0), to: { targets[$0.id] ?? .unclassified },
            repository: repository, deviceID: deviceID, at: date)
        let rules = try repository.classificationRules().filter {
            catalog.resolvedTarget(for: $0.targetKind) != nil
        }
        _ = try KindDeletionService.retarget(
            rules, to: { catalog.resolvedTarget(for: $0.targetKind) ?? .unclassified },
            repository: repository, at: date)
        return moved
    }
}
