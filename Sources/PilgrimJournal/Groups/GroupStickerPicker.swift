import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// The reaction and comment-sticker picker: system emoji (reactions only) and the group's
/// stickers (≤ 30), with "스티커 만들기" and, for a sticker's creator or the admin, deleting.
struct GroupStickerPicker: View {
    @ObservedObject var model: GroupPostDetailModel
    /// nil hides the emoji row (picking a sticker for a comment).
    var onPickEmoji: ((String) -> Void)?
    let onPickSticker: (StickerResponse) -> Void
    var onReport: ((StickerResponse) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var isCreating = false
    @State private var deleting: StickerResponse?

    private let columns = [GridItem(.adaptive(minimum: 64, maximum: 84), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: JournalTheme.Spacing.large) {
                    if let onPickEmoji {
                        emojiSection(onPickEmoji)
                    }
                    stickerSection
                    if let notice = model.notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(JournalTheme.Spacing.regular)
            }
            .background(JournalTheme.canvas)
            .navigationTitle(onPickEmoji == nil ? Text("스티커") : Text("반응"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .sheet(isPresented: $isCreating) {
                GroupStickerCreateSheet(model: model)
            }
            .confirmationDialog(
                "스티커를 지울까요?",
                isPresented: Binding(
                    get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible,
                presenting: deleting
            ) { sticker in
                Button("지우기", role: .destructive) {
                    Task { await model.deleteSticker(sticker) }
                }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("이 스티커로 한 반응이 사라지고, 댓글에는 ‘지워진 스티커’로 보여요.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 420)
        #endif
    }

    private func emojiSection(_ onPick: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            Text("이모지")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(JournalTheme.inkSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                ForEach(GroupPostDetailModel.reactionEmoji, id: \.self) { emoji in
                    let key = ReactionKey.emoji(emoji)
                    Button {
                        onPick(emoji)
                        dismiss()
                    } label: {
                        Text(emoji)
                            .font(.system(size: 28))
                            .frame(width: 44, height: 44)
                            .background(
                                model.hasReacted(key)
                                    ? JournalTheme.selection : JournalTheme.surfaceMuted,
                                in: RoundedRectangle(cornerRadius: JournalTheme.Radius.small))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canAddReaction(key))
                    .accessibilityAddTraits(model.hasReacted(key) ? .isSelected : [])
                }
            }
            if model.myReactionCount >= APILimits.reactionsPerUserPerPost {
                Text("반응은 한 글에 10개까지 남길 수 있어요")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
        }
    }

    private var stickerSection: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            HStack {
                Text("그룹 스티커 \(model.stickers.count)/\(APILimits.stickersPerGroup)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(JournalTheme.inkSecondary)
                Spacer()
                Button {
                    if model.canCreateSticker {
                        isCreating = true
                    } else {
                        model.notice = String(localized: "이 그룹의 스티커는 30개까지예요")
                    }
                } label: {
                    Label("스티커 만들기", systemImage: "plus.square.on.square")
                        .font(.footnote)
                }
            }
            if model.stickers.isEmpty {
                Text("아직 스티커가 없어요. 사진으로 우리 그룹만의 스티커를 만들어 보세요.")
                    .font(.callout)
                    .foregroundStyle(JournalTheme.inkSecondary)
            } else {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.stickers) { sticker in
                        stickerCell(sticker)
                    }
                }
            }
        }
    }

    private func stickerCell(_ sticker: StickerResponse) -> some View {
        let key = ReactionKey.sticker(sticker.id)
        let isPickable = onPickEmoji == nil || model.canAddReaction(key)
        return Button {
            onPickSticker(sticker)
            dismiss()
        } label: {
            VStack(spacing: 4) {
                GroupMediaImage(media: sticker.media, contentMode: .fit)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: JournalTheme.Radius.small))
                    .overlay {
                        if onPickEmoji != nil, model.hasReacted(key) {
                            RoundedRectangle(cornerRadius: JournalTheme.Radius.small)
                                .stroke(JournalTheme.brandPrimary, lineWidth: 2)
                        }
                    }
                if let name = sticker.name {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(JournalTheme.inkSecondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isPickable)
        .accessibilityLabel(Text(sticker.name ?? String(localized: "스티커")))
        .contextMenu {
            if model.canDelete(sticker) {
                Button("스티커 지우기", systemImage: "trash", role: .destructive) {
                    deleting = sticker
                }
            }
            if let onReport, !sticker.isMine {
                Button("스티커 신고", systemImage: "exclamationmark.bubble") {
                    onReport(sticker)
                    dismiss()
                }
            }
        }
    }
}
