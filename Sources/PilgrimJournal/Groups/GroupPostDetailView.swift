import JournalGroups
import PhotosUI
import PilgrimAPI
import SwiftUI

/// The detail column while a group is selected: the selected post, or a placeholder.
struct GroupPostDetailView: View {
    @ObservedObject var groups: GroupsController
    let groupID: UUID
    let postID: UUID?

    var body: some View {
        Group {
            if let postID {
                GroupPostDetailContent(
                    groups: groups, groupID: groupID, postID: postID,
                    isAdmin: isAdmin
                )
                .id(postID)
            } else {
                JournalEmptyState(
                    title: groups.group(groupID)?.name ?? String(localized: "그룹"),
                    description: String(localized: "왼쪽 피드에서 글을 고르세요."),
                    systemImage: "person.3"
                ) {}
            }
        }
        .background(JournalTheme.canvas)
        .environment(\.groupMediaURLResolver, .refreshing(with: groups.api))
    }

    /// Admin actions are hidden from everyone while an admin vote is open.
    private var isAdmin: Bool {
        guard let group = groups.group(groupID) else { return false }
        return group.isAdmin && group.status != .voting
    }
}

private struct GroupPostDetailContent: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: GroupPostDetailModel
    @State private var report: ReportRequest?
    @State private var pendingReport: ReportRequest?
    @State private var picker: PickerMode?
    @State private var photoViewer: PhotoViewerRequest?
    @State private var isConfirmingExtend = false
    @State private var isConfirmingDelete = false
    @State private var blocking: UserSummary?
    @State private var commentPhotoSelection: [PhotosPickerItem] = []
    let groupID: UUID
    let api: any GroupAPI

    private struct ReportRequest: Identifiable {
        let target: GroupReportTarget
        let author: UserSummary?
        var id: String { target.id }
    }

    private enum PickerMode: String, Identifiable {
        case reaction, commentSticker
        var id: String { rawValue }
    }

    private struct PhotoViewerRequest: Identifiable {
        let id = UUID()
        let media: [MediaRef]
        let index: Int
    }

    init(groups: GroupsController, groupID: UUID, postID: UUID, isAdmin: Bool) {
        self.groupID = groupID
        self.api = groups.api
        _model = StateObject(
            wrappedValue: GroupPostDetailModel(
                api: groups.api, postID: postID, groupID: groupID, isAdmin: isAdmin,
                prepareImage: GroupImagePreparation.current))
    }

    var body: some View {
        dialogs(sheets(content.task { await model.load() }))
            .onChange(of: commentPhotoSelection) { _, items in
                guard !items.isEmpty else { return }
                Task { await importCommentPhotos(items) }
            }
    }

    private func reportSheet(_ request: ReportRequest) -> GroupReportSheet {
        var hidePost: (() async -> Void)?
        if request.target.type == .post {
            hidePost = { await hideAndClose() }
        }
        return GroupReportSheet(
            api: api, target: request.target, groupID: groupID, author: request.author,
            onHidePost: hidePost, onBlock: { user in await block(user) })
    }

    private func stickerPicker(_ mode: PickerMode) -> GroupStickerPicker {
        let pickEmoji: ((String) -> Void)? =
            mode == .reaction
            ? { emoji in Task { await model.toggleReaction(.emoji(emoji)) } } : nil
        return GroupStickerPicker(
            model: model,
            onPickEmoji: pickEmoji,
            onPickSticker: { sticker in
                if mode == .reaction {
                    Task { await model.toggleReaction(.sticker(sticker.id)) }
                } else {
                    model.commentSticker = sticker
                }
            },
            onReport: { sticker in
                pendingReport = ReportRequest(
                    target: .sticker(sticker.id), author: sticker.createdBy)
            })
    }

    private func showPendingReport() {
        guard let pendingReport else { return }
        report = pendingReport
        self.pendingReport = nil
    }

    private func sheets(_ view: some View) -> some View {
        view
            .sheet(item: $report) { reportSheet($0) }
            .sheet(item: $picker, onDismiss: showPendingReport) { stickerPicker($0) }
            .sheet(item: $photoViewer) { request in
                GroupPhotoViewer(media: request.media, index: request.index)
            }
    }

    private var isBlocking: Binding<Bool> {
        Binding(get: { blocking != nil }, set: { if !$0 { blocking = nil } })
    }

    private func dialogs(_ view: some View) -> some View {
        view
            .confirmationDialog(
                "토론을 일주일 연장할까요?", isPresented: $isConfirmingExtend,
                titleVisibility: .visible
            ) {
                Button("토론 연장 +1주") { Task { await model.extendDiscussion() } }
                Button("취소", role: .cancel) {}
            } message: {
                extendMessage
            }
            .confirmationDialog(
                "이 글을 내릴까요?", isPresented: $isConfirmingDelete, titleVisibility: .visible
            ) {
                Button("글 내리기", role: .destructive) {
                    Task { if await model.deletePost() { closePost() } }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("모든 멤버에게서 바로 사라지고 되돌릴 수 없어요.")
            }
            .confirmationDialog(
                "차단할까요?", isPresented: isBlocking, titleVisibility: .visible,
                presenting: blocking
            ) { user in
                Button("\(user.displayName) 님 차단", role: .destructive) {
                    Task { await block(user) }
                }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("서로의 글·댓글·반응이 보이지 않게 돼요. 상대에게는 알리지 않아요.")
            }
    }

    @ViewBuilder
    private var extendMessage: some View {
        if let date = model.extendedExpiryPreview {
            Text("\(GroupExpiryText.visibleUntil(date, calendar: .current)) 보이게 돼요.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .gone:
            JournalEmptyState(
                title: GroupContentError.goneMessage,
                description: String(localized: "기한이 지났거나 내려진 글입니다."),
                systemImage: "clock.badge.xmark"
            ) {}
        case .failed(let message):
            JournalEmptyState(
                title: message,
                description: String(localized: "기록장은 그대로 쓸 수 있어요."),
                systemImage: "wifi.exclamationmark"
            ) {
                Button("다시 시도") { Task { await model.load() } }
            }
        case .loaded:
            if let post = model.post {
                loaded(post)
            }
        }
    }

    // MARK: Loaded

    private func loaded(_ post: PostResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JournalTheme.Spacing.large) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    GroupPostCard(post: post, now: context.date, isCompact: false) { index in
                        photoViewer = PhotoViewerRequest(media: post.media, index: index)
                    }
                }
                if model.canExtend {
                    extendRow(post)
                }
                GroupReactionBar(
                    reactions: post.reactions,
                    stickers: model.stickers,
                    canAddMore: model.myReactionCount < APILimits.reactionsPerUserPerPost,
                    onToggle: { key in Task { await model.toggleReaction(key) } },
                    onOpenPicker: { picker = .reaction }
                )
                Divider()
                commentsSection(post)
            }
            .frame(maxWidth: JournalTheme.editorMaxWidth, alignment: .leading)
            .padding(JournalTheme.Spacing.regular)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { commentBar }
        .navigationTitle(post.groupDisplayTitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) { overflowMenu(post) }
        }
    }

    private func extendRow(_ post: PostResponse) -> some View {
        HStack {
            if post.extensionCount > 0 {
                Text("토론 연장 \(post.extensionCount)회")
                    .font(.footnote)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
            Spacer()
            Button {
                isConfirmingExtend = true
            } label: {
                Label("토론 연장 +1주", systemImage: "calendar.badge.plus")
            }
            .buttonStyle(.bordered)
            .tint(PostKind.bookReport.groupColor)
            .disabled(model.isWorking)
        }
    }

    private func overflowMenu(_ post: PostResponse) -> some View {
        Menu {
            if model.canDeletePost {
                Button("글 내리기", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
            if !post.isMine {
                Button("이 글 숨기기", systemImage: "eye.slash") {
                    Task { if await model.hidePost() { closePost() } }
                }
                Button(
                    "\(post.author.displayName) 님 숨기기",
                    systemImage: "person.crop.circle.badge.minus"
                ) {
                    Task { if await model.hide(post.author) { closePost() } }
                }
                Button("\(post.author.displayName) 님 차단", systemImage: "hand.raised") {
                    blocking = post.author
                }
                Divider()
                Button("글 신고", systemImage: "exclamationmark.bubble") {
                    report = ReportRequest(target: .post(post.id), author: post.author)
                }
                Button("사람 신고", systemImage: "person.crop.circle.badge.exclamationmark") {
                    report = ReportRequest(target: .user(post.author), author: post.author)
                }
            }
        } label: {
            Label("더 보기", systemImage: "ellipsis.circle")
        }
        .disabled(model.isWorking)
    }

    // MARK: Comments

    private func commentsSection(_ post: PostResponse) -> some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.medium) {
            Text("댓글 \(post.commentCount)")
                .font(.headline)
                .foregroundStyle(JournalTheme.ink)
            if model.comments.isEmpty {
                Text("아직 댓글이 없어요.")
                    .font(.callout)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
            ForEach(model.comments) { comment in
                commentRow(comment)
            }
            if model.commentsCursor != nil {
                Button("댓글 더 보기") { Task { await model.loadMoreComments() } }
                    .font(.callout)
            }
        }
    }

    private func commentRow(_ comment: CommentResponse) -> some View {
        HStack(alignment: .top, spacing: JournalTheme.Spacing.small) {
            GroupAvatar(user: comment.author, size: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.author.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(JournalTheme.ink)
                    Text(comment.createdAt, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                if !comment.body.isEmpty {
                    Text(comment.body)
                        .foregroundStyle(JournalTheme.ink)
                        .textSelection(.enabled)
                }
                if let sticker = comment.sticker {
                    GroupMediaImage(media: sticker.media, contentMode: .fit)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: JournalTheme.Radius.small))
                        .accessibilityLabel(Text(sticker.name ?? String(localized: "스티커")))
                } else if comment.stickerRemoved {
                    Label("지워진 스티커", systemImage: "seal")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                if !comment.media.isEmpty {
                    GroupPhotoGrid(media: comment.media, maxHeight: 160) { index in
                        photoViewer = PhotoViewerRequest(media: comment.media, index: index)
                    }
                }
            }
            Spacer(minLength: 0)
            commentMenu(comment)
        }
    }

    private func commentMenu(_ comment: CommentResponse) -> some View {
        Menu {
            if model.canDelete(comment) {
                Button("댓글 지우기", systemImage: "trash", role: .destructive) {
                    Task { await model.deleteComment(comment) }
                }
            }
            if !comment.isMine {
                Button("댓글 신고", systemImage: "exclamationmark.bubble") {
                    report = ReportRequest(target: .comment(comment.id), author: comment.author)
                }
                Button(
                    "\(comment.author.displayName) 님 숨기기",
                    systemImage: "person.crop.circle.badge.minus"
                ) {
                    Task { await model.hide(comment.author) }
                }
                Button("\(comment.author.displayName) 님 차단", systemImage: "hand.raised") {
                    blocking = comment.author
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(JournalTheme.inkSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("댓글 메뉴"))
    }

    private var commentBar: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            if let notice = model.notice {
                HStack {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Spacer()
                    Button {
                        model.notice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("닫기"))
                }
            }
            if let sticker = model.commentSticker {
                HStack(spacing: 6) {
                    GroupMediaImage(media: sticker.media, contentMode: .fit)
                        .frame(width: 36, height: 36)
                    Text(sticker.name ?? String(localized: "스티커"))
                        .font(.caption)
                    Button {
                        model.commentSticker = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("스티커 빼기"))
                }
            }
            if !model.commentPhotos.isEmpty {
                GroupLocalPhotoStrip(photos: model.commentPhotos) { model.removeCommentPhoto($0) }
            }
            HStack(alignment: .bottom, spacing: JournalTheme.Spacing.small) {
                Button {
                    picker = .commentSticker
                } label: {
                    Image(systemName: "face.smiling")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("스티커 붙이기"))
                PhotosPicker(
                    selection: $commentPhotoSelection,
                    maxSelectionCount: max(
                        1, APILimits.photosPerComment - model.commentPhotos.count),
                    matching: .images
                ) {
                    Image(systemName: "photo")
                }
                .buttonStyle(.plain)
                .disabled(model.commentPhotos.count >= APILimits.photosPerComment)
                .accessibilityLabel(Text("사진 붙이기"))
                TextField("댓글 쓰기", text: $model.commentText, axis: .vertical)
                    .lineLimit(1...5)
                    .journalMetadataField()
                if model.isSendingComment {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.sendComment() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        model.canSendComment ? JournalTheme.brandPrimary : JournalTheme.inkSecondary
                    )
                    .disabled(!model.canSendComment)
                    .accessibilityLabel(Text("댓글 보내기"))
                }
            }
            if model.commentText.count > APILimits.commentBodyMax {
                Text("댓글은 \(APILimits.commentBodyMax)자까지 쓸 수 있어요")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(JournalTheme.Spacing.medium)
        .background(.bar)
    }

    // MARK: Actions

    private func block(_ user: UserSummary) async {
        let closes = model.post?.author.id == user.id
        if await model.block(user), closes { closePost() }
    }

    private func hideAndClose() async {
        if await model.hidePost() { closePost() }
    }

    private func closePost() {
        appModel.selectGroupPost(nil)
    }

    private func importCommentPhotos(_ items: [PhotosPickerItem]) async {
        var data: [Data] = []
        for item in items {
            if let photo = try? await item.loadTransferable(type: Data.self) {
                data.append(photo)
            }
        }
        commentPhotoSelection = []
        model.addCommentPhotos(data)
    }
}
