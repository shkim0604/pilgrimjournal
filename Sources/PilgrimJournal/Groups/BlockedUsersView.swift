import Combine
import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// The people this user blocked, with unblocking.
@MainActor
final class BlockedUsersModel: ObservableObject {
    @Published private(set) var users: [UserSummary] = []
    @Published private(set) var hasLoaded = false
    @Published var errorMessage: String?

    private let api: any GroupAPI

    init(api: any GroupAPI) {
        self.api = api
    }

    func load() async {
        do {
            users = try await api.blockedUsers()
            errorMessage = nil
        } catch {
            if GroupContentError.isCancellation(error) { return }
            errorMessage = GroupContentError.message(for: error)
        }
        hasLoaded = true
    }

    @discardableResult
    func unblock(_ user: UserSummary) async -> Bool {
        do {
            try await api.unblock(userID: user.id)
            users.removeAll { $0.id == user.id }
            errorMessage = nil
            return true
        } catch {
            errorMessage = GroupContentError.message(for: error)
            return false
        }
    }
}

/// Settings → 차단한 사람 (A7 links it).
struct BlockedUsersView: View {
    @StateObject private var model: BlockedUsersModel
    @State private var confirming: UserSummary?

    init(api: any GroupAPI) {
        _model = StateObject(wrappedValue: BlockedUsersModel(api: api))
    }

    var body: some View {
        List {
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            ForEach(model.users, id: \.id) { user in
                HStack(spacing: JournalTheme.Spacing.medium) {
                    GroupAvatar(user: user, size: 32)
                    Text(user.displayName).foregroundStyle(JournalTheme.ink)
                    Spacer()
                    Button("차단 풀기") { confirming = user }
                        .buttonStyle(.bordered)
                }
            }
        }
        .overlay {
            if model.hasLoaded, model.users.isEmpty, model.errorMessage == nil {
                JournalEmptyState(
                    title: String(localized: "차단한 사람이 없어요"),
                    description: String(localized: "차단하면 서로의 글·댓글·반응이 보이지 않아요."),
                    systemImage: "person.crop.circle.badge.xmark"
                ) {}
            }
        }
        .navigationTitle("차단한 사람")
        .confirmationDialog(
            "차단을 풀까요?",
            isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { user in
            Button("차단 풀기") { Task { await model.unblock(user) } }
            Button("취소", role: .cancel) {}
        } message: { user in
            Text("\(user.displayName) 님의 글과 댓글이 다시 보여요.")
        }
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

/// A member's profile photo, or their initial on a tinted circle.
struct GroupAvatar: View {
    let user: UserSummary
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let photo = user.profilePhoto {
                GroupMediaImage(media: photo)
            } else {
                ZStack {
                    JournalTheme.selection
                    Text(String(user.displayName.prefix(1)))
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(JournalTheme.brandPrimary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}
