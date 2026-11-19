import Foundation

/// A group post as the scrap composer reads it. It mirrors the group server's post without
/// depending on it (JournalDomain has no dependencies); the app maps the server's types in.
public struct ScrapPost: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case prayer, bookReport, testimony
    }

    /// One line of a prayer-request card.
    public struct PrayerLine: Equatable, Sendable {
        public var text: String
        /// The topic's raw value (`health`, `family`, …), named through `ScrapLabels.topicName`.
        public var topic: String?
        /// Who it is for.
        /// The group item's section (a prayer note's heading, or a name).
        public var section: String?

        public init(text: String, topic: String? = nil, section: String? = nil) {
            self.text = text
            self.topic = topic
            self.section = section
        }
    }

    public struct Book: Equatable, Sendable {
        public var title: String
        public var author: String?

        public init(title: String, author: String? = nil) {
            self.title = title
            self.author = author
        }
    }

    /// A calendar day with no time or zone (a prayer request's deadline).
    public struct Day: Equatable, Sendable {
        public var year: Int
        public var month: Int
        public var day: Int

        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }
    }

    public var id: UUID
    public var groupID: UUID
    /// The group's name at the moment of the scrap.
    public var groupName: String
    public var kind: Kind
    public var authorName: String
    public var title: String?
    public var body: String?
    public var items: [PrayerLine]
    public var book: Book?
    public var deadline: Day?
    public var createdAt: Date
    /// The poster's IANA time zone; the entry keeps it as its original time zone.
    public var timeZoneIdentifier: String
    /// The post's photos (server media IDs), in order.
    public var photoIDs: [UUID]

    public init(
        id: UUID, groupID: UUID, groupName: String, kind: Kind, authorName: String,
        title: String? = nil, body: String? = nil, items: [PrayerLine] = [], book: Book? = nil,
        deadline: Day? = nil, createdAt: Date, timeZoneIdentifier: String, photoIDs: [UUID] = []
    ) {
        self.id = id
        self.groupID = groupID
        self.groupName = groupName
        self.kind = kind
        self.authorName = authorName
        self.title = title
        self.body = body
        self.items = items
        self.book = book
        self.deadline = deadline
        self.createdAt = createdAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.photoIDs = photoIDs
    }
}

/// A visible comment on the post (the caller leaves out hidden and blocked people's).
public struct ScrapComment: Equatable, Sendable {
    public var authorName: String
    public var body: String
    public var createdAt: Date
    /// The comment's photos (server media IDs), in order.
    public var photoIDs: [UUID]
    /// The comment is (or was) a sticker; it is written as `ScrapLabels.sticker`.
    public var hasSticker: Bool

    public init(
        authorName: String, body: String, createdAt: Date, photoIDs: [UUID] = [],
        hasSticker: Bool = false
    ) {
        self.authorName = authorName
        self.body = body
        self.createdAt = createdAt
        self.photoIDs = photoIDs
        self.hasSticker = hasSticker
    }
}

/// The language a scrap is written in: the shared post's own language, never the device's,
/// so every device writes the same words for the same post.
public enum ScrapLanguage: String, Equatable, Sendable {
    case korean
    case english

    /// Korean when the post's text (title, body, prayer lines and who they are for) holds any
    /// Hangul syllable or jamo, otherwise English. Deterministic and the same on every OS
    /// version, unlike a statistical language recognizer. Names (author, group, book) are left
    /// out: a Korean name does not make an English post Korean.
    public static func of(_ post: ScrapPost) -> ScrapLanguage {
        var texts = [post.title, post.body]
        for item in post.items {
            texts.append(item.text)
            texts.append(item.section)
        }
        return texts.contains { containsHangul($0 ?? "") } ? .korean : .english
    }

    /// Whether `text` has a Hangul syllable or jamo (conjoining, compatibility, the extended
    /// blocks or the halfwidth forms).
    public static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHangul($0.value) }
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        switch value {
        case 0xAC00...0xD7A3, // Hangul Syllables
            0x1100...0x11FF, // Hangul Jamo
            0x3130...0x318F, // Hangul Compatibility Jamo
            0xA960...0xA97F, // Hangul Jamo Extended-A
            0xD7B0...0xD7FF, // Hangul Jamo Extended-B
            0xFFA0...0xFFDC: // Halfwidth Hangul
            return true
        default:
            return false
        }
    }
}

/// The words of a scrap's header, title and comment section. They become stored text and are
/// never translated later, so both sets are fixed here instead of coming from the app's
/// String Catalog: the result depends only on the post (`ScrapLanguage.of`), not on the
/// device's language. The notebook name is not among them; it is always Korean
/// (`ScrapComposer.notebookPrefix`).
public struct ScrapLabels: Sendable {
    /// Formats the post and comment dates.
    public var locale: Locale
    /// "스크랩" / "Scraps": the header's first word.
    public var scrap: String
    public var prayerKind: String
    public var bookReportKind: String
    public var testimonyKind: String
    /// "<날짜>에 올림".
    public var posted: @Sendable (String) -> String
    /// "데드라인 <날짜>".
    public var deadline: @Sendable (String) -> String
    /// "<작성자>의 기도제목", the title of an untitled prayer request.
    public var prayerTitle: @Sendable (String) -> String
    /// "<작성자>의 간증", the title of an untitled testimony.
    public var testimonyTitle: @Sendable (String) -> String
    /// "댓글", the comment section's heading.
    public var comments: String
    /// "(스티커)", a sticker comment.
    public var sticker: String
    /// A prayer topic's name from its raw value; nil leaves the topic out.
    public var topicName: @Sendable (String) -> String?

    public init(
        locale: Locale,
        scrap: String,
        prayerKind: String,
        bookReportKind: String,
        testimonyKind: String,
        posted: @escaping @Sendable (String) -> String,
        deadline: @escaping @Sendable (String) -> String,
        prayerTitle: @escaping @Sendable (String) -> String,
        testimonyTitle: @escaping @Sendable (String) -> String,
        comments: String,
        sticker: String,
        topicName: @escaping @Sendable (String) -> String?
    ) {
        self.locale = locale
        self.scrap = scrap
        self.prayerKind = prayerKind
        self.bookReportKind = bookReportKind
        self.testimonyKind = testimonyKind
        self.posted = posted
        self.deadline = deadline
        self.prayerTitle = prayerTitle
        self.testimonyTitle = testimonyTitle
        self.comments = comments
        self.sticker = sticker
        self.topicName = topicName
    }

    public func kindName(_ kind: ScrapPost.Kind) -> String {
        switch kind {
        case .prayer: prayerKind
        case .bookReport: bookReportKind
        case .testimony: testimonyKind
        }
    }

    /// The fixed set for `language`.
    public static func labels(for language: ScrapLanguage) -> ScrapLabels {
        switch language {
        case .korean: korean
        case .english: english
        }
    }

    /// The fixed set for the post's own language.
    public static func labels(for post: ScrapPost) -> ScrapLabels {
        labels(for: ScrapLanguage.of(post))
    }

    /// The Korean names of the group server's prayer topics.
    public static let koreanTopicNames: [String: String] = [
        "health": "건강", "family": "가정", "work": "직장", "study": "학업",
        "finances": "재정", "relationships": "관계", "faith": "신앙", "career": "진로",
    ]

    /// The English names, the raw values as `PrayerRequestTopic.name(in: .english)` gives them.
    public static let englishTopicNames: [String: String] = Dictionary(
        uniqueKeysWithValues: koreanTopicNames.keys.map { ($0, $0) })

    public static let korean = ScrapLabels(
        locale: Locale(identifier: "ko_KR"),
        scrap: "스크랩",
        prayerKind: "기도제목",
        bookReportKind: "독후감",
        testimonyKind: "간증",
        posted: { "\($0)에 올림" },
        deadline: { "데드라인 \($0)" },
        prayerTitle: { "\($0)의 기도제목" },
        testimonyTitle: { "\($0)의 간증" },
        comments: "댓글",
        sticker: "(스티커)",
        topicName: { ScrapLabels.koreanTopicNames[$0] })

    public static let english = ScrapLabels(
        locale: Locale(identifier: "en_US"),
        scrap: "Scraps",
        prayerKind: "Prayer requests",
        bookReportKind: "Book report",
        testimonyKind: "Testimony",
        posted: { "Posted on \($0)" },
        deadline: { "Deadline \($0)" },
        prayerTitle: { "\($0)'s prayer requests" },
        testimonyTitle: { "\($0)'s testimony" },
        comments: "Comments",
        sticker: "(sticker)",
        topicName: { ScrapLabels.englishTopicNames[$0] })
}

/// A photo the scrap's body refers to, still to be downloaded and saved as an attachment
/// under `id`.
public struct ScrapAttachment: Equatable, Sendable {
    /// The attachment ID the body's `![](attachment:<id>)` line names.
    public var id: UUID
    /// The server media to download.
    public var mediaID: UUID
    public var originalName: String
    public var mimeType: String

    public init(id: UUID, mediaID: UUID, originalName: String, mimeType: String = "image/jpeg") {
        self.id = id
        self.mediaID = mediaID
        self.originalName = originalName
        self.mimeType = mimeType
    }
}

/// A scrap ready to save: the entry, its attachments and the notebook it belongs in.
public struct ScrapComposition: Equatable, Sendable {
    /// Kind `.scrap`, in `notebookName`, dated when the post was made. `id` is nil.
    public var draft: JournalEntryDraft
    /// The post's photos first, then each comment's, in body order.
    public var attachments: [ScrapAttachment]
    /// "스크랩 · <그룹 이름>", always in Korean whatever the post's language.
    public var notebookName: String

    public init(draft: JournalEntryDraft, attachments: [ScrapAttachment], notebookName: String) {
        self.draft = draft
        self.attachments = attachments
        self.notebookName = notebookName
    }
}

/// The fixed, language-independent source line at the end of a scrap's header:
/// `pilgrim-scrap: group=<groupId> post=<postId>`, UUIDs in lower case.
public enum ScrapMarker {
    public static let prefix = "pilgrim-scrap:"

    public static func line(groupID: UUID, postID: UUID) -> String {
        "\(prefix) group=\(groupID.uuidString.lowercased()) post=\(postID.uuidString.lowercased())"
    }

    /// The post IDs of every marker line in `body` (a `> ` quote prefix is fine).
    public static func postIDs(in body: String) -> [UUID] {
        body.split(whereSeparator: \.isNewline).compactMap { line -> UUID? in
            guard let start = line.range(of: prefix) else { return nil }
            let fields = line[start.upperBound...].split(separator: " ")
            guard let post = fields.first(where: { $0.hasPrefix("post=") }) else { return nil }
            return UUID(uuidString: String(post.dropFirst("post=".count)))
        }
    }

    public static func contains(postID: UUID, in body: String) -> Bool {
        postIDs(in: body).contains(postID)
    }

    /// A marker line exactly as `line(groupID:postID:)` writes it, alone on its line and
    /// maybe quoted. The app hides only these lines, never other text that mentions the prefix.
    public static let linePattern =
        #"(?m)^(?:>[ \t]?)?pilgrim-scrap: group=[0-9a-f-]{36} post=[0-9a-f-]{36}[ \t]*$"#

    private static let lineRegex = try! NSRegularExpression(pattern: linePattern)

    /// `body` without its marker lines, for showing a scrap. The stored body keeps them.
    public static func removingMarkerLines(from body: String) -> String {
        guard body.contains(prefix) else { return body }
        return body.components(separatedBy: "\n").filter { line in
            lineRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil
        }.joined(separator: "\n")
    }
}
