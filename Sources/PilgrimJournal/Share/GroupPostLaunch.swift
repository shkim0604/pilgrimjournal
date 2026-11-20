import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// Whether "그룹에 올리기" can open the composer, and if not, what to tell the person.
enum GroupPostReadiness: Equatable {
    case ready
    /// Not signed in to groups, or the sign-up is unfinished: "그룹 시작하기" opens right where
    /// the share flow is, then posting carries on.
    case needsOnboarding
    case blocked(String)

    /// Decided from what the controller knows after `GroupsController.prepareForPosting()`.
    static func evaluate(
        accountState: GroupsAccountState, groups: [GroupSummary], lastError: GroupAPIError?
    ) -> GroupPostReadiness {
        switch accountState {
        case .upgradeRequired:
            return .blocked(GroupMessages.upgradeRequired)
        case .signedOut, .needsProfile:
            return .needsOnboarding
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
    /// sure the person is signed in and in a group they can write to. Someone not signed in to
    /// groups gets "그룹 시작하기" here (the sidebar's sheet host may be off screen on iPhone)
    /// and the composer once that is done; anything else that stands in the way is explained
    /// in an alert. Does nothing while `groups` is nil (`GroupsFeature` off).
    ///
    /// `onPosted` runs after the composer has closed on a successful post, so a sheet that
    /// started it can close itself without racing the composer's own dismissal.
    func groupPostComposer(
        _ request: Binding<GroupPostRequest?>, groups: GroupsController?,
        prayerNotes: GroupPrayerNoteSource? = nil,
        onPosted: @escaping (PostResponse) -> Void = { _ in }
    ) -> some View {
        modifier(
            GroupPostComposerPresenter(
                request: request, groups: groups, prayerNotes: prayerNotes, onPosted: onPosted))
    }
}

private struct GroupPostComposerPresenter: ViewModifier {
    @Binding var request: GroupPostRequest?
    let groups: GroupsController?
    let prayerNotes: GroupPrayerNoteSource?
    let onPosted: (PostResponse) -> Void
    @State private var composing: GroupPostRequest?
    /// The request waiting on "그룹 시작하기".
    @State private var onboarding: GroupPostRequest?
    @State private var posted: PostResponse?
    @State private var blockedMessage: String?
    /// `onboarding`'s request, kept for `continueAfterOnboarding` (the sheet clears its item).
    @State private var waitingRequest: GroupPostRequest?
    @State private var isPreparing = false

    func body(content: Content) -> some View {
        content
            .onChange(of: request?.id) { _, id in
                guard id != nil, let pending = request else { return }
                request = nil
                Task { await open(pending) }
            }
            .sheet(item: $onboarding, onDismiss: continueAfterOnboarding) { _ in
                if let groups {
                    GroupPostOnboardingSheet(groups: groups)
                }
            }
            .sheet(item: $composing, onDismiss: finishPosting) { request in
                if let groups {
                    GroupPostComposerSheet.compose(
                        request.draft, groups: groups, groupID: nil,
                        prayerNotes: prayerNotes, onPosted: { posted = $0 })
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

    private func open(_ pending: GroupPostRequest, afterOnboarding: Bool = false) async {
        guard let groups, !isPreparing, composing == nil, onboarding == nil else { return }
        isPreparing = true
        defer { isPreparing = false }
        let start = GroupTiming.now
        let readiness = await groups.prepareForPosting()
        GroupTiming.log("prepareForPosting", since: start)
        switch readiness {
        case .ready:
            composing = pending
        case .needsOnboarding:
            // Just back from "그룹 시작하기" (the session was lost meanwhile): not a second time.
            guard !afterOnboarding else { return }
            waitingRequest = pending
            onboarding = pending
        case .blocked(let message):
            blockedMessage = message
        }
    }

    /// After "그룹 시작하기" closes: on to the composer once the person can post.
    private func continueAfterOnboarding() {
        guard let pending = waitingRequest else { return }
        waitingRequest = nil
        guard groups?.accountState.hasGroupAccess == true else { return }
        Task { await open(pending, afterOnboarding: true) }
    }

    private func finishPosting() {
        guard let post = posted else { return }
        posted = nil
        onPosted(post)
    }
}

/// "그룹 시작하기" opened from "그룹에 올리기". Closes itself once the person is signed in and
/// signed up, so the composer can follow.
private struct GroupPostOnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var groups: GroupsController

    var body: some View {
        GroupOnboardingSheet(groups: groups)
            .onChange(of: groups.accountState.hasGroupAccess) { _, hasAccess in
                if hasAccess { dismiss() }
            }
    }
}
