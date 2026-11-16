import Combine
import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// Posts and people this user hid (on all their devices), with undo.
@MainActor
final class HiddenItemsModel: ObservableObject {
    @Published private(set) var posts: [HiddenPost] = []
    @Published private(set) var users: [HiddenUser] = []
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    private let api: any GroupAPI

    init(api: any GroupAPI) {
        self.api = api
    }

    var isEmpty: Bool { posts.isEmpty && users.isEmpty }

    func load() async {
        do {
            let hides = try await api.hides()
            posts = hides.posts
            users = hides.users
            errorMessage = nil
        } catch {
            if GroupContentError.isCancellation(error) { return }
            errorMessage = GroupContentError.message(for: error)
        }
        hasLoaded = true
    }

    @discardableResult
    func unhide(_ post: HiddenPost) async -> Bool {
        do {
            try await api.unhidePost(id: post.postId)
            posts.removeAll { $0.postId == post.postId }
            errorMessage = nil
            return true
        } catch {
            errorMessage = GroupContentError.message(for: error)
            return false
        }
    }

    @discardableResult
    func unhide(_ user: HiddenUser) async -> Bool {
        do {
            try await api.unhideUser(id: user.user.id)
            users.removeAll { $0.user.id == user.user.id }
            errorMessage = nil
            return true
        } catch {
            errorMessage = GroupContentError.message(for: error)
            return false
        }
    }
}

/// Settings → 숨긴 항목 (A7 links it).
struct HiddenItemsView: View {
    @StateObject private var model: HiddenItemsModel

    init(api: any GroupAPI) {
        _model = StateObject(wrappedValue: HiddenItemsModel(api: api))
    }

    var body: some View {
        List {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if !model.users.isEmpty {
                Section {
                    ForEach(model.users, id: \.user.id) { hidden in
                        HStack(spacing: JournalTheme.Spacing.medium) {
                            GroupAvatar(user: hidden.user, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hidden.user.displayName)
                                    .foregroundStyle(JournalTheme.ink)
                                Text("모든 그룹에서 숨김")
                                    .font(.caption)
                                    .foregroundStyle(JournalTheme.inkSecondary)
                            }
                            Spacer()
                            Button("다시 보기") { Task { await model.unhide(hidden) } }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("숨긴 사람")
                }
            }
            if !model.posts.isEmpty {
                Section {
                    ForEach(model.posts, id: \.postId) { hidden in
                        HStack(spacing: JournalTheme.Spacing.medium) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hidden.title ?? String(localized: "제목 없는 글"))
                                    .foregroundStyle(JournalTheme.ink)
                                    .lineLimit(1)
                                Text(hidden.groupName)
                                    .font(.caption)
                                    .foregroundStyle(JournalTheme.inkSecondary)
                            }
                            Spacer()
                            Button("다시 보기") { Task { await model.unhide(hidden) } }
                                .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("숨긴 글")
                }
            }
        }
        .overlay {
            if model.hasLoaded, model.isEmpty, model.errorMessage == nil {
                JournalEmptyState(
                    title: String(localized: "숨긴 항목이 없어요"),
                    description: String(localized: "숨긴 글과 사람은 내 기기에서만 보이지 않아요."),
                    systemImage: "eye.slash"
                ) {}
            }
        }
        .navigationTitle("숨긴 항목")
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}
