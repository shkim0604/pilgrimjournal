import Foundation

/// A named, user-saved section layout (카테고리 구성) for new prayer notes,
/// e.g. "가족 기도" = 감사/가족/교회/중보.
public struct PrayerNoteTemplate: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var categories: [String]
    public var updatedAt: Date
    /// Tombstone so a delete wins over an older copy from another device.
    public var deletedAt: Date?

    public var isDeleted: Bool { deletedAt != nil }

    public init(
        id: UUID = UUID(),
        name: String,
        categories: [String],
        updatedAt: Date,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.categories = categories
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

/// The user's prayer-note templates, merged across devices the same way the
/// kind catalog is: per-template last-write-wins with deterministic tiebreaks.
public struct PrayerTemplateCatalog: Codable, Equatable, Sendable {
    /// Every template, tombstones included.
    public var templates: [PrayerNoteTemplate]

    public init(templates: [PrayerNoteTemplate] = []) {
        self.templates = Self.canonicalized(templates)
    }

    /// One canonical array order (by id), so equality is stable no matter in
    /// which order templates were saved or merged on each device.
    private static func canonicalized(_ templates: [PrayerNoteTemplate]) -> [PrayerNoteTemplate] {
        templates.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Templates to offer in pickers: not deleted, sorted by name.
    public var activeTemplates: [PrayerNoteTemplate] {
        templates.filter { !$0.isDeleted }.sorted {
            ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString)
        }
    }

    /// Saves a template. A template whose trimmed name matches an active one
    /// updates it (same id); otherwise a new template is created. Returns nil
    /// when the trimmed name is empty.
    @discardableResult
    public mutating func upsert(
        name: String, categories: [String], at date: Date
    ) -> PrayerNoteTemplate? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        var cleanedCategories: [String] = []
        for category in categories {
            let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !cleanedCategories.contains(trimmed) {
                cleanedCategories.append(trimmed)
            }
        }
        if let index = templates.firstIndex(where: {
            !$0.isDeleted && $0.name == trimmedName
        }) {
            templates[index].categories = cleanedCategories
            templates[index].updatedAt = date
            return templates[index]
        }
        let template = PrayerNoteTemplate(
            name: trimmedName, categories: cleanedCategories, updatedAt: date)
        templates.append(template)
        templates = Self.canonicalized(templates)
        return template
    }

    public mutating func delete(id: UUID, at date: Date) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].deletedAt = date
        templates[index].updatedAt = date
    }

    /// Union by id; for each id the later `updatedAt` wins, with deterministic
    /// tiebreaks (deleted first, then larger name) so both devices converge.
    public func merged(with other: PrayerTemplateCatalog) -> PrayerTemplateCatalog {
        var byID: [UUID: PrayerNoteTemplate] = [:]
        for template in templates { byID[template.id] = template }
        for template in other.templates {
            if let existing = byID[template.id] {
                byID[template.id] = Self.winner(existing, template)
            } else {
                byID[template.id] = template
            }
        }
        return PrayerTemplateCatalog(templates: Array(byID.values))
    }

    private static func winner(
        _ lhs: PrayerNoteTemplate, _ rhs: PrayerNoteTemplate
    ) -> PrayerNoteTemplate {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt ? lhs : rhs
        }
        if lhs.isDeleted != rhs.isDeleted {
            return lhs.isDeleted ? lhs : rhs
        }
        if lhs.name != rhs.name {
            return lhs.name > rhs.name ? lhs : rhs
        }
        // Same timestamp, state and name but different content (e.g. two
        // devices edited within the ISO8601 whole-second window): pick by the
        // content itself so both devices converge instead of ping-ponging.
        let lhsContent = lhs.categories.joined(separator: "\u{1F}")
        let rhsContent = rhs.categories.joined(separator: "\u{1F}")
        return lhsContent >= rhsContent ? lhs : rhs
    }
}
