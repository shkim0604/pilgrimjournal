import CryptoKit
import DayOneImport
import Foundation
import JournalDomain

public struct JournalBackupService {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func create(
        at destination: URL,
        entries: [JournalEntryRecord],
        revisions: [EntryRevisionRecord],
        rules: [ClassificationRuleRecord],
        attachments: [BackupAttachment],
        sourceSnapshots: [BackupSourceSnapshot] = []
    ) throws {
        let partial = destination
            .deletingLastPathComponent()
            .appending(path: ".\(destination.lastPathComponent).partial")
        try? FileManager.default.removeItem(at: partial)

        var files: [String: Data] = [:]
        files["entries.jsonl"] = try encodeLines(entries)
        files["revisions.jsonl"] = try encodeLines(revisions)
        files["rules.jsonl"] = try encodeLines(rules)
        files["attachments.jsonl"] = try encodeLines(attachments.map(\.record))
        if !sourceSnapshots.isEmpty {
            files["source-snapshots.jsonl"] = try encodeLines(sourceSnapshots)
        }
        for attachment in attachments {
            if let binary = attachment.binary {
                files["attachments/\(attachment.record.id.uuidString)"] = binary
            }
        }

        let checksums = files.mapValues(sha256)
        let manifest = BackupManifest(
            files: checksums,
            includesSourceSnapshots: !sourceSnapshots.isEmpty
        )
        files["manifest.json"] = try encoder.encode(manifest)

        do {
            let writer = try StoredZipWriter(url: partial)
            for name in files.keys.sorted() {
                try writer.add(name: name, data: files[name] ?? Data())
            }
            try writer.finish()
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    public func readAndValidate(from url: URL) throws -> BackupContents {
        let archive = try SafeZipArchive(url: url)
        let lookup = Dictionary(uniqueKeysWithValues: archive.entries.map { ($0.displayName, $0) })
        guard let manifestEntry = lookup["manifest.json"] else {
            throw JournalError.invalidBackup("manifest.json이 없습니다.")
        }
        let manifest = try decoder.decode(
            BackupManifest.self,
            from: archive.data(for: manifestEntry)
        )
        guard manifest.formatVersion == BackupManifest.currentFormatVersion else {
            throw JournalError.invalidBackup(
                "지원하지 않는 format version \(manifest.formatVersion)"
            )
        }

        var validated: [String: Data] = [:]
        for (name, checksum) in manifest.files {
            guard let entry = lookup[name] else {
                throw JournalError.invalidBackup("manifest 파일이 없습니다: \(name)")
            }
            let data = try archive.data(for: entry)
            guard sha256(data) == checksum else {
                throw JournalError.invalidBackup("checksum 불일치: \(name)")
            }
            validated[name] = data
        }

        let entries: [JournalEntryRecord] = try decodeLines(
            validated["entries.jsonl"] ?? Data()
        )
        let revisions: [EntryRevisionRecord] = try decodeLines(
            validated["revisions.jsonl"] ?? Data()
        )
        let rules: [ClassificationRuleRecord] = try decodeLines(
            validated["rules.jsonl"] ?? Data()
        )
        let attachmentRecords: [AttachmentRecord] = try decodeLines(
            validated["attachments.jsonl"] ?? Data()
        )
        let attachments = attachmentRecords.map { record in
            BackupAttachment(
                record: record,
                binary: validated["attachments/\(record.id.uuidString)"]
            )
        }
        let snapshots: [BackupSourceSnapshot] = try decodeLines(
            validated["source-snapshots.jsonl"] ?? Data()
        )
        return BackupContents(
            manifest: manifest,
            entries: entries,
            revisions: revisions,
            rules: rules,
            attachments: attachments,
            sourceSnapshots: snapshots
        )
    }

    public func plan(
        contents: BackupContents,
        currentEntries: [JournalEntryRecord],
        mode: RestoreMode
    ) -> RestorePlan {
        let currentByID = Dictionary(uniqueKeysWithValues: currentEntries.map { ($0.id, $0) })
        let backupIDs = Set(contents.entries.map(\.id))
        var upserts: [JournalEntryRecord] = []
        var conflicts: [(JournalEntryRecord, JournalEntryRecord)] = []

        for backup in contents.entries {
            guard let current = currentByID[backup.id] else {
                upserts.append(backup)
                continue
            }
            if current.currentRevisionID != backup.currentRevisionID {
                conflicts.append((current, backup))
                if mode == .replace || backup.updatedAt > current.updatedAt {
                    upserts.append(backup)
                }
            }
        }
        let tombstones = mode == .replace
            ? currentEntries.filter { !backupIDs.contains($0.id) }.map(\.id)
            : []
        return RestorePlan(
            mode: mode,
            upserts: upserts,
            conflicts: conflicts,
            tombstoneIDs: tombstones
        )
    }

    private func encodeLines<T: Encodable>(_ values: [T]) throws -> Data {
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        return data
    }

    private func decodeLines<T: Decodable>(_ data: Data) throws -> [T] {
        guard !data.isEmpty else { return [] }
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(T.self, from: Data(line))
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
public struct JournalRestoreExecutor {
    public init() {}

    public func execute(
        contents: BackupContents,
        plan: RestorePlan,
        repository: any BackupRestoreRepository,
        deviceID: String,
        at date: Date = .now
    ) throws -> RestoreResult {
        try repository.performRestoreTransaction {
            try repository.saveRestoreEpoch(
                RestoreEpochRecord(createdAt: date, mode: plan.mode)
            )
            for id in plan.tombstoneIDs {
                try repository.moveToTrash(entryID: id, deviceID: deviceID, at: date)
            }
            for entry in plan.upserts {
                var draft = entry.draft
                draft.id = entry.id
                _ = try repository.save(draft, deviceID: deviceID, at: date)
            }
            for revision in contents.revisions {
                try repository.importRevision(revision)
            }
            for rule in contents.rules {
                try repository.saveClassificationRule(rule)
            }
            if let attachmentRepository = repository as? any AttachmentRepository {
                for attachment in contents.attachments {
                    try attachmentRepository.saveAttachment(
                        attachment.record,
                        binary: attachment.binary
                    )
                }
            }
        }
        return RestoreResult(
            restored: plan.upserts.count,
            tombstoned: plan.tombstoneIDs.count,
            conflicts: plan.conflicts.count
        )
    }
}
