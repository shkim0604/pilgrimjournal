import Foundation
import JournalDomain

@MainActor
public struct DayOneImportExecutor {
    public init() {}

    public func execute(
        preview: DayOneImportPreview,
        repository: any JournalRepository,
        deviceID: String,
        batchSize: Int = 50,
        onEvent: @MainActor (DayOneExecutionEvent) -> Void = { _ in },
        onProgress: @MainActor (_ completed: Int, _ total: Int) -> Void = { _, _ in },
        shouldContinue: @MainActor () -> Bool = { true }
    ) async -> DayOneImportResult {
        var result = DayOneImportResult()
        let safeBatchSize = max(1, batchSize)
        let archive = try? SafeZipArchive(url: preview.archiveURL)

        for (index, item) in preview.items.enumerated() {
            if Task.isCancelled || !shouldContinue() {
                result.warnings.append(String(localized: "사용자가 가져오기를 취소했습니다.", bundle: .module))
                break
            }
            do {
                if let existing = try repository.entry(sourceUUID: item.sourceUUID) {
                    let attachmentWarnings = importAttachments(
                        for: item,
                        entryID: existing.id,
                        archive: archive,
                        repository: repository
                    )
                    result.skipped += 1
                    result.outcomes.append(
                        DayOneImportOutcome(
                            sourceUUID: item.sourceUUID,
                            entryID: nil,
                            status: .skipped,
                            kind: item.draft.kind,
                            title: item.draft.title,
                            message: String(localized: "이미 가져온 기록", bundle: .module),
                            warnings: item.warnings + attachmentWarnings
                        ))
                    onEvent(
                        .skipped(
                            sourceUUID: item.sourceUUID,
                            reason: String(localized: "이미 가져온 기록", bundle: .module),
                            rawJSON: item.rawJSON
                        ))
                } else {
                    var draft = item.draft
                    draft.id = item.stableEntryID
                    let record = try repository.save(
                        draft,
                        deviceID: deviceID,
                        at: .now
                    )
                    let attachmentWarnings = importAttachments(
                        for: item,
                        entryID: record.id,
                        archive: archive,
                        repository: repository
                    )
                    let itemWarnings = item.warnings + attachmentWarnings
                    result.succeeded += 1
                    result.warnings.append(contentsOf: itemWarnings)
                    result.outcomes.append(
                        DayOneImportOutcome(
                            sourceUUID: item.sourceUUID,
                            entryID: record.id,
                            status: .imported,
                            kind: item.draft.kind,
                            title: item.draft.title,
                            warnings: itemWarnings
                        ))
                    onEvent(
                        .imported(
                            sourceUUID: item.sourceUUID,
                            entryID: record.id,
                            rawJSON: item.rawJSON
                        ))
                }
            } catch {
                result.failed += 1
                let reason = error.localizedDescription
                result.failures.append("\(item.sourceUUID): \(reason)")
                result.outcomes.append(
                    DayOneImportOutcome(
                        sourceUUID: item.sourceUUID,
                        entryID: nil,
                        status: .failed,
                        kind: item.draft.kind,
                        title: item.draft.title,
                        message: reason,
                        warnings: item.warnings
                    ))
                onEvent(
                    .failed(
                        sourceUUID: item.sourceUUID,
                        reason: reason,
                        rawJSON: item.rawJSON
                    ))
            }
            onProgress(index + 1, preview.items.count)
            if (index + 1).isMultiple(of: safeBatchSize) {
                await Task.yield()
            }
        }
        return result
    }

    private func importAttachments(
        for item: DayOnePreviewItem,
        entryID: UUID,
        archive: SafeZipArchive?,
        repository: any JournalRepository
    ) -> [String] {
        guard !item.attachments.isEmpty else { return [] }
        guard let archive else {
            return [String(localized: "첨부 파일을 위해 ZIP을 다시 열지 못했습니다.", bundle: .module)]
        }
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            return [String(localized: "현재 저장소가 첨부 파일을 지원하지 않습니다.", bundle: .module)]
        }

        var warnings: [String] = []
        // Scoped to this entry and fetched once, not once per attachment
        // reference. The previous version called `allAttachments()` (a
        // full-table scan that faults every blob in the whole journal)
        // *inside* this loop, so a K-attachment import did O(K) full-table
        // scans against an ever-growing table — O(K²) blob faults overall,
        // exactly during the "large-import responsiveness" scenario
        // docs/development.md calls out as a device-verification gate.
        var existingChecksums = Set(
            (try? attachmentRepository.attachments(forEntry: entryID))?
                .filter { $0.deletedAt == nil }
                .map(\.checksum) ?? []
        )
        for reference in item.attachments {
            guard
                let zipEntry = matchingEntry(
                    reference.filename,
                    in: archive.entries
                )
            else {
                let warning = String(
                    localized: "첨부 파일을 찾지 못했습니다: \(reference.filename)", bundle: .module)
                if !item.warnings.contains(warning) {
                    warnings.append(warning)
                }
                continue
            }
            do {
                let data = try archive.data(for: zipEntry)
                let checksum = ContentHash.sha256Hex(data)
                guard !existingChecksums.contains(checksum) else { continue }
                let record = AttachmentRecord(
                    entryID: entryID,
                    originalName: reference.filename,
                    mimeType: mimeType(for: reference),
                    checksum: checksum,
                    byteCount: Int64(data.count),
                    state: .pending
                )
                try attachmentRepository.saveAttachment(record, binary: data)
                existingChecksums.insert(checksum)
            } catch {
                warnings.append(
                    String(
                        localized:
                            "첨부 파일 \(reference.filename)을(를) 가져오지 못했습니다: \(error.localizedDescription)",
                        bundle: .module)
                )
            }
        }
        return warnings
    }

    private func matchingEntry(
        _ filename: String,
        in entries: [ZipEntry]
    ) -> ZipEntry? {
        let expected = normalizedPath(filename)
        return entries.first { entry in
            guard !entry.isDirectory else { return false }
            let path = normalizedPath(entry.displayName)
            return path == expected
                || path.hasSuffix("/\(expected)")
                || URL(fileURLWithPath: path).lastPathComponent
                    == URL(fileURLWithPath: expected).lastPathComponent
        }
    }

    private func normalizedPath(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }

    private func mimeType(for reference: DayOneAttachmentReference) -> String {
        switch URL(fileURLWithPath: reference.filename)
            .pathExtension.lowercased()
        {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic", "heif": "image/heic"
        case "gif": "image/gif"
        case "mov": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        default:
            switch reference.type?.lowercased() {
            case "photos", "photo": "image/*"
            case "videos", "video": "video/*"
            case "audios", "audio": "audio/*"
            default: "application/octet-stream"
            }
        }
    }
}
