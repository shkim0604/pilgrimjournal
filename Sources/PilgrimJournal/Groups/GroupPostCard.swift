import Foundation
import JournalDomain
import PilgrimAPI
import SwiftUI

extension PostKind {
    var groupLabel: String {
        switch self {
        case .prayer: String(localized: "기도제목")
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

/// The kind as a small tinted capsule.
struct GroupKindBadge: View {
    let kind: PostKind

    var body: some View {
        Label(kind.groupLabel, systemImage: kind.groupSymbol)
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

    private func prayerItems(_ items: [PrayerItem]) -> some View {
        let shown = isCompact ? Array(items.prefix(4)) : items
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(PostKind.prayer.groupColor)
                        .frame(width: 5, height: 5)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.text)
                            .foregroundStyle(JournalTheme.ink)
                            .lineLimit(isCompact ? 2 : nil)
                        if let who = item.who, !who.isEmpty {
                            Text("\(who) 위해")
                                .font(.caption)
                                .foregroundStyle(JournalTheme.inkSecondary)
                        }
                    }
                }
            }
            if items.count > shown.count {
                Text("외 \(items.count - shown.count)개")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
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
                Text(parts.body)
                    .foregroundStyle(JournalTheme.ink)
                    .lineLimit(isCompact ? 6 : nil)
                    .textSelection(.enabled)
            }
        }
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
