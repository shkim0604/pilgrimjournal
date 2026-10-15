import CryptoKit
import Foundation
import JournalDomain

public struct DayOneArchiveAnalyzer {
    private let classifier = ClassificationEngine()

    public init() {}

    public func analyze(
        archiveURL: URL,
        rules: [ClassificationRuleRecord] = [],
        knownSourceUUIDs: Set<String> = []
    ) throws -> DayOneImportPreview {
        let archive = try SafeZipArchive(url: archiveURL)
        let candidates = archive.entries.filter(\.isJSONCandidate)
        guard !candidates.isEmpty else {
            throw JournalError.unsupportedArchive(
                String(localized: "JSON 파일이 없습니다.", bundle: .module))
        }

        var selected: (entry: ZipEntry, root: [String: Any], data: Data)?
        for candidate in candidates {
            guard candidate.uncompressedSize <= 256 * 1_024 * 1_024 else { continue }
            let data = try archive.data(for: candidate)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                root["metadata"] is [String: Any],
                root["entries"] is [[String: Any]]
            else {
                continue
            }
            selected = (candidate, root, data)
            break
        }
        guard let selected else {
            throw JournalError.unsupportedArchive(
                String(localized: "metadata와 entries를 가진 Day One JSON을 찾지 못했습니다.", bundle: .module)
            )
        }

        let metadata = selected.root["metadata"] as? [String: Any] ?? [:]
        let version = metadata["version"] as? String ?? "unknown"
        guard version == "1.0" else {
            throw JournalError.unsupportedArchive("Day One export version \(version)")
        }
        let rawEntries = selected.root["entries"] as? [[String: Any]] ?? []
        var previewItems: [DayOnePreviewItem] = []
        var warnings: [String] = []
        var seen = Set<String>()
        let normalizedKnown = Set(knownSourceUUIDs.map { $0.lowercased() })
        var duplicates = Set<String>()
        var optionalFieldCounts = [String: Int]()
        var missingAttachmentCount = 0

        for (index, rawEntry) in rawEntries.enumerated() {
            guard let sourceUUID = rawEntry["uuid"] as? String, !sourceUUID.isEmpty else {
                warnings.append(
                    String(localized: "항목 \(index + 1): uuid가 없어 건너뜁니다.", bundle: .module))
                continue
            }
            let normalizedUUID = sourceUUID.lowercased()
            if seen.contains(normalizedUUID) || normalizedKnown.contains(normalizedUUID) {
                duplicates.insert(sourceUUID)
            }
            seen.insert(normalizedUUID)

            let rawJSON = try JSONSerialization.data(
                withJSONObject: rawEntry,
                options: [.sortedKeys]
            )
            let mapped = try mapEntry(rawEntry, sourceUUID: sourceUUID)
            let classification = classifier.classify(
                ClassificationCandidate(
                    tags: mapped.tags,
                    templateUUID: mapped.templateUUID,
                    templateTitle: mapped.templateTitle
                ),
                rules: rules
            )
            var draft = mapped.draft
            draft.kind = classification.kind
            var itemWarnings = mapped.warnings
            for attachment in mapped.attachments
            where !archiveContains(attachment, entries: archive.entries) {
                missingAttachmentCount += 1
                itemWarnings.append(
                    String(localized: "첨부 파일을 찾지 못했습니다: \(attachment.filename)", bundle: .module))
            }
            countOptionalFields(in: rawEntry, into: &optionalFieldCounts)
            previewItems.append(
                DayOnePreviewItem(
                    stableEntryID: StableIdentifier.fromDayOne(sourceUUID: sourceUUID),
                    sourceUUID: sourceUUID,
                    draft: draft,
                    rawJSON: rawJSON,
                    classification: classification,
                    attachments: mapped.attachments,
                    warnings: itemWarnings
                ))
        }

        return DayOneImportPreview(
            archiveURL: archiveURL,
            archiveFingerprint: try fingerprint(of: archiveURL),
            exportVersion: version,
            jsonDisplayName: selected.entry.displayName,
            items: previewItems,
            duplicateSourceUUIDs: duplicates,
            optionalFieldCounts: optionalFieldCounts,
            missingAttachmentCount: missingAttachmentCount,
            warnings: warnings
        )
    }

    private func archiveContains(
        _ attachment: DayOneAttachmentReference,
        entries: [ZipEntry]
    ) -> Bool {
        let expected = attachment.filename
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        return entries.contains { entry in
            guard !entry.isDirectory else { return false }
            let path = entry.displayName
                .replacingOccurrences(of: "\\", with: "/")
                .lowercased()
            return path == expected
                || path.hasSuffix("/\(expected)")
                || URL(fileURLWithPath: path).lastPathComponent
                    == URL(fileURLWithPath: expected).lastPathComponent
        }
    }

    private func countOptionalFields(
        in raw: [String: Any],
        into counts: inout [String: Int]
    ) {
        for key in [
            "richText", "timeZone", "location", "weather", "starred",
            "isPinned", "template", "photos", "videos", "audios",
        ] where raw[key] != nil {
            counts[key, default: 0] += 1
        }
        if let tags = raw["tags"] as? [Any], !tags.isEmpty {
            counts["tags", default: 0] += 1
        }
    }

    private func mapEntry(
        _ raw: [String: Any],
        sourceUUID: String
    ) throws -> (
        draft: JournalEntryDraft,
        tags: [String],
        templateUUID: String?,
        templateTitle: String?,
        attachments: [DayOneAttachmentReference],
        warnings: [String]
    ) {
        var warnings: [String] = []
        let text = raw["text"] as? String
        let richText = raw["richText"] as? String
        let body: String
        if let text, !text.isEmpty {
            body = text
            if let richText, (try? JSONSerialization.jsonObject(with: Data(richText.utf8))) == nil {
                warnings.append(
                    String(localized: "richText를 parse하지 못해 text를 사용했습니다.", bundle: .module))
            }
        } else if let richText,
            let object = try? JSONSerialization.jsonObject(with: Data(richText.utf8))
        {
            body = collectText(from: object)
            if body.isEmpty {
                warnings.append(String(localized: "richText에서 본문을 찾지 못했습니다.", bundle: .module))
            }
        } else {
            body = ""
            warnings.append(String(localized: "읽을 수 있는 본문이 없습니다.", bundle: .module))
        }

        let occurredAt = parseDate(raw["creationDate"] as? String) ?? .distantPast
        if occurredAt == .distantPast {
            warnings.append(String(localized: "creationDate를 parse하지 못했습니다.", bundle: .module))
        }
        let tags = raw["tags"] as? [String] ?? []
        let template = raw["template"] as? [String: Any]
        let templateUUID = template?["uuid"] as? String
        let templateTitle = template?["title"] as? String
        let attachments = collectAttachments(raw)

        var canonicalMetadata: [String: Any] = [:]
        for key in [
            "modifiedDate", "location", "weather", "creationDevice",
            "creationDeviceModel", "creationDeviceType", "creationOSName",
            "creationOSVersion", "duration", "editingTime", "isAllDay", "template",
        ] where raw[key] != nil {
            canonicalMetadata[key] = raw[key]
        }
        let metadataData = try JSONSerialization.data(
            withJSONObject: canonicalMetadata,
            options: [.sortedKeys]
        )

        let draft = JournalEntryDraft(
            id: StableIdentifier.fromDayOne(sourceUUID: sourceUUID),
            kind: .unclassified,
            body: body,
            occurredAt: occurredAt,
            originalTimeZone: raw["timeZone"] as? String,
            tags: tags,
            isStarred: raw["starred"] as? Bool ?? false,
            isPinned: raw["isPinned"] as? Bool ?? false,
            sourceUUID: sourceUUID,
            sourceMetadata: metadataData
        )
        return (draft, tags, templateUUID, templateTitle, attachments, warnings)
    }

    private func collectAttachments(_ raw: [String: Any]) -> [DayOneAttachmentReference] {
        ["photos", "videos", "audios"].flatMap { key -> [DayOneAttachmentReference] in
            guard let values = raw[key] as? [[String: Any]] else { return [] }
            return values.compactMap { value in
                let filename =
                    value["filename"] as? String
                    ?? value["identifier"] as? String
                guard let filename else { return nil }
                return DayOneAttachmentReference(
                    filename: filename,
                    identifier: value["identifier"] as? String,
                    type: value["type"] as? String ?? key
                )
            }
        }
    }

    private func collectText(from value: Any) -> String {
        var pieces: [String] = []
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let text = dictionary["text"] as? String, !text.isEmpty {
                    pieces.append(text)
                } else {
                    for (key, child) in dictionary where key != "meta" {
                        visit(child)
                    }
                }
            } else if let array = value as? [Any] {
                array.forEach(visit)
            }
        }
        visit(value)
        return pieces.joined(separator: "\n")
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
        }
        return ContentHash.hex(hash.finalize())
    }
}
