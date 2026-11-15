import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// Whether "그룹에 올리기" can open the composer, and if not, what to tell the person.
enum GroupPostReadiness: Equatable {
    case ready
    case blocked(String)

    /// Decided from what the controller knows after `GroupsController.prepareForPosting()`.
    static func evaluate(
        accountState: GroupsAccountState, groups: [GroupSummary], lastError: GroupAPIError?
    ) -> GroupPostReadiness {
        switch accountState {
        case .upgradeRequired:
            return .blocked(GroupMessages.upgradeRequired)
        case .signedOut, .needsProfile:
            return .blocked(
                String(localized: "그룹에 올리려면 먼저 사이드바의 그룹에서 ‘그룹 시작하기’를 마쳐 주세요."))
        case .needsSubscription:
            return .blocked(String(localized: "그룹에 올리려면 구독이 필요해요."))
        case .unknown:
            return .blocked(String(localized: "그룹 서버에 연결할 수 없어요. 다시 시도해 주세요."))
        case .signedIn:
            if groups.contains(where: { $0.status != .pendingDeletion }) { return .ready }
            if groups.isEmpty, lastError != nil {
                return .blocked(String(localized: "그룹 서버에 연결할 수 없어요. 다시 시도해 주세요."))
            }
            return .blocked(
                String(localized: "올릴 수 있는 그룹이 없어요. 사이드바의 그룹에서 새 그룹을 만들거나 초대 코드로 참여해 주세요."))
        }
    }
}

extension GroupsController {
    /// Finds out where the user stands and loads the group list if this launch has not yet
    /// (the sidebar usually has), then says whether a post can be written.
    func prepareForPosting() async -> GroupPostReadiness {
        if accountState == .unknown || lastError != nil { await loadAccount() }
        if accountState.hasGroupAccess, !hasLoaded || groups.isEmpty { await refresh() }
        return GroupPostReadiness.evaluate(
            accountState: accountState, groups: groups, lastError: lastError)
    }
}

/// A request to open the group composer with `draft`.
struct GroupPostRequest: Identifiable, Equatable {
    let id = UUID()
    var draft: GroupPostDraft
}

extension View {
    /// Opens the group composer (`GroupPostComposerSheet`) for each `request` set: first makes
    /// sure the person is signed in and in a group they can write to, and explains it in an
    /// alert when not. Does nothing while `groups` is nil (`GroupsFeature` off).
    ///
    /// `onPosted` runs after the composer has closed on a successful post, so a sheet that
    /// started it can close itself without racing the composer's own dismissal.
    func groupPostComposer(
        _ request: Binding<GroupPostRequest?>, groups: GroupsController?,
        onPosted: @escaping (PostResponse) -> Void = { _ in }
    ) -> some View {
        modifier(GroupPostComposerPresenter(request: request, groups: groups, onPosted: onPosted))
    }
}

private struct GroupPostComposerPresenter: ViewModifier {
    @Binding var request: GroupPostRequest?
    let groups: GroupsController?
    let onPosted: (PostResponse) -> Void
    @State private var composing: GroupPostRequest?
    @State private var posted: PostResponse?
    @State private var blockedMessage: String?
    @State private var isPreparing = false

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, id in
                guard id != nil, let pending = request else { return }
                request = nil
                Task { await open(pending) }
            }
            .sheet(item: $composing, onDismiss: finishPosting) { request in
                if let groups {
                    GroupPostComposerSheet.compose(
                        request.draft, groups: groups, groupID: nil,
                        onPosted: { posted = $0 })
                }
            }
            .alert(
                "그룹에 올릴 수 없어요",
                isPresented: Binding(
                    get: { blockedMessage != nil }, set: { if !$0 { blockedMessage = nil } })
            ) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(verbatim: blockedMessage ?? "")
            }
    }

    private func open(_ pending: GroupPostRequest) async {
        guard let groups, !isPreparing, composing == nil else { return }
        isPreparing = true
        defer { isPreparing = false }
        switch await groups.prepareForPosting() {
        case .ready:
            composing = pending
        case .blocked(let message):
            blockedMessage = message
        }
    }

    private func finishPosting() {
        guard let post = posted else { return }
        posted = nil
        onPosted(post)
    }
}
