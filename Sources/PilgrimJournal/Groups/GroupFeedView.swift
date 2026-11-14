import JournalGroups
import PilgrimAPI
import SwiftUI

/// The content column while a group is selected: its posts, newest first.
///
/// T0.3 stub: loads the first page once per group and lets a post be selected. A3 replaces it
/// with the real feed (cursor paging, 15-second polling, expiry badges, per-kind cards).
struct GroupFeedView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var groups: GroupsController
    let groupID: UUID
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @State private var posts: [PostResponse] = []
    @State private var loadFailed = false

    var body: some View {
        List(selection: postSelection) {
            ForEach(posts) { post in
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(of: post))
                        .font(.headline)
                        .foregroundStyle(JournalTheme.ink)
                    Text(post.author.displayName)
                        .font(.subheadline)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                .tag(post.id)
            }
        }
        .overlay {
            if posts.isEmpty {
                JournalEmptyState(
                    title: loadFailed
                        ? String(localized: "그룹 글을 불러오지 못했어요")
                        : String(localized: "아직 올라온 글이 없어요"),
                    description: String(localized: "그룹 피드는 준비 중입니다."),
                    systemImage: "person.3"
                ) {}
            }
        }
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle(groups.group(groupID)?.name ?? String(localized: "그룹"))
        .task(id: groupID) { await load() }
        .navigationSplitViewColumnWidth(
            min: JournalTheme.timelineWidth.lowerBound,
            ideal: 330,
            max: JournalTheme.timelineWidth.upperBound
        )
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

    private func load() async {
        do {
            posts = try await groups.api.posts(groupID: groupID, cursor: nil, limit: nil).items
            loadFailed = false
        } catch {
            posts = []
            loadFailed = true
        }
    }

    static func title(of post: PostResponse) -> String {
        let title = post.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        return post.book?.title ?? String(localized: "제목 없음")
    }
}
