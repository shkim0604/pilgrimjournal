import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// A group's settings: its name, my notification switches, members (remove, unban, hand over
/// the admin role), invites, the admin vote, leaving and — for the admin — deleting with the
/// 7-day grace. While a vote is open there is no admin, so the admin parts are hidden.
struct GroupSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel
    @ObservedObject var groups: GroupsController
    @StateObject private var model: GroupSettingsModel
    @State private var isConfirmingLeave = false
    @State private var isConfirmingDelete = false
    @State private var isPickingSuccessor = false

    init(groups: GroupsController, groupID: UUID) {
        self.groups = groups
        _model = StateObject(wrappedValue: GroupSettingsModel(groups: groups, groupID: groupID))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let summary = model.summary, let capabilities = model.capabilities {
                    content(summary, capabilities)
                } else if model.isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
                if let message = model.message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Button("다시 불러오기") { Task { await model.load() } }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(JournalTheme.canvas)
            .navigationTitle(model.summary?.name ?? String(localized: "그룹 설정"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task { await model.load() }
            .navigationDestination(isPresented: $isPickingSuccessor) {
                GroupSuccessorPicker(model: model) {
                    left()
                }
            }
        }
        .frame(minWidth: 440, minHeight: 600)
    }

    @ViewBuilder
    private func content(_ summary: GroupSummary, _ capabilities: GroupAdminCapabilities)
        -> some View
    {
        if summary.status != .active {
            Section {
                GroupStatusBanner(group: summary)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }

        Section("그룹") {
            if capabilities.canRename {
                HStack {
                    TextField("그룹 이름", text: $model.nameText)
                        .onSubmit { Task { await model.saveName() } }
                    Button("저장") { Task { await model.saveName() } }
                        .disabled(!model.canSaveName || model.isWorking)
                }
            } else {
                LabeledContent("이름", value: summary.name)
            }
            LabeledContent("관리자", value: summary.admin?.displayName ?? String(localized: "없음"))
        }

        if capabilities.isVoting {
            Section {
                NavigationLink {
                    GroupAdminVoteView(groups: groups, groupID: model.groupID)
                } label: {
                    Label("새 관리자 투표", systemImage: "checkmark.seal")
                }
            }
        }

        Section {
            Toggle(
                "새 글 알림",
                isOn: Binding(
                    get: { model.notifications.newPostPushEnabled },
                    set: { value in
                        var settings = model.notifications
                        settings.newPostPushEnabled = value
                        Task { await model.setNotifications(settings) }
                    }))
            Toggle(
                "Daily Report에 넣기",
                isOn: Binding(
                    get: { model.notifications.dailyReportEnabled },
                    set: { value in
                        var settings = model.notifications
                        settings.dailyReportEnabled = value
                        Task { await model.setNotifications(settings) }
                    }))
        } header: {
            Text("알림")
        } footer: {
            Text("이 그룹에만 적용돼요. 알림 문구에는 기도 내용이나 글 본문이 들어가지 않아요.")
        }

        Section {
            NavigationLink {
                GroupMembersView(model: model)
            } label: {
                LabeledContent("멤버", value: String(localized: "\(summary.memberCount)명"))
            }
            if capabilities.canManageInvites {
                NavigationLink {
                    GroupInvitesView(groups: groups, groupID: model.groupID)
                } label: {
                    Label("초대 링크·QR", systemImage: "qrcode")
                }
            }
        }

        Section {
            Button("그룹 나가기", role: .destructive) { isConfirmingLeave = true }
                .disabled(model.isWorking)
                .confirmationDialog(
                    leaveTitle(summary), isPresented: $isConfirmingLeave, titleVisibility: .visible
                ) {
                    leaveActions(summary)
                } message: {
                    Text(leaveMessage(summary))
                }
            if capabilities.canDeleteGroup {
                Button("그룹 삭제", role: .destructive) { isConfirmingDelete = true }
                    .disabled(model.isWorking)
                    .confirmationDialog(
                        "그룹을 삭제할까요?", isPresented: $isConfirmingDelete,
                        titleVisibility: .visible
                    ) {
                        Button("7일 뒤 삭제", role: .destructive) {
                            Task { _ = await model.deleteGroup() }
                        }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text(
                            "그룹은 7일 뒤에 모든 글과 사진과 함께 지워지고, 되돌릴 수 없어요. 그동안 멤버는 글을 읽고 스크랩할 수 있지만 새로 쓸 수는 없어요."
                        )
                    }
            }
        } footer: {
            if capabilities.isPendingDeletion {
                Text("삭제 예정인 그룹이에요. 필요한 글은 삭제 전에 스크랩해 두세요.")
            }
        }
    }

    private func leaveTitle(_ summary: GroupSummary) -> String {
        switch GroupLeavePlan(group: summary) {
        case .adminChoosesSuccessor: String(localized: "관리자를 누구에게 맡길까요?")
        case .lastMember: String(localized: "마지막 멤버예요. 나갈까요?")
        case .leave: String(localized: "그룹에서 나갈까요?")
        }
    }

    private func leaveMessage(_ summary: GroupSummary) -> String {
        switch GroupLeavePlan(group: summary) {
        case .adminChoosesSuccessor:
            String(localized: "직접 넘기면 바로 새 관리자가 정해져요. 투표로 정하면 남은 멤버가 3일 동안 투표하고, 그동안 관리자 기능은 쉬어요.")
        case .lastMember:
            String(localized: "나가면 그룹이 바로 지워져요. 내가 올린 글도 함께 사라져요.")
        case .leave:
            String(localized: "내가 올린 글과 댓글은 남아요. 다시 들어오려면 새 초대가 필요해요.")
        }
    }

    @ViewBuilder
    private func leaveActions(_ summary: GroupSummary) -> some View {
        switch GroupLeavePlan(group: summary) {
        case .adminChoosesSuccessor:
            Button("멤버에게 직접 넘기기") { isPickingSuccessor = true }
            Button("나가고 투표로 정하기", role: .destructive) { leave() }
        case .lastMember:
            Button("나가고 그룹 지우기", role: .destructive) { leave() }
        case .leave:
            Button("나가기", role: .destructive) { leave() }
        }
        Button("취소", role: .cancel) {}
    }

    private func leave() {
        Task {
            if await model.leave() { left() }
        }
    }

    private func left() {
        if appModel.selectedGroupID == model.groupID {
            appModel.selectKind(nil)
        }
        dismiss()
    }
}

/// Members, with the admin's remove (= ban) and hand-over actions and the ban list.
struct GroupMembersView: View {
    @ObservedObject var model: GroupSettingsModel
    @State private var pendingRemoval: MemberResponse?
    @State private var pendingTransfer: MemberResponse?

    var body: some View {
        let capabilities = model.capabilities
        Form {
            Section {
                ForEach(model.members, id: \.user.id) { member in
                    memberRow(member, capabilities: capabilities)
                }
                if model.hasMoreMembers {
                    Button("더 보기") { Task { await model.loadMoreMembers() } }
                }
            } header: {
                Text("멤버")
            }

            if capabilities?.canManageBans == true, !model.bans.isEmpty {
                Section {
                    ForEach(model.bans, id: \.user.id) { ban in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(ban.user.displayName)
                                    .foregroundStyle(JournalTheme.ink)
                                Text("\(GroupDateText.day(ban.bannedAt)) 강퇴")
                                    .font(.caption)
                                    .foregroundStyle(JournalTheme.inkSecondary)
                            }
                            Spacer()
                            Button("강퇴 해제") { Task { await model.unban(ban) } }
                                .buttonStyle(.borderless)
                                .disabled(model.isWorking)
                        }
                    }
                } header: {
                    Text("강퇴한 사람")
                } footer: {
                    Text("강퇴를 풀어도 바로 돌아오지는 않아요. 새 초대로 다시 참여할 수 있게 될 뿐이에요.")
                }
            }

            if let message = model.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle("멤버")
        .confirmationDialog(
            "멤버를 강퇴할까요?",
            isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { member in
            Button("\(member.user.displayName)님 강퇴", role: .destructive) {
                Task { await model.remove(member) }
            }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("강퇴한 사람은 강퇴를 풀기 전까지 어떤 초대로도 다시 들어올 수 없어요. 그 사람이 올린 글과 댓글은 남아요.")
        }
        .confirmationDialog(
            "관리자를 넘길까요?",
            isPresented: Binding(
                get: { pendingTransfer != nil }, set: { if !$0 { pendingTransfer = nil } }),
            titleVisibility: .visible,
            presenting: pendingTransfer
        ) { member in
            Button("\(member.user.displayName)님에게 넘기기") {
                Task { await model.transferAdmin(to: member) }
            }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("넘기면 나는 일반 멤버가 되고, 초대·강퇴·삭제는 새 관리자만 할 수 있어요.")
        }
    }

    @ViewBuilder
    private func memberRow(_ member: MemberResponse, capabilities: GroupAdminCapabilities?)
        -> some View
    {
        let isMe = model.isMe(member.user)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.user.displayName)
                        .foregroundStyle(JournalTheme.ink)
                    if isMe {
                        Text("나")
                            .font(.caption)
                            .foregroundStyle(JournalTheme.inkSecondary)
                    }
                }
                Text("\(GroupDateText.day(member.joinedAt)) 참여")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }
            Spacer()
            if member.isAdmin {
                Text("관리자")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JournalTheme.brandPrimary)
            }
            if !isMe,
                capabilities?.canRemoveMembers == true || capabilities?.canTransferAdmin == true
            {
                Menu {
                    if capabilities?.canTransferAdmin == true {
                        Button {
                            pendingTransfer = member
                        } label: {
                            Label("관리자 넘기기", systemImage: "crown")
                        }
                    }
                    if capabilities?.canRemoveMembers == true {
                        Button(role: .destructive) {
                            pendingRemoval = member
                        } label: {
                            Label("강퇴", systemImage: "person.fill.xmark")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("\(member.user.displayName) 관리")
                .disabled(model.isWorking)
            }
        }
    }
}

/// "멤버에게 직접 넘기기": pick the next admin, then leave as an ordinary member.
private struct GroupSuccessorPicker: View {
    @ObservedObject var model: GroupSettingsModel
    var onLeft: () -> Void
    @State private var pending: MemberResponse?

    var body: some View {
        Form {
            Section {
                ForEach(model.otherMembers, id: \.user.id) { member in
                    Button(member.user.displayName) { pending = member }
                        .disabled(model.isWorking)
                }
            } footer: {
                Text("고른 멤버가 바로 관리자가 되고, 나는 그룹에서 나가요.")
            }
            if let message = model.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle("새 관리자 고르기")
        .confirmationDialog(
            "관리자를 넘기고 나갈까요?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { member in
            Button("\(member.user.displayName)님에게 넘기고 나가기", role: .destructive) {
                Task {
                    if await model.transferAndLeave(to: member) { onLeft() }
                }
            }
            Button("취소", role: .cancel) {}
        }
    }
}
