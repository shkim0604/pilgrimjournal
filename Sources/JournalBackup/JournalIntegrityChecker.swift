import Foundation
import JournalDomain

public enum JournalIntegrityIssueKind: String, Codable, Sendable {
    case missingCurrentRevision
    case orphanRevision
    case orphanAttachment
    case unavailableAttachmentBinary
    case missingSearchDocument
    case orphanSearchDocument
    case searchHistoryTokenMismatch
}

public struct JournalIntegrityIssue: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: JournalIntegrityIssueKind
    public var entryID: UUID?
    public var message: String

    public init(
        kind: JournalIntegrityIssueKind,
        entryID: UUID? = nil,
        relatedID: UUID? = nil,
        message: String
    ) {
        self.kind = kind
        self.entryID = entryID
        self.message = message
        id = [kind.rawValue, entryID?.uuidString, relatedID?.uuidString]
            .compactMap { $0 }
            .joined(separator: ":")
    }
}

public struct JournalIntegrityReport: Equatable, Sendable {
    public var checkedAt: Date
    public var entryCount: Int
    public var revisionCount: Int
    public var attachmentCount: Int
    public var issues: [JournalIntegrityIssue]

    public var isHealthy: Bool { issues.isEmpty }

    public init(
        checkedAt: Date,
        entryCount: Int,
        revisionCount: Int,
        attachmentCount: Int,
        issues: [JournalIntegrityIssue]
    ) {
        self.checkedAt = checkedAt
        self.entryCount = entryCount
        self.revisionCount = revisionCount
        self.attachmentCount = attachmentCount
        self.issues = issues
    }
}

public struct JournalIntegrityChecker {
    public init() {}

    public func inspect(
        entries: [JournalEntryRecord],
        revisions: [EntryRevisionRecord],
        attachments: [BackupAttachment],
        indexedEntryIDs: Set<UUID>,
        expectedSearchHistoryToken: String? = nil,
        actualSearchHistoryToken: String? = nil,
        at date: Date = .now
    ) -> JournalIntegrityReport {
        let entryIDs = Set(entries.map(\.id))
        let activeEntryIDs = Set(entries.lazy.filter { !$0.isDeleted }.map(\.id))
        let revisionIDs = Set(revisions.map(\.id))
        var issues: [JournalIntegrityIssue] = []

        for entry in entries where !revisionIDs.contains(entry.currentRevisionID) {
            issues.append(JournalIntegrityIssue(
                kind: .missingCurrentRevision,
                entryID: entry.id,
                relatedID: entry.currentRevisionID,
                message: "현재 revision을 찾을 수 없습니다."
            ))
        }
        for revision in revisions where !entryIDs.contains(revision.entryID) {
            issues.append(JournalIntegrityIssue(
                kind: .orphanRevision,
                entryID: revision.entryID,
                relatedID: revision.id,
                message: "원본 기록이 없는 revision입니다."
            ))
        }
        for attachment in attachments {
            let record = attachment.record
            if !entryIDs.contains(record.entryID) {
                issues.append(JournalIntegrityIssue(
                    kind: .orphanAttachment,
                    entryID: record.entryID,
                    relatedID: record.id,
                    message: "원본 기록이 없는 첨부입니다."
                ))
            }
            if attachment.binary == nil,
               record.state != .uploaded,
               record.deletedAt == nil {
                issues.append(JournalIntegrityIssue(
                    kind: .unavailableAttachmentBinary,
                    entryID: record.entryID,
                    relatedID: record.id,
                    message: "로컬 binary가 없고 원격 업로드 완료 상태도 아닙니다."
                ))
            }
        }
        for id in activeEntryIDs.subtracting(indexedEntryIDs) {
            issues.append(JournalIntegrityIssue(
                kind: .missingSearchDocument,
                entryID: id,
                message: "검색 인덱스에 기록이 없습니다."
            ))
        }
        for id in indexedEntryIDs.subtracting(activeEntryIDs) {
            issues.append(JournalIntegrityIssue(
                kind: .orphanSearchDocument,
                entryID: id,
                message: "canonical 기록이 없는 검색 문서입니다."
            ))
        }
        if expectedSearchHistoryToken != actualSearchHistoryToken {
            issues.append(JournalIntegrityIssue(
                kind: .searchHistoryTokenMismatch,
                message: "검색 history token이 canonical 저장소와 일치하지 않습니다."
            ))
        }

        return JournalIntegrityReport(
            checkedAt: date,
            entryCount: entries.count,
            revisionCount: revisions.count,
            attachmentCount: attachments.count,
            issues: issues.sorted { $0.id < $1.id }
        )
    }
}
