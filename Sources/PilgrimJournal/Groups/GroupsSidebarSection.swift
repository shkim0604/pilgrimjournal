import JournalGroups
import PilgrimAPI
import SwiftUI

/// The sidebar's 그룹 section: "그룹 시작하기" until the user is signed in to the group server,
/// then the groups they belong to with their unread counts, and the ways in. Shown only while
/// `GroupsFeature` is on (`AppModel.groups` is nil otherwise). A group server that cannot be
/// reached only shows a notice here; the journal keeps working.
struct GroupsSidebarSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var groups: GroupsController
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    var body: some View {
        Section("그룹") {
            switch groups.accountState {
            case .unknown:
                if groups.errorMessage != nil {
                    connectionNotice
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowBackground(Color.clear)
                }
            case .signedOut, .needsProfile:
                actionRow(
                    groups.accountState == .needsProfile
                        ? String(localized: "그룹 가입 마치기") : String(localized: "그룹 시작하기"),
                    systemImage: "person.3"
                ) {
                    groups.beginOnboarding()
                }
                .accessibilityHint("Apple 계정으로 인증하고 그룹 이름을 정합니다.")
                actionRow(String(localized: "초대 코드로 참여"), systemImage: "ticket") {
                    groups.beginJoin()
                }
            case .upgradeRequired:
                Link(destination: GroupsAppStoreLink.url) {
                    Label(GroupMessages.upgradeRequired, systemImage: "arrow.down.app")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                .listRowBackground(Color.clear)
            case .signedIn, .needsSubscription:
                groupRows
            }
        }
        .task { await groups.start() }
        .groupsSheets(groups, preferredCompactColumn: $preferredCompactColumn)
    }

    @ViewBuilder
    private var groupRows: some View {
        ForEach(groups.groups) { group in
            JournalSidebarItem(
                title: group.name,
                systemImage: Self.systemImage(for: group),
                accent: group.status == .active
                    ? JournalTheme.brandPrimary : JournalTheme.accentWarm,
                isSelected: model.selectedGroupID == group.id
            ) {
                model.selectGroup(group.id)
                preferredCompactColumn = .content
            }
            .badge(group.unreadCount)
            .contextMenu { menu(for: group) }
        }
        if groups.errorMessage != nil {
            connectionNotice
        }
        if groups.accountState == .needsSubscription {
            actionRow(String(localized: "구독이 필요해요"), systemImage: "sparkles") {
                groups.requestSubscription()
            }
        }
        actionRow(String(localized: "새 그룹"), systemImage: "plus.circle") {
            groups.beginCreateGroup()
        }
        actionRow(String(localized: "초대 코드로 참여"), systemImage: "ticket") {
            groups.beginJoin()
        }
    }

    private var connectionNotice: some View {
        Button {
            Task { await groups.start() }
        } label: {
            Label(groups.errorMessage ?? "", systemImage: "arrow.clockwise")
                .foregroundStyle(JournalTheme.inkSecondary)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityHint("다시 불러옵니다.")
    }

    @ViewBuilder
    private func menu(for group: GroupSummary) -> some View {
        let capabilities = GroupAdminCapabilities(group: group)
        Button {
            groups.presentedSheet = .settings(groupID: group.id)
        } label: {
            Label("그룹 설정", systemImage: "gearshape")
        }
        if capabilities.canCreateInvites {
            Button {
                groups.presentedSheet = .invites(groupID: group.id)
            } label: {
                Label("초대하기", systemImage: "qrcode")
            }
        }
        if capabilities.isVoting {
            Button {
                groups.presentedSheet = .vote(groupID: group.id)
            } label: {
                Label("새 관리자 투표", systemImage: "checkmark.seal")
            }
        }
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(JournalTheme.brandPrimary)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }

    static func systemImage(for group: GroupSummary) -> String {
        switch group.status {
        case .active: "person.3"
        case .voting: "checkmark.seal"
        case .pendingDeletion: "clock.badge.exclamationmark"
        }
    }
}

extension View {
    /// Hosts every group sheet (`GroupsController.presentedSheet`). Applied by the sidebar
    /// section; Phase 2 can move it to the window root so the feed's buttons can open them
    /// while the sidebar is off screen on iPhone.
    func groupsSheets(
        _ groups: GroupsController, preferredCompactColumn: Binding<NavigationSplitViewColumn>
    ) -> some View {
        modifier(
            GroupsSheetsModifier(groups: groups, preferredCompactColumn: preferredCompactColumn))
    }
}

private struct GroupsSheetsModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var groups: GroupsController
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    func body(content: Content) -> some View {
        content.sheet(item: $groups.presentedSheet, onDismiss: groups.sheetDidDismiss) { sheet in
            sheetContent(sheet)
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: GroupsSheet) -> some View {
        switch sheet {
        case .onboarding:
            GroupOnboardingSheet(groups: groups)
        case .createGroup:
            GroupCreateSheet(groups: groups, onCreated: open)
        case .join(let request):
            GroupJoinSheet(groups: groups, request: request, onJoined: open)
        case .settings(let groupID):
            GroupSettingsSheet(groups: groups, groupID: groupID)
        case .invites(let groupID):
            GroupInviteSheet(groups: groups, groupID: groupID)
        case .vote(let groupID):
            GroupAdminVoteSheet(groups: groups, groupID: groupID)
        case .subscription:
            GroupSubscriptionPlaceholderSheet()
        }
    }

    private func open(_ groupID: UUID) {
        model.selectGroup(groupID)
        preferredCompactColumn = .content
    }
}

/// Stands in for the subscription screen until A8 sets `GroupsController.onSubscriptionRequired`.
private struct GroupSubscriptionPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            JournalEmptyState(
                title: String(localized: "구독이 필요해요"),
                description: String(localized: "그룹을 만들거나 참여하려면 구독이 필요해요. 구독 화면은 준비 중입니다."),
                systemImage: "sparkles"
            ) {}
            .navigationTitle("구독")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}
