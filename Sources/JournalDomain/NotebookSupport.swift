import Foundation

public enum NotebookTagCodec {
    private static let prefix = "__pilgrim_notebook__:"

    public static func normalizedName(_ name: String) -> String? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    public static func encodedTag(for name: String) -> String? {
        guard let normalized = normalizedName(name) else { return nil }
        return prefix + Data(normalized.utf8).base64EncodedString()
    }

    public static func notebookName(in tags: [String]) -> String? {
        tags.lazy.compactMap(decode).first
    }

    public static func assigning(_ name: String?, to tags: [String]) -> [String] {
        var result = visibleTags(in: tags)
        if let name, let encoded = encodedTag(for: name) {
            result.append(encoded)
        }
        return result
    }

    public static func visibleTags(in tags: [String]) -> [String] {
        tags.filter { decode($0) == nil }
    }

    public static func replacingVisibleTags(
        in tags: [String],
        with visibleTags: [String]
    ) -> [String] {
        let notebookTags = tags.filter { decode($0) != nil }
        return visibleTags + notebookTags
    }

    private static func decode(_ tag: String) -> String? {
        guard tag.hasPrefix(prefix) else { return nil }
        let payload = String(tag.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: payload),
            let name = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return normalizedName(name)
    }
}

public extension JournalEntryDraft {
    var notebookName: String? {
        get { NotebookTagCodec.notebookName(in: tags) }
        set { tags = NotebookTagCodec.assigning(newValue, to: tags) }
    }

    var visibleTags: [String] {
        NotebookTagCodec.visibleTags(in: tags)
    }
}

public extension JournalEntryRecord {
    var notebookName: String? {
        NotebookTagCodec.notebookName(in: tags)
    }

    var visibleTags: [String] {
        NotebookTagCodec.visibleTags(in: tags)
    }
}
