import Foundation
import JournalDomain
import PilgrimAPI
import SwiftUI

extension PostKind {
    var groupLabel: String {
        switch self {
        // Its own key: the bare "기도제목" is the prayer notes' checklist wording.
        case .prayer:
            String(
                localized: "groupPost.kind.prayer", defaultValue: "기도제목",
                comment: "Group post kind: prayer requests shared with a group")
        case .bookReport: String(localized: "독후감")
        case .testimony: String(localized: "간증")
        }
    }

    var groupSymbol: String {
        switch self {
        case .prayer: "hands.sparkles"
        case .bookReport: "book.closed"
        case .testimony: "sparkles"
        }
    }

    /// Prayer amber, book report (reading) blue, testimony clay.
    var groupColorToken: KindColorToken {
        switch self {
        case .prayer: .amber
        case .bookReport: .slate
        case .testimony: .clay
        }
    }

    var groupColor: Color { JournalTheme.color(for: groupColorToken) }
}

extension PostResponse {
    var trimmedTitle: String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return title
    }

    /// A one-line name for the post (navigation title, accessibility): the title, the book
    /// title, the first prayer line, or the kind.
    var groupDisplayTitle: String {
        if let trimmedTitle { return trimmedTitle }
        if let book = book?.title, !book.isEmpty { return book }
        if let first = items?.first?.text, !first.isEmpty { return first }
        return kind.groupLabel
    }
}

/// Prayer lines grouped the way a prayer note shows them: consecutive lines with the same
/// section under one heading; lines without a section have no heading.
struct PrayerItemSection {
    /// An item with its index in the post's `items` (how the server names it).
    struct Line: Identifiable {
        var index: Int
        var item: PrayerItem
        var id: Int { index }
    }

    var name: String?
    var items: [Line]

    static func group(_ items: [PrayerItem]) -> [PrayerItemSection] {
        var sections: [PrayerItemSection] = []
        for (index, item) in items.enumerated() {
            let name = item.section.flatMap { $0.isEmpty ? nil : $0 }
            let line = Line(index: index, item: item)
            if let last = sections.last, last.name == name {
                sections[sections.count - 1].items.append(line)
            } else {
                sections.append(PrayerItemSection(name: name, items: [line]))
            }
        }
        return sections
    }
}

/// The kind as a small tinted capsule, icon only; VoiceOver still reads the kind's name.
struct GroupKindBadge: View {
    let kind: PostKind

    var body: some View {
        Label(kind.groupLabel, systemImage: kind.groupSymbol)
            .labelStyle(.iconOnly)
            .accessibilityLabel(kind.groupLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(kind.groupColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(kind.groupColor.opacity(0.12), in: Capsule())
    }
}

/// A group post as a card. `isCompact` truncates long text for the feed; the detail column
/// shows everything.
struct GroupPostCard: View {
    let post: PostResponse
    let now: Date
    var isCompact = true
    var onOpenPhoto: ((Int) -> Void)?
    /// Toggles the item at an index answered; used only in the detail column on one's own post.
    var onToggleAnswer: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.medium) {
            header
            if let title = post.trimmedTitle {
                Text(title)
                    .font(isCompact ? .headline : .title3.weight(.semibold))
                    .foregroundStyle(JournalTheme.ink)
                    .lineLimit(isCompact ? 2 : nil)
            }
            if let book = post.book {
                bookLine(book)
            }
            if let items = post.items, !items.isEmpty {
                prayerItems(items)
            }
            bodyText
            if !post.media.isEmpty {
                GroupPhotoGrid(
                    media: post.media, maxHeight: isCompact ? 180 : 280, onOpen: onOpenPhoto)
            }
            GroupExpiryBadge(post: post, now: now)
            if isCompact {
                footer
            }
        }
        .padding(isCompact ? JournalTheme.Spacing.medium : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: JournalTheme.Spacing.small) {
            GroupAvatar(user: post.author, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(
                    post.author.displayName.isEmpty
                        ? String(localized: "알 수 없음") : post.author.displayName
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(JournalTheme.ink)
                Text(post.createdAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
            Spacer(minLength: JournalTheme.Spacing.small)
            if post.isUnread {
                Circle()
                    .fill(JournalTheme.brandPrimary)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(Text("새 글"))
            }
            GroupKindBadge(kind: post.kind)
        }
    }

    private func bookLine(_ book: BookInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "book")
                .foregroundStyle(PostKind.bookReport.groupColor)
            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(JournalTheme.ink)
            if let author = book.author, !author.isEmpty {
                Text(author)
                    .font(.subheadline)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// Like a prayer note: each section's name, then its lines, each with an open circle or, once
    /// answered, a filled checkmark. Every line shows, in the feed too (at most ten).
    private func prayerItems(_ items: [PrayerItem]) -> some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            ForEach(Array(PrayerItemSection.group(items).enumerated()), id: \.offset) {
                _, section in
                VStack(alignment: .leading, spacing: 4) {
                    if let name = section.name {
                        Text(name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(JournalTheme.inkSecondary)
                    }
                    ForEach(section.items) { line in
                        prayerLine(line)
                    }
                }
            }
            let answered = items.filter { $0.answeredAt != nil }.count
            if isCompact, answered > 0 {
                Label("응답 \(answered)/\(items.count)", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
        }
    }

    @ViewBuilder
    private func prayerLine(_ line: PrayerItemSection.Line) -> some View {
        let isAnswered = line.item.answeredAt != nil
        let row = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isAnswered ? "checkmark.circle.fill" : "circle")
                .font(.footnote)
                .foregroundStyle(PostKind.prayer.groupColor)
                .accessibilityHidden(true)
            Text(line.item.text)
                .foregroundStyle(isAnswered ? JournalTheme.inkSecondary : JournalTheme.ink)
                .lineLimit(isCompact ? 2 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        let value = isAnswered ? String(localized: "응답됨") : String(localized: "기도 중")
        if !isCompact, post.isMine, let onToggleAnswer {
            Button {
                onToggleAnswer(line.index)
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(value)
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityValue(value)
        }
    }

    @ViewBuilder
    private var bodyText: some View {
        if let body = post.body, !body.isEmpty {
            let parts = GroupPostQuote.split(body)
            if let quote = parts.quote {
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(post.kind.groupColor.opacity(0.6))
                        .frame(width: 3)
                    Text(quote)
                        .italic()
                        .foregroundStyle(JournalTheme.inkSecondary)
                        .lineLimit(isCompact ? 3 : nil)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if !parts.body.isEmpty {
                // A prayer post's note shows only its first line in the feed.
                let firstLineOnly = isCompact && post.kind == .prayer
                Text(firstLineOnly ? Self.firstLine(of: parts.body) : parts.body)
                    .foregroundStyle(firstLineOnly ? JournalTheme.inkSecondary : JournalTheme.ink)
                    .lineLimit(firstLineOnly ? 1 : (isCompact ? 6 : nil))
                    .textSelection(.enabled)
            }
        }
    }

    static func firstLine(of text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1).first ?? "")
    }

    private var footer: some View {
        HStack(spacing: JournalTheme.Spacing.medium) {
            GroupReactionSummary(reactions: post.reactions)
            Spacer()
            Label("\(post.commentCount)", systemImage: "bubble.left")
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
                .accessibilityLabel(Text("댓글 \(post.commentCount)개"))
        }
    }
}
