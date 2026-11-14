import Foundation
import PilgrimAPI
import SwiftUI

/// One reaction key: the emoji, or the sticker image (a placeholder until stickers load).
struct GroupReactionKeyView: View {
    let key: ReactionKey
    var sticker: StickerResponse?
    var size: CGFloat = 18

    var body: some View {
        switch key {
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size))
        case .sticker:
            if let sticker {
                GroupMediaImage(media: sticker.media, contentMode: .fit)
                    .frame(width: size + 4, height: size + 4)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .accessibilityLabel(Text(sticker.name ?? String(localized: "스티커")))
            } else {
                Image(systemName: "seal")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .accessibilityLabel(Text("스티커"))
            }
        }
    }
}

/// The feed card's read-only reaction line: up to five keys with counts.
struct GroupReactionSummary: View {
    let reactions: [ReactionSummary]

    var body: some View {
        if reactions.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                ForEach(reactions.prefix(5), id: \.key) { reaction in
                    HStack(spacing: 2) {
                        GroupReactionKeyView(key: reaction.key, size: 13)
                        Text("\(reaction.count)")
                            .font(.caption)
                            .foregroundStyle(
                                reaction.reactedByMe
                                    ? JournalTheme.brandPrimary : JournalTheme.inkSecondary)
                    }
                }
                if reactions.count > 5 {
                    Text("+\(reactions.count - 5)")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("반응 \(reactions.reduce(0) { $0 + $1.count })개"))
        }
    }
}

/// The detail column's reactions: every key as a toggle chip, then the picker.
struct GroupReactionBar: View {
    let reactions: [ReactionSummary]
    let stickers: [StickerResponse]
    let canAddMore: Bool
    let onToggle: (ReactionKey) -> Void
    let onOpenPicker: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JournalTheme.Spacing.small) {
                ForEach(reactions, id: \.key) { reaction in
                    Button {
                        onToggle(reaction.key)
                    } label: {
                        HStack(spacing: 4) {
                            GroupReactionKeyView(
                                key: reaction.key, sticker: sticker(for: reaction.key))
                            Text("\(reaction.count)")
                                .font(.callout.monospacedDigit())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(
                            reaction.reactedByMe ? JournalTheme.brandPrimary : JournalTheme.ink
                        )
                        .background(
                            reaction.reactedByMe
                                ? JournalTheme.selection : JournalTheme.surfaceMuted,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().stroke(
                                reaction.reactedByMe ? JournalTheme.brandPrimary : .clear,
                                lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(reaction.reactedByMe ? .isSelected : [])
                    .accessibilityHint(
                        reaction.reactedByMe ? Text("눌러서 반응 취소") : Text("눌러서 반응하기"))
                }
                Button(action: onOpenPicker) {
                    Image(systemName: "face.smiling")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(JournalTheme.surfaceMuted, in: Capsule())
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: "plus")
                                .font(.system(size: 8, weight: .bold))
                                .offset(x: 2, y: -2)
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(canAddMore ? JournalTheme.ink : JournalTheme.inkSecondary)
                .accessibilityLabel(Text("반응 추가"))
            }
        }
    }

    private func sticker(for key: ReactionKey) -> StickerResponse? {
        guard case .sticker(let id) = key else { return nil }
        return stickers.first { $0.id == id }
    }
}
