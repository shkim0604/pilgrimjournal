import Foundation

public enum KindColorToken: String, Codable, CaseIterable, Sendable {
    // Order is fixed: the first six are the current colors of the six built-in kinds.
    case amber, sage, slate, clay, iris, stone, teal, rose
}

public enum KindIconCatalog {
    private static let builtInSymbols = [
        "hands.sparkles", "book.closed", "books.vertical", "pencil.and.scribble", "note.text",
        "tray",
    ]

    public static let symbols: [String] =
        builtInSymbols + [
            "tag", "heart", "star", "leaf", "sun.max", "moon", "flame", "music.note",
            "person.2", "house", "briefcase", "graduationcap", "lightbulb", "calendar",
        ]

    public static func displaySymbol(for token: String) -> String {
        symbols.contains(token) ? token : "tag"
    }

    static func defaultSymbol(forBuiltInAt index: Int) -> String {
        builtInSymbols[index]
    }
}

public enum KindState: Codable, Equatable, Sendable {
    case active
    case deleted(moveTarget: JournalKind)
}

public struct KindDefinition: Codable, Equatable, Identifiable, Sendable {
    public var kind: JournalKind
    public var name: String
    public var colorToken: KindColorToken
    public var iconToken: String
    public var order: Int
    public var state: KindState
    public var updatedAt: Date
    public var modifiedByDeviceID: String

    public var id: String { kind.id }

    public var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    public init(
        kind: JournalKind,
        name: String,
        colorToken: KindColorToken,
        iconToken: String,
        order: Int,
        state: KindState,
        updatedAt: Date,
        modifiedByDeviceID: String
    ) {
        self.kind = kind
        self.name = name
        self.colorToken = colorToken
        self.iconToken = iconToken
        self.order = order
        self.state = state
        self.updatedAt = updatedAt
        self.modifiedByDeviceID = modifiedByDeviceID
    }
}

extension KindDefinition {
    /// Marks an edit. The stamp is at least a whole second past the previous one,
    /// so two quick edits stay ordered after the catalog store cuts timestamps
    /// to whole seconds (a tie would fall to the byte comparison and could
    /// revert the second edit), and a clock that went backwards cannot make an
    /// edit lose to the one before it.
    fileprivate mutating func stamp(deviceID: String, at date: Date) {
        updatedAt = max(date, updatedAt.addingTimeInterval(1))
        modifiedByDeviceID = deviceID
    }
}

public enum KindCatalogError: LocalizedError, Equatable, Sendable {
    case emptyName
    case nameTooLong
    case duplicateName(String)
    case systemKindLocked
    case lastCreatableKind
    case invalidMoveTarget
    case notDeleted
    case customKindCannotBeRestored

    public var errorDescription: String? {
        switch self {
        case .emptyName: "유형 이름을 입력해 주세요."
        case .nameTooLong: "유형 이름은 20자 이하로 입력해 주세요."
        case .duplicateName(let name): "‘\(name)’ 유형이 이미 있습니다."
        case .systemKindLocked: "미분류는 바꿀 수 없습니다."
        case .lastCreatableKind: "유형이 하나 이상 있어야 합니다."
        case .invalidMoveTarget: "기록을 옮길 다른 유형을 골라 주세요."
        case .notDeleted: "삭제된 유형이 아닙니다."
        case .customKindCannotBeRestored: "직접 만든 유형은 되살릴 수 없습니다."
        }
    }
}

/// User edits to journal kinds. Only edited kinds are stored; untouched built-ins are derived.
public struct KindCatalog: Codable, Equatable, Sendable {
    public static let maxNameLength = 20

    /// Always sorted by `kind.id` so equal catalogs compare equal regardless of edit history.
    public private(set) var definitions: [KindDefinition] {
        didSet { definitions = Self.normalized(definitions) }
    }

    private enum CodingKeys: String, CodingKey { case definitions }

    public init(definitions: [KindDefinition] = []) {
        self.definitions = Self.normalized(definitions)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([KindDefinition].self, forKey: .definitions)
        self.init(definitions: decoded)
    }

    private static func normalized(_ definitions: [KindDefinition]) -> [KindDefinition] {
        let sorted = definitions.sorted { $0.id < $1.id }
        return sorted == definitions ? definitions : sorted
    }

    public static func defaultDefinition(for builtIn: BuiltInKind) -> KindDefinition {
        let index = BuiltInKind.allCases.firstIndex(of: builtIn) ?? 0
        return KindDefinition(
            kind: JournalKind(id: builtIn.rawValue),
            name: builtIn.defaultName,
            colorToken: KindColorToken.allCases[index],
            iconToken: KindIconCatalog.defaultSymbol(forBuiltInAt: index),
            order: index,
            state: .active,
            updatedAt: .distantPast,
            modifiedByDeviceID: "")
    }

    public static func unknownDefinition(for kind: JournalKind) -> KindDefinition {
        KindDefinition(
            kind: kind,
            name: "이름 없는 유형",
            colorToken: .stone,
            iconToken: "tag",
            order: Int.max - 1,
            state: .active,
            updatedAt: .distantPast,
            modifiedByDeviceID: "")
    }

    // MARK: Queries

    public var allDefinitions: [KindDefinition] {
        let stored = Set(definitions.map(\.id))
        let defaults = BuiltInKind.allCases
            .filter { !stored.contains($0.rawValue) }
            .map { Self.defaultDefinition(for: $0) }
        return definitions + defaults
    }

    public var activeKinds: [KindDefinition] {
        let active = allDefinitions.filter { $0.isActive }
        let sorted = active.filter { !$0.kind.isUnclassified }.sorted(by: Self.orderedBefore)
        return sorted + active.filter { $0.kind.isUnclassified }
    }

    public var creatableKinds: [KindDefinition] {
        activeKinds.filter { !$0.kind.isUnclassified }
    }

    public var deletedBuiltIns: [KindDefinition] {
        allDefinitions
            .filter { !$0.isActive && $0.kind.builtIn != nil }
            .sorted(by: Self.orderedBefore)
    }

    public var hasDeletedKinds: Bool {
        allDefinitions.contains { !$0.isActive }
    }

    public func isKnown(_ kind: JournalKind) -> Bool {
        kind.builtIn != nil || definitions.contains { $0.kind == kind }
    }

    public func definition(for kind: JournalKind) -> KindDefinition {
        if let stored = definitions.first(where: { $0.kind == kind }) { return stored }
        if let builtIn = kind.builtIn { return Self.defaultDefinition(for: builtIn) }
        return Self.unknownDefinition(for: kind)
    }

    /// Where entries of `kind` should live now: `nil` when the kind is active or
    /// unknown, and always for 미분류, which can never be deleted (a catalog that
    /// says otherwise is crafted or corrupt).
    public func resolvedTarget(for kind: JournalKind) -> JournalKind? {
        guard !kind.isUnclassified, isKnown(kind),
            case .deleted(let first) = definition(for: kind).state
        else {
            return nil
        }
        var visited: Set<String> = [kind.id]
        var next = first
        while true {
            guard visited.insert(next.id).inserted, isKnown(next) else { return .unclassified }
            switch definition(for: next).state {
            case .active: return next
            case .deleted(let following): next = following
            }
        }
    }

    // MARK: Mutations

    @discardableResult
    public mutating func create(
        name: String, colorToken: KindColorToken, iconToken: String,
        deviceID: String, at date: Date
    ) throws -> KindDefinition {
        let clean = try validatedName(name, excluding: nil)
        let created = KindDefinition(
            kind: .custom(),
            name: clean,
            colorToken: colorToken,
            iconToken: iconToken,
            order: nextOrder(),
            state: .active,
            updatedAt: date,
            modifiedByDeviceID: deviceID)
        definitions.append(created)
        return created
    }

    public mutating func update(
        _ kind: JournalKind, name: String, colorToken: KindColorToken, iconToken: String,
        deviceID: String, at date: Date
    ) throws {
        guard !kind.isUnclassified else { throw KindCatalogError.systemKindLocked }
        let clean = try validatedName(name, excluding: kind)
        var edited = definition(for: kind)
        if !isKnown(kind) { edited.order = nextOrder() }
        edited.name = clean
        edited.colorToken = colorToken
        edited.iconToken = iconToken
        edited.stamp(deviceID: deviceID, at: date)
        store(edited)
    }

    public mutating func reorder(
        _ ordered: [JournalKind], deviceID: String, at date: Date
    ) throws {
        guard !ordered.contains(where: \.isUnclassified) else {
            throw KindCatalogError.systemKindLocked
        }
        for (index, kind) in ordered.enumerated() {
            var edited = definition(for: kind)
            guard !isKnown(kind) || edited.order != index else { continue }
            edited.order = index
            edited.stamp(deviceID: deviceID, at: date)
            store(edited)
        }
    }

    public mutating func delete(
        _ kind: JournalKind, moveTarget: JournalKind, deviceID: String, at date: Date
    ) throws {
        guard !kind.isUnclassified else { throw KindCatalogError.systemKindLocked }
        guard moveTarget != kind, isKnown(moveTarget), definition(for: moveTarget).isActive else {
            throw KindCatalogError.invalidMoveTarget
        }
        guard creatableKinds.contains(where: { $0.kind != kind }) else {
            throw KindCatalogError.lastCreatableKind
        }
        var edited = definition(for: kind)
        edited.state = .deleted(moveTarget: moveTarget)
        edited.stamp(deviceID: deviceID, at: date)
        store(edited)
    }

    public mutating func restore(
        _ kind: JournalKind, deviceID: String, at date: Date
    ) throws {
        guard kind.builtIn != nil else { throw KindCatalogError.customKindCannotBeRestored }
        var edited = definition(for: kind)
        guard !edited.isActive else { throw KindCatalogError.notDeleted }
        if let clash = activeKinds.first(where: { Self.sameName($0.name, edited.name) }) {
            throw KindCatalogError.duplicateName(clash.name)
        }
        edited.state = .active
        edited.order = nextOrder()
        edited.stamp(deviceID: deviceID, at: date)
        store(edited)
    }

    public func merged(with other: KindCatalog) -> KindCatalog {
        var result = definitions
        for candidate in other.definitions {
            guard let index = result.firstIndex(where: { $0.kind == candidate.kind }) else {
                result.append(candidate)
                continue
            }
            let current = result[index]
            if Self.wins(candidate, over: current) {
                result[index] = candidate
            }
        }
        return KindCatalog(definitions: result)
    }

    /// Total order: later `updatedAt`, then larger device ID, then larger encoded bytes.
    private static func wins(_ candidate: KindDefinition, over current: KindDefinition) -> Bool {
        if candidate.updatedAt != current.updatedAt {
            return candidate.updatedAt > current.updatedAt
        }
        if candidate.modifiedByDeviceID != current.modifiedByDeviceID {
            return candidate.modifiedByDeviceID > current.modifiedByDeviceID
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let lhs = try? encoder.encode(candidate), let rhs = try? encoder.encode(current)
        else { return false }
        return lhs.lexicographicallyPrecedes(rhs) ? false : lhs != rhs
    }

    // MARK: Helpers

    private static func orderedBefore(_ lhs: KindDefinition, _ rhs: KindDefinition) -> Bool {
        lhs.order != rhs.order ? lhs.order < rhs.order : lhs.id < rhs.id
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private func nextOrder() -> Int {
        let top = creatableKinds.map(\.order).max() ?? -1
        return top == Int.max ? top : top + 1
    }

    private func validatedName(_ raw: String, excluding kind: JournalKind?) throws -> String {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw KindCatalogError.emptyName }
        guard clean.count <= Self.maxNameLength else { throw KindCatalogError.nameTooLong }
        let clash = activeKinds.contains { $0.kind != kind && Self.sameName($0.name, clean) }
        if clash { throw KindCatalogError.duplicateName(clean) }
        return clean
    }

    private mutating func store(_ definition: KindDefinition) {
        if let index = definitions.firstIndex(where: { $0.kind == definition.kind }) {
            definitions[index] = definition
        } else {
            definitions.append(definition)
        }
    }
}
