import Foundation

/// The subject a prayer request is about; the label's second half.
public enum PrayerRequestTopic: String, CaseIterable, Sendable {
    case health, family, work, study, finances, relationships, faith, career

    private static let koreanNames: [PrayerRequestTopic: String] = [
        .health: "건강", .family: "가정", .work: "직장", .study: "학업",
        .finances: "재정", .relationships: "관계", .faith: "신앙", .career: "진로",
    ]

    /// Accepts the Korean name or the English one, since the model answers in the diary's language.
    public init?(label: String) {
        let word = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = Self.koreanNames.first(where: { $0.value == word }) {
            self = match.key
        } else if let match = Self.allCases.first(where: { $0.rawValue == word.lowercased() }) {
            self = match
        } else {
            return nil
        }
    }

    public func name(in language: RequestLanguage) -> String {
        switch language {
        case .korean: Self.koreanNames[self] ?? rawValue
        case .english: rawValue
        }
    }
}

/// The part of a journal entry the pipeline reads.
public struct PrayerRequestSource: Sendable {
    public let title: String
    public let dateText: String
    public let body: String

    public init(title: String, dateText: String, body: String) {
        self.title = title
        self.dateText = dateText
        self.body = body
    }
}

/// One suggested request. Lives only in memory while the share sheet is open.
public struct PrayerRequestDraft: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var text: String
    public var language: RequestLanguage
    public var topic: PrayerRequestTopic?
    public var who: String?

    public init(
        id: UUID = UUID(), text: String, language: RequestLanguage,
        topic: PrayerRequestTopic? = nil, who: String? = nil
    ) {
        self.id = id
        self.text = text
        self.language = language
        self.topic = topic
        self.who = who
    }
}

/// The on-device model as the pipeline sees it, so tests and the prompt lab can swap it.
public protocol ShareLanguageModel: Sendable {
    func respond(instructions: String, prompt: String, maximumTokens: Int) async throws -> String
}

public enum PrayerRequestOutcome: Equatable, Sendable {
    case drafts([PrayerRequestDraft])
    /// The gate said the diary has nothing to pray for.
    case nothingToPrayFor
    /// The model failed or its answer held no request lines.
    case noUsableAnswer
}
