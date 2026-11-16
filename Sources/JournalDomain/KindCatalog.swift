import Foundation

public enum KindColorToken: String, Codable, CaseIterable, Sendable {
    // Order is fixed: the first seven are the colors of the seven built-in kinds, in
    // `BuiltInKind.allCases` order (teal is scrap's).
    case amber, sage, slate, clay, iris, stone, teal, rose
}

public enum KindIconCatalog {
    // Order is fixed, as for `KindColorToken`: one per built-in kind, in
    // `BuiltInKind.allCases` order (`bookmark` is scrap's).
    private static let builtInSymbols = [
        "hands.sparkles", "book.closed", "books.vertical", "pencil.and.scribble", "note.text",
        "tray", "bookmark",
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
        case .emptyName: String(localized: "유형 이름을 입력해 주세요.", bundle: .module)
        case .nameTooLong: String(localized: "유형 이름은 20자 이하로 입력해 주세요.", bundle: .module)
        case .duplicateName(let name): String(localized: "‘\(name)’ 유형이 이미 있습니다.", bundle: .module)
        case .systemKindLocked: String(localized: "미분류는 바꿀 수 없습니다.", bundle: .module)
        case .lastCreatableKind: String(localized: "유형이 하나 이상 있어야 합니다.", bundle: .module)
        case .invalidMoveTarget: String(localized: "기록을 옮길 다른 유형을 골라 주세요.", bundle: .module)
        case .notDeleted: String(localized: "삭제된 유형이 아닙니다.", bundle: .module)
        case .customKindCannotBeRestored:
            String(localized: "직접 만든 유형은 되살릴 수 없습니다.", bundle: .module)
        }
    }
}

/// User edits to journal kinds. Only edited kinds are stored; untouched built-ins are derived,
/// except those that appear on first use (scrap), which are listed only once stored.
public struct KindCatalog: Codable, Equatable, Sendable {
    public static let maxNameLength = 20

    /// The scrap kind's name when an active kind is already called "스크랩" (a user-made one,
    /// say) at the moment it first appears.
    public static let scrapAlternateName = "그룹 스크랩"

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
            .filter { !stored.contains($0.rawValue) && !$0.appearsOnFirstUse }
            .map { Self.defaultDefinition(for: $0) }
        return definitions + defaults
    }

    public var activeKinds: [KindDefinition] {
        let active = allDefinitions.filter { $0.isActive }
        let sorted = active.filter { !$0.kind.isUnclassified }.sorted(by: Self.orderedBefore)
        return sorted + active.filter { $0.kind.isUnclassified }
    }

    /// Active kinds the user can rename, recolour, reorder and delete: every active kind but
    /// unclassified, scrap included once it has appeared.
    public var manageableKinds: [KindDefinition] {
        activeKinds.filter { !$0.kind.isUnclassified }
    }

    /// Kinds a new entry, a classification rule or a batch move may pick: the manageable
    /// kinds without those that only arise on their own (scrap).
    public var creatableKinds: [KindDefinition] {
        manageableKinds.filter { $0.kind.builtIn?.canCreateManually ?? true }
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
        if !isKnown(kind) || isAwaitingFirstUse(kind) { edited.order = nextOrder() }
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

    /// Makes a kind that appears on first use (scrap) active and listed, and returns its
    /// definition. An active stored definition is returned untouched. Otherwise the kind is
    /// stored (or, if the user deleted it, restored) at the end of the list, keeping a name
    /// the user gave it when no other active kind has taken it meanwhile; on a clash it falls
    /// back to the default name, then to "그룹 스크랩" (numbered if even that is taken).
    /// Never throws: the first scrap must always find its kind.
    @discardableResult
    public mutating func materialize(
        _ builtIn: BuiltInKind, deviceID: String, at date: Date
    ) -> KindDefinition {
        let kind = JournalKind(id: builtIn.rawValue)
        var edited = definition(for: kind)
        if definitions.contains(where: { $0.kind == kind }), edited.isActive { return edited }
        edited.name = availableName(for: builtIn, preferring: edited.name)
        edited.state = .active
        edited.order = nextOrder()
        edited.stamp(deviceID: deviceID, at: date)
        store(edited)
        return edited
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

    /// After every listed kind but unclassified. Without scrap this is the same list as
    /// `creatableKinds`, so existing catalogs get the orders they always got.
    private func nextOrder() -> Int {
        let top = manageableKinds.map(\.order).max() ?? -1
        return top == Int.max ? top : top + 1
    }

    /// A first-use kind (scrap) with no stored definition yet: not listed anywhere.
    private func isAwaitingFirstUse(_ kind: JournalKind) -> Bool {
        guard let builtIn = kind.builtIn, builtIn.appearsOnFirstUse else { return false }
        return !definitions.contains { $0.kind == kind }
    }

    private func availableName(for builtIn: BuiltInKind, preferring current: String) -> String {
        let kind = JournalKind(id: builtIn.rawValue)
        let taken = activeKinds.filter { $0.kind != kind }.map(\.name)
        func isFree(_ name: String) -> Bool {
            !name.isEmpty && !taken.contains { Self.sameName($0, name) }
        }
        var candidates = [current, builtIn.defaultName]
        if builtIn == .scrap {
            candidates.append(Self.scrapAlternateName)
            candidates += (2...99).map { "\(Self.scrapAlternateName) \($0)" }
        }
        return candidates.first(where: isFree) ?? candidates.last ?? builtIn.defaultName
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
