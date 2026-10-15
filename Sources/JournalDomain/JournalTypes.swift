import CryptoKit
import Foundation

public enum BuiltInKind: String, CaseIterable, Sendable {
    case prayer
    case bibleStudy
    case reading
    case diary
    case memo
    case unclassified

    public var defaultName: String {
        switch self {
        case .prayer: "기도노트"
        case .bibleStudy: "성경공부"
        case .reading: "독서노트"
        case .diary: "일기"
        case .memo: "메모"
        case .unclassified: "미분류"
        }
    }

    public var canCreateManually: Bool { self != .unclassified }

    /// The core kinds the app is built around stay put; memo and user-made
    /// kinds can go. Unclassified is locked separately.
    public var canBeDeleted: Bool {
        switch self {
        case .prayer, .bibleStudy, .reading, .diary, .unclassified: false
        case .memo: true
        }
    }
}

/// A journal kind identified by an open string ID: built-in IDs are the `BuiltInKind` raw
/// values, user-created kinds use `"custom-" + UUID`. Encoded as a single bare string.
public struct JournalKind: Hashable, Codable, Identifiable, Sendable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.id = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "JournalKind id must not be empty")
        }
        self.id = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    public var rawValue: String { id }
    public var builtIn: BuiltInKind? { BuiltInKind(rawValue: id) }
    public var isUnclassified: Bool { id == BuiltInKind.unclassified.rawValue }
    public var canBeDeleted: Bool { builtIn?.canBeDeleted ?? true }

    /// Name used outside the kind catalog (validation messages, check scripts).
    public var fallbackName: String { builtIn?.defaultName ?? "이름 없는 유형" }

    public static let prayer = JournalKind(id: BuiltInKind.prayer.rawValue)
    public static let bibleStudy = JournalKind(id: BuiltInKind.bibleStudy.rawValue)
    public static let reading = JournalKind(id: BuiltInKind.reading.rawValue)
    public static let diary = JournalKind(id: BuiltInKind.diary.rawValue)
    public static let memo = JournalKind(id: BuiltInKind.memo.rawValue)
    public static let unclassified = JournalKind(id: BuiltInKind.unclassified.rawValue)

    public static var builtIns: [JournalKind] {
        BuiltInKind.allCases.map { JournalKind(id: $0.rawValue) }
    }

    public static func custom() -> JournalKind {
        JournalKind(id: "custom-" + UUID().uuidString)
    }
}

public enum PrayerStatus: String, Codable, CaseIterable, Sendable {
    case ongoing
    case answered
}

public struct EntryDetails: Codable, Equatable, Sendable {
    public var prayerStatus: PrayerStatus?
    public var answeredAt: Date?
    public var scriptureReference: String?
    public var bookTitle: String?
    public var bookAuthor: String?
    public var mood: String?

    public init(
        prayerStatus: PrayerStatus? = nil,
        answeredAt: Date? = nil,
        scriptureReference: String? = nil,
        bookTitle: String? = nil,
        bookAuthor: String? = nil,
        mood: String? = nil
    ) {
        self.prayerStatus = prayerStatus
        self.answeredAt = answeredAt
        self.scriptureReference = scriptureReference
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.mood = mood
    }

    public func validated(for kind: JournalKind) throws -> EntryDetails {
        var copy = self
        switch kind.builtIn {
        case .prayer:
            copy.scriptureReference = nil
            copy.bookTitle = nil
            copy.bookAuthor = nil
            copy.mood = nil
            if copy.prayerStatus == nil { copy.prayerStatus = .ongoing }
            if copy.prayerStatus != .answered { copy.answeredAt = nil }
        case .bibleStudy:
            copy.prayerStatus = nil
            copy.answeredAt = nil
            copy.bookTitle = nil
            copy.bookAuthor = nil
            copy.mood = nil
        case .reading:
            copy.prayerStatus = nil
            copy.answeredAt = nil
            copy.scriptureReference = nil
            copy.mood = nil
        case .diary:
            copy.prayerStatus = nil
            copy.answeredAt = nil
            copy.scriptureReference = nil
            copy.bookTitle = nil
            copy.bookAuthor = nil
        case .memo, .unclassified, nil:
            copy = EntryDetails()
        }
        return copy
    }

    /// Human-readable lines for the kind-specific fields that would be lost when an entry
    /// leaves `kind`, or nil when there is nothing to carry over.
    public func carryOverLines(from kind: BuiltInKind, timeZoneIdentifier: String?) -> String? {
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                !trimmed.isEmpty
            else { return nil }
            return trimmed
        }
        var lines: [String] = []
        switch kind {
        case .prayer:
            switch prayerStatus {
            case .ongoing:
                lines.append("기도 상태: 기도 중")
            case .answered:
                if let answeredAt {
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone =
                        timeZoneIdentifier.flatMap { TimeZone(identifier: $0) } ?? .current
                    let formatter = DateFormatter()
                    formatter.calendar = calendar
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = calendar.timeZone
                    formatter.dateFormat = "yyyy-MM-dd"
                    lines.append("기도 상태: 응답됨 (\(formatter.string(from: answeredAt)))")
                } else {
                    lines.append("기도 상태: 응답됨")
                }
            case nil:
                break
            }
        case .bibleStudy:
            if let reference = clean(scriptureReference) { lines.append("본문: \(reference)") }
        case .reading:
            let title = clean(bookTitle).map { "책: \($0)" }
            let author = clean(bookAuthor).map { "저자: \($0)" }
            let joined = [title, author].compactMap { $0 }.joined(separator: " / ")
            if !joined.isEmpty { lines.append(joined) }
        case .diary:
            if let mood = clean(mood) { lines.append("기분: \(mood)") }
        case .memo, .unclassified:
            break
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

public enum SyncState: Equatable, Sendable {
    case localOnly
    case savedLocally
    case pending
    case synced(Date?)
    case unavailable(reason: String)
    case failed(message: String, retryable: Bool)
}

public enum JournalError: LocalizedError, Equatable, Sendable {
    case invalidManualKind
    case emptyContent
    case entryNotFound
    case revisionNotFound
    case duplicateSource(String)
    case unsupportedArchive(String)
    case unsafeArchive(String)
    case invalidBackup(String)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidManualKind:
            "미분류로는 새 기록을 만들 수 없습니다. 다른 유형을 골라 주세요."
        case .emptyContent: "제목이나 본문 중 하나는 입력해야 합니다."
        case .entryNotFound: "기록을 찾을 수 없습니다."
        case .revisionNotFound: "기록 이력을 찾을 수 없습니다."
        case let .duplicateSource(source): "이미 가져온 Day One 기록입니다: \(source)"
        case let .unsupportedArchive(reason): "지원하지 않는 가져오기 파일입니다: \(reason)"
        case let .unsafeArchive(reason): "안전하지 않은 압축 파일입니다: \(reason)"
        case let .invalidBackup(reason): "유효하지 않은 백업입니다: \(reason)"
        case let .persistence(reason): "데이터를 저장할 수 없습니다: \(reason)"
        }
    }
}

public enum StableIdentifier {
    public static func fromDayOne(sourceUUID: String) -> UUID {
        let normalized = sourceUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: normalized) {
            return uuid
        }

        let digest = SHA256.hash(data: Data("dayone:\(normalized.lowercased())".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
    }
}
