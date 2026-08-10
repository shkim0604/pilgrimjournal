import CryptoKit
import Foundation

public enum JournalKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case prayer
    case bibleStudy
    case reading
    case diary
    case memo
    case unclassified

    public var id: String { rawValue }

    public var localizedName: String {
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
        switch kind {
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
        case .memo:
            copy = EntryDetails()
        case .unclassified:
            copy = EntryDetails()
        }
        return copy
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
        case .invalidManualKind: "새 기록은 네 가지 기록 유형 중 하나여야 합니다."
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
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
