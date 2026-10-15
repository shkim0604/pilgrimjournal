import Foundation

/// An entry or classification rule a move pass could not save.
public struct KindMoveFailure: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case entry
        case rule
    }

    public var item: Item
    public var id: UUID
    public var message: String

    public init(item: Item, id: UUID, message: String) {
        self.item = item
        self.id = id
        self.message = message
    }
}

/// Every save a move pass could not make, reported once the pass has tried them all.
public struct KindMoveError: LocalizedError, Equatable, Sendable {
    public var failures: [KindMoveFailure]

    public init(failures: [KindMoveFailure]) {
        self.failures = failures
    }

    public var errorDescription: String? {
        let entries = failures.filter { $0.item == .entry }.count
        let rules = failures.count - entries
        let what = [
            entries > 0 ? "기록 \(entries)개" : nil,
            rules > 0 ? "분류 규칙 \(rules)개" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: "와 ")
        let reason = failures.first.map { " (\($0.message))" } ?? ""
        return "\(what)를 옮기지 못했습니다\(reason). 다음에 앱을 열 때 다시 시도합니다."
    }
}

/// What a move pass did. One unsaveable entry or rule never stops the rest.
public struct KindMoveOutcome: Sendable {
    /// Entries saved with their new kind, for the search index.
    public var moved: [JournalEntryRecord] = []
    public var retargetedRuleCount = 0
    public var failures: [KindMoveFailure] = []

    public init() {}

    public var error: KindMoveError? {
        failures.isEmpty ? nil : KindMoveError(failures: failures)
    }
}

@MainActor
public struct KindDeletionService {
    public init() {}

    public static func body(_ body: String, appending carryOver: String?) -> String {
        guard let carryOver else { return body }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return carryOver }
        return body + "\n\n---\n" + carryOver
    }

    /// Moves every non-trashed entry of `kind` to `target`. An entry that fails
    /// to save is recorded in the outcome and the rest still move.
    public func moveEntries(
        from kind: JournalKind,
        to target: JournalKind,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date
    ) throws -> KindMoveOutcome {
        var entries: [JournalEntryRecord] = []
        var cursor: JournalTimelineCursor?
        repeat {
            let page = try repository.page(
                kind: kind, includeDeleted: false, after: cursor, limit: 500)
            entries.append(contentsOf: page.entries)
            cursor = page.nextCursor
        } while cursor != nil
        var outcome = KindMoveOutcome()
        Self.move(
            entries, to: { _ in target }, repository: repository, deviceID: deviceID, at: date,
            into: &outcome)
        return outcome
    }

    /// Retargets classification rules that point at `kind`. A rule that fails
    /// to save is recorded in the outcome and the rest are still retargeted.
    public func retargetRules(
        from kind: JournalKind,
        to target: JournalKind,
        repository: any JournalRepository,
        at date: Date
    ) throws -> KindMoveOutcome {
        var outcome = KindMoveOutcome()
        Self.retarget(
            try repository.classificationRules().filter { $0.targetKind == kind },
            to: { _ in target }, repository: repository, at: date, into: &outcome)
        return outcome
    }

    fileprivate static func move(
        _ entries: [JournalEntryRecord],
        to target: (JournalEntryRecord) -> JournalKind,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date,
        into outcome: inout KindMoveOutcome
    ) {
        for entry in entries {
            var draft = entry.draft
            let carryOver = entry.kind.builtIn.flatMap {
                entry.details.carryOverLines(from: $0, timeZoneIdentifier: entry.originalTimeZone)
            }
            draft.body = body(entry.body, appending: carryOver)
            draft.kind = target(entry)
            do {
                outcome.moved.append(try repository.save(draft, deviceID: deviceID, at: date))
            } catch {
                outcome.failures.append(
                    KindMoveFailure(
                        item: .entry, id: entry.id, message: error.localizedDescription))
            }
        }
    }

    fileprivate static func retarget(
        _ rules: [ClassificationRuleRecord],
        to target: (ClassificationRuleRecord) -> JournalKind,
        repository: any JournalRepository,
        at date: Date,
        into outcome: inout KindMoveOutcome
    ) {
        for var rule in rules {
            rule.targetKind = target(rule)
            rule.updatedAt = date
            do {
                try repository.saveClassificationRule(rule)
                outcome.retargetedRuleCount += 1
            } catch {
                outcome.failures.append(
                    KindMoveFailure(item: .rule, id: rule.id, message: error.localizedDescription))
            }
        }
    }
}

@MainActor
public struct KindReconciler {
    public init() {}

    /// Moves entries and rules whose kind the catalog marks deleted. Unknown IDs
    /// and 미분류 are left alone, and so is another device's copy of an entry
    /// that device last saved before it deleted the kind: that device moved the
    /// entry itself, and its newer version is still on its way through CloudKit.
    /// Fetch errors throw; a failed save is recorded and the rest still move.
    public func reconcile(
        catalog: KindCatalog,
        repository: any JournalRepository,
        deviceID: String,
        at date: Date
    ) throws -> KindMoveOutcome {
        var outcome = KindMoveOutcome()
        guard catalog.hasDeletedKinds else { return outcome }
        var stale: [(JournalEntryRecord, JournalKind)] = []
        var cursor: JournalTimelineCursor?
        repeat {
            let page = try repository.page(
                kind: nil, includeDeleted: false, after: cursor, limit: 500)
            for entry in page.entries {
                guard let target = catalog.resolvedTarget(for: entry.kind),
                    target != entry.kind,
                    !Self.awaitsDeletingDevicesMove(entry, catalog: catalog, deviceID: deviceID)
                else { continue }
                stale.append((entry, target))
            }
            cursor = page.nextCursor
        } while cursor != nil
        let targets = Dictionary(uniqueKeysWithValues: stale.map { ($0.0.id, $0.1) })
        KindDeletionService.move(
            stale.map(\.0), to: { targets[$0.id] ?? .unclassified },
            repository: repository, deviceID: deviceID, at: date, into: &outcome)
        let rules = try repository.classificationRules().filter { rule in
            catalog.resolvedTarget(for: rule.targetKind).map { $0 != rule.targetKind } ?? false
        }
        KindDeletionService.retarget(
            rules, to: { catalog.resolvedTarget(for: $0.targetKind) ?? .unclassified },
            repository: repository, at: date, into: &outcome)
        return outcome
    }

    /// True for another device's pre-deletion copy: the entry was last saved by
    /// the device that deleted its kind, no later than the deletion. That device
    /// moved the entry when it deleted the kind; moving this older copy with a
    /// later stamp would overwrite the moved version once it arrives. On the
    /// deleting device itself nothing newer is coming, so its leftovers move.
    private static func awaitsDeletingDevicesMove(
        _ entry: JournalEntryRecord, catalog: KindCatalog, deviceID: String
    ) -> Bool {
        let deleted = catalog.definition(for: entry.kind)
        return deleted.modifiedByDeviceID != deviceID
            && entry.modifiedByDeviceID == deleted.modifiedByDeviceID
            && entry.updatedAt <= deleted.updatedAt
    }
}
