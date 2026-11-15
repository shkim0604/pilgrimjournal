import Foundation

/// Turns a group post into a journal entry (design.md 15절 "본문"):
///
/// ```markdown
/// > 스크랩 · 수요 기도모임
/// > 민지 · 기도제목 · 2026년 11월 14일에 올림 · 데드라인 2026년 11월 20일
/// > pilgrim-scrap: group=<groupId> post=<postId>
///
/// - 어머니 검사 결과가 좋게 나오도록 기도해 주세요 (엄마/건강)
///
/// ![](attachment:<첨부 UUID>)
///
/// ---
///
/// **댓글**
///
/// > 준호 · 11월 14일: 함께 기도할게요 🙏
/// > 수아 · 11월 15일: (스티커)
/// ```
///
/// A book report puts `**<책 제목>** · <저자>` right after the header. Comment photos follow
/// their comment's quote as image lines. No comments, no comment section. Pure: the same
/// input (and attachment IDs) always gives the same entry.
public enum ScrapComposer {
    public static func compose(
        post: ScrapPost,
        comments: [ScrapComment],
        labels: ScrapLabels = .korean,
        makeAttachmentID: () -> UUID = { UUID() }
    ) -> ScrapComposition {
        let timeZone = TimeZone(identifier: post.timeZoneIdentifier) ?? .current
        var attachments: [ScrapAttachment] = []
        func imageLines(_ mediaIDs: [UUID]) -> String {
            mediaIDs.map { mediaID in
                let attachment = ScrapAttachment(
                    id: makeAttachmentID(), mediaID: mediaID,
                    originalName: "scrap-\(attachments.count + 1).jpg")
                attachments.append(attachment)
                return "![](attachment:\(attachment.id.uuidString))"
            }.joined(separator: "\n\n")
        }

        var blocks = [header(post, labels: labels, timeZone: timeZone)]
        if post.kind == .bookReport, let book = post.book, let title = clean(book.title) {
            blocks.append(
                ["**\(title)**", clean(book.author)].compactMap { $0 }.joined(separator: " · "))
        }
        let items = post.items.compactMap { prayerLine($0, labels: labels) }
        if !items.isEmpty { blocks.append(items.joined(separator: "\n")) }
        if let body = post.body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
            blocks.append(body)
        }
        if !post.photoIDs.isEmpty { blocks.append(imageLines(post.photoIDs)) }

        if !comments.isEmpty {
            blocks.append("---")
            blocks.append("**\(labels.comments)**")
            var quotes: [String] = []
            for comment in comments {
                quotes.append(commentQuote(comment, labels: labels, timeZone: timeZone))
                if !comment.photoIDs.isEmpty {
                    blocks.append(quotes.joined(separator: "\n"))
                    quotes = []
                    blocks.append(imageLines(comment.photoIDs))
                }
            }
            if !quotes.isEmpty { blocks.append(quotes.joined(separator: "\n")) }
        }

        let notebookName = notebookName(groupName: post.groupName, labels: labels)
        var draft = JournalEntryDraft(
            kind: .scrap,
            title: title(post, labels: labels),
            body: blocks.joined(separator: "\n\n"),
            occurredAt: post.createdAt,
            originalTimeZone: post.timeZoneIdentifier)
        draft.notebookName = notebookName
        return ScrapComposition(
            draft: draft, attachments: attachments, notebookName: notebookName)
    }

    /// "스크랩 · <그룹 이름>" (U+00B7 with one space either side), or just "스크랩" for a
    /// nameless group.
    public static func notebookName(groupName: String, labels: ScrapLabels = .korean) -> String {
        guard let name = clean(groupName) else { return labels.scrap }
        return "\(labels.scrap) · \(name)"
    }

    /// The post's title; otherwise a book report's book title, or "<작성자>의 기도제목" /
    /// "<작성자>의 간증".
    public static func title(_ post: ScrapPost, labels: ScrapLabels = .korean) -> String {
        if let title = clean(post.title) { return title }
        let author = clean(post.authorName) ?? ""
        switch post.kind {
        case .bookReport: return clean(post.book?.title) ?? labels.bookReportKind
        case .prayer: return labels.prayerTitle(author)
        case .testimony: return labels.testimonyTitle(author)
        }
    }

    // MARK: Parts

    private static func header(
        _ post: ScrapPost, labels: ScrapLabels, timeZone: TimeZone
    ) -> String {
        var source = [
            clean(post.authorName) ?? "",
            labels.kindName(post.kind),
            labels.posted(longDate(post.createdAt, labels: labels, timeZone: timeZone)),
        ]
        if let deadline = post.deadline, let date = dayDate(deadline) {
            source.append(labels.deadline(longDate(date, labels: labels, timeZone: utc)))
        }
        let group = clean(post.groupName).map { "\(labels.scrap) · \($0)" } ?? labels.scrap
        return [
            "> \(group)",
            "> \(source.filter { !$0.isEmpty }.joined(separator: " · "))",
            "> \(ScrapMarker.line(groupID: post.groupID, postID: post.id))",
        ].joined(separator: "\n")
    }

    /// "- <내용> (<누구>/<주제>)", either part of the bracket optional.
    private static func prayerLine(_ line: ScrapPost.PrayerLine, labels: ScrapLabels) -> String? {
        guard let text = clean(line.text) else { return nil }
        let topic = clean(line.topic).flatMap { labels.topicName($0) }
        let about = [clean(line.who), topic].compactMap { $0 }
        return about.isEmpty ? "- \(text)" : "- \(text) (\(about.joined(separator: "/")))"
    }

    /// "> <작성자> · <월 일>: <내용>", continuing a multi-line comment on more `>` lines.
    private static func commentQuote(
        _ comment: ScrapComment, labels: ScrapLabels, timeZone: TimeZone
    ) -> String {
        let lead = [
            clean(comment.authorName),
            shortDate(comment.createdAt, labels: labels, timeZone: timeZone),
        ].compactMap { $0 }.joined(separator: " · ")
        var text = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if comment.hasSticker {
            text = text.isEmpty ? labels.sticker : "\(text) \(labels.sticker)"
        }
        guard !text.isEmpty else { return "> \(lead)" }
        let lines = text.components(separatedBy: .newlines)
        let rest = lines.dropFirst().map { $0.isEmpty ? ">" : "> \($0)" }
        return (["> \(lead): \(lines[0])"] + rest).joined(separator: "\n")
    }

    // MARK: Helpers

    /// Trimmed, with line breaks folded to spaces so a name can't break the header's quote.
    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let folded = value.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return folded.isEmpty ? nil : folded
    }

    private static let utc = TimeZone(identifier: "UTC")!

    private static func dayDate(_ day: ScrapPost.Day) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day))
    }

    private static func longDate(_ date: Date, labels: ScrapLabels, timeZone: TimeZone) -> String {
        format(date, template: "yMMMMd", labels: labels, timeZone: timeZone)
    }

    private static func shortDate(_ date: Date, labels: ScrapLabels, timeZone: TimeZone) -> String {
        format(date, template: "MMMMd", labels: labels, timeZone: timeZone)
    }

    private static func format(
        _ date: Date, template: String, labels: ScrapLabels, timeZone: TimeZone
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = labels.locale
        let formatter = DateFormatter()
        formatter.locale = labels.locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
