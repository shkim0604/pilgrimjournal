import PilgrimAPI
import SwiftUI

/// The sidebar's 그룹 section: the groups this user belongs to with their unread counts, and
/// the ways in. Shown only while `GroupsFeature` is on (`AppModel.groups` is nil otherwise).
///
/// T0.3 stub: "그룹 만들기" and "초대 코드로 참여" open placeholders until A2 brings the
/// onboarding, create and join flows.
struct GroupsSidebarSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var groups: GroupsController
    @Binding var preferredCompactColumn: NavigationSplitViewColumn

    var body: some View {
        Section("그룹") {
            ForEach(groups.groups) { group in
                JournalSidebarItem(
                    title: group.name,
                    systemImage: "person.3",
                    accent: JournalTheme.brandPrimary,
                    isSelected: model.selectedGroupID == group.id
                ) {
                    model.selectGroup(group.id)
                    preferredCompactColumn = .content
                }
                .badge(group.unreadCount)
            }
            if let message = groups.errorMessage {
                Button {
                    Task { await groups.refresh() }
                } label: {
                    Label(message, systemImage: "arrow.clockwise")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityHint("다시 불러옵니다.")
            }
            Button {
                groups.isPresentingCreateGroup = true
            } label: {
                Label("그룹 만들기", systemImage: "plus.circle")
                    .foregroundStyle(JournalTheme.brandPrimary)
            }
            .buttonStyle(.plain)
            Button {
                groups.isPresentingJoinGroup = true
            } label: {
                Label("초대 코드로 참여", systemImage: "ticket")
                    .foregroundStyle(JournalTheme.brandPrimary)
            }
            .buttonStyle(.plain)
        }
        .task { await groups.refresh() }
        .sheet(isPresented: $groups.isPresentingCreateGroup) {
            GroupsPlaceholderSheet(title: String(localized: "그룹 만들기"))
        }
        .sheet(isPresented: $groups.isPresentingJoinGroup) {
            GroupsPlaceholderSheet(title: String(localized: "초대 코드로 참여"))
        }
    }
}

/// Stands in for the create and join sheets until A2.
private struct GroupsPlaceholderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        NavigationStack {
            JournalEmptyState(
                title: title,
                description: String(localized: "준비 중입니다."),
                systemImage: "person.3"
            ) {}
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .frame(minWidth: 320, minHeight: 240)
    }
}
