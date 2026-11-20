import JournalGroups
import PilgrimAPI
import SwiftUI

/// The content column while a group is selected: its posts, newest first, filtered by kind,
/// cursor-paged and refreshed every 15 seconds while on screen.
struct GroupFeedView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var groups: GroupsController
    let groupID: UUID
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @StateObject private var feed: GroupFeedModel
    @State private var composer: ComposerRequest?

    private struct ComposerRequest: Identifiable {
        let id = UUID()
        let kind: PostKind
    }

    init(
        groups: GroupsController, groupID: UUID,
        preferredCompactColumn: Binding<NavigationSplitViewColumn>
    ) {
        self.groups = groups
        self.groupID = groupID
        _preferredCompactColumn = preferredCompactColumn
        _feed = StateObject(
            wrappedValue: GroupFeedModel(
                api: groups.api, groupID: groupID, onRefreshed: groups.onFeedRefreshed))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            feedList(now: context.date)
        }
        .safeAreaInset(edge: .top, spacing: 0) { filterBar }
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle(group?.name ?? String(localized: "그룹"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) { newPostMenu }
        }
        .environment(\.groupMediaURLResolver, .refreshing(with: groups.api))
        .task(id: groupID) {
            await feed.start()
            await groups.refresh()
            await feed.pollWhileVisible()
        }
        .refreshable { await feed.refresh() }
        .sheet(item: $composer) { request in
            GroupPostComposerSheet.compose(
                GroupPostDraft(kind: request.kind), groups: groups, groupID: groupID,
                prayerNotes: model.groupPrayerNoteSource,
                onPosted: { post in model.selectGroupPost(post.id) })
        }
        .navigationSplitViewColumnWidth(
            min: JournalTheme.timelineWidth.lowerBound,
            ideal: 360,
            max: JournalTheme.timelineWidth.upperBound + 60
        )
    }

    private var group: GroupSummary? { groups.group(groupID) }

    private var canPost: Bool { group?.status != .pendingDeletion }

    // MARK: List

    private func feedList(now: Date) -> some View {
        List(selection: postSelection) {
            if let message = feed.refreshError {
                Label(message, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .listRowBackground(Color.clear)
            }
            ForEach(feed.posts) { post in
                GroupPostCard(post: post, now: now)
                    .background(
                        JournalTheme.paper,
                        in: RoundedRectangle(
                            cornerRadius: JournalTheme.Radius.large, style: .continuous)
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(post.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        Text(
                            "\(post.kind.groupLabel), \(post.author.displayName), \(post.groupDisplayTitle)"
                        )
                    )
                    .task { await feed.loadMoreIfNeeded(after: post) }
            }
            if feed.hasMore {
                loadMoreRow
            }
        }
        .listStyle(.plain)
        .overlay { emptyState }
    }

    /// The end of the list while older posts remain. Its task runs again whenever the cursor
    /// changes, so a page whose posts are all filtered out or expired loads the next one
    /// instead of stopping; after a failure it waits for "다시 시도".
    private var loadMoreRow: some View {
        HStack {
            Spacer()
            if let message = feed.loadMoreError {
                VStack(spacing: 6) {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(JournalTheme.inkSecondary)
                    Button("다시 시도") { Task { await feed.loadMore() } }
                        .font(.footnote)
                }
            } else {
                ProgressView()
            }
            Spacer()
        }
        .padding(.vertical, JournalTheme.Spacing.small)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .task(id: feed.nextCursor) {
            if feed.loadMoreError == nil { await feed.loadMore() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if feed.posts.isEmpty {
            switch feed.loadState {
            case .idle, .loading:
                ProgressView()
            case .failed(let message):
                JournalEmptyState(
                    title: message,
                    description: String(localized: "기록장은 그대로 쓸 수 있어요."),
                    systemImage: "wifi.exclamationmark"
                ) {
                    Button("다시 시도") { Task { await feed.refresh() } }
                }
            case .loaded:
                JournalEmptyState(
                    title: feed.kindFilter == nil
                        ? String(localized: "아직 올라온 글이 없어요")
                        : String(localized: "이 종류의 글이 없어요"),
                    description: String(
                        localized: "기도제목·독후감·간증을 올려 보세요. 글은 기한이 지나면 사라져요."),
                    systemImage: "person.3"
                ) {
                    if canPost {
                        Button("새 글 쓰기") { composer = ComposerRequest(kind: .prayer) }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JournalTheme.Spacing.small) {
                filterChip(nil, title: String(localized: "전체"))
                ForEach(PostKind.allCases, id: \.self) { kind in
                    filterChip(kind, title: kind.groupLabel)
                }
            }
            .padding(.horizontal, JournalTheme.Spacing.regular)
            .padding(.vertical, JournalTheme.Spacing.small)
        }
        // Only behind the chips: by default a colour fills the safe area too and covers the
        // navigation bar's large title.
        .background(JournalTheme.canvas, ignoresSafeAreaEdges: [])
    }

    private func filterChip(_ kind: PostKind?, title: String) -> some View {
        let isSelected = feed.kindFilter == kind
        let tint = kind?.groupColor ?? JournalTheme.brandPrimary
        return Button {
            feed.kindFilter = kind
        } label: {
            // Kinds show their icon only; 전체 has none and stays text.
            Group {
                if let kind {
                    Label(title, systemImage: kind.groupSymbol).labelStyle(.iconOnly)
                } else {
                    Text(title)
                }
            }
            .font(.callout.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? tint : JournalTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? tint.opacity(0.14) : JournalTheme.surfaceMuted, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var newPostMenu: some View {
        Menu {
            ForEach(PostKind.allCases, id: \.self) { kind in
                Button {
                    composer = ComposerRequest(kind: kind)
                } label: {
                    Label(kind.groupLabel, systemImage: kind.groupSymbol)
                }
            }
            Section {
                // A hint, not an action. A title and subtitle fit a menu row; one long Text
                // was cut off.
                Button {
                } label: {
                    Text("기록에서 나누기")
                    Text("기록의 공유 메뉴에서도 올릴 수 있어요")
                }
                .disabled(true)
            }
        } label: {
            Label("새 글", systemImage: "square.and.pencil")
        }
        .disabled(!canPost)
        .help(canPost ? Text("새 글") : Text("삭제 예정인 그룹에는 새로 쓸 수 없어요"))
    }

    private var postSelection: Binding<UUID?> {
        Binding(
            get: { model.selectedGroupPostID },
            set: { postID in
                model.selectGroupPost(postID)
                if postID != nil { preferredCompactColumn = .detail }
            }
        )
    }
}
