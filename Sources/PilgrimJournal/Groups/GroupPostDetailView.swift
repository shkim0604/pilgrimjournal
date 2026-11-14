import JournalGroups
import PilgrimAPI
import SwiftUI

/// The detail column while a group is selected: the selected post, or a placeholder.
///
/// T0.3 stub: shows the post's text. A3 replaces it with comments, reactions, discussion
/// extension, take-down, report, block and hide.
struct GroupPostDetailView: View {
    @ObservedObject var groups: GroupsController
    let groupID: UUID
    let postID: UUID?
    @State private var post: PostResponse?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let postID, let post, post.id == postID {
                ScrollView {
                    VStack(alignment: .leading, spacing: JournalTheme.Spacing.medium) {
                        Text(GroupFeedView.title(of: post))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(JournalTheme.ink)
                        Text(post.author.displayName)
                            .font(.subheadline)
                            .foregroundStyle(JournalTheme.inkSecondary)
                        if let body = post.body, !body.isEmpty {
                            Text(body)
                                .foregroundStyle(JournalTheme.ink)
                        }
                        ForEach(post.items ?? [], id: \.self) { item in
                            Label(item.text, systemImage: "heart")
                                .foregroundStyle(JournalTheme.ink)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(JournalTheme.Spacing.regular)
                }
            } else if postID != nil && loadFailed {
                JournalEmptyState(
                    title: String(localized: "이 글은 더 이상 볼 수 없어요"),
                    description: String(localized: "기한이 지났거나 내려진 글입니다."),
                    systemImage: "clock.badge.xmark"
                ) {}
            } else {
                JournalEmptyState(
                    title: groups.group(groupID)?.name ?? String(localized: "그룹"),
                    description: String(localized: "왼쪽 피드에서 글을 고르세요."),
                    systemImage: "person.3"
                ) {}
            }
        }
        .background(JournalTheme.canvas)
        .task(id: postID) { await load() }
    }

    private func load() async {
        guard let postID else {
            post = nil
            loadFailed = false
            return
        }
        do {
            post = try await groups.api.post(id: postID)
            loadFailed = false
        } catch {
            post = nil
            loadFailed = true
        }
    }
}
