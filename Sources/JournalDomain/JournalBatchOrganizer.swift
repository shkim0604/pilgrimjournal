import Foundation

public struct JournalBatchOrganizationResult: Sendable {
    public var updatedEntries: [JournalEntryRecord]

    public init(updatedEntries: [JournalEntryRecord]) {
        self.updatedEntries = updatedEntries
    }
}

public enum JournalBatchOrganizationError: LocalizedError, Equatable, Sendable {
    case emptySelection
    case missingEntries([UUID])

    public var errorDescription: String? {
        switch self {
        case .emptySelection:
            String(localized: "정리할 기록을 선택하세요.", bundle: .module)
        case let .missingEntries(ids):
            String(localized: "선택한 기록 \(ids.count)개를 찾지 못했습니다.", bundle: .module)
        }
    }
}

@MainActor
public struct JournalBatchOrganizer {
    public init() {}

    public func apply(
        entryIDs: Set<UUID>,
        targetKind: JournalKind? = nil,
        addingTags: [String] = [],
        repository: any JournalRepository,
        deviceID: String,
        at date: Date = .now
    ) throws -> JournalBatchOrganizationResult {
        guard !entryIDs.isEmpty else {
            throw JournalBatchOrganizationError.emptySelection
        }

        var drafts: [JournalEntryDraft] = []
        var missing: [UUID] = []
        for id in entryIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entry = try repository.entry(id: id), !entry.isDeleted else {
                missing.append(id)
                continue
            }
            var draft = entry.draft
            if let targetKind {
                draft.kind = targetKind
                draft.details = try draft.details.validated(for: targetKind)
            }
            draft.tags.append(contentsOf: addingTags)
            drafts.append(try draft.validated(manual: false))
        }
        guard missing.isEmpty else {
            throw JournalBatchOrganizationError.missingEntries(missing)
        }

        var updated: [JournalEntryRecord] = []
        for draft in drafts {
            updated.append(
                try repository.save(
                    draft,
                    deviceID: deviceID,
                    at: date
                ))
        }
        return JournalBatchOrganizationResult(updatedEntries: updated)
    }
}
