import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// Joining a group: a code from an invite link or QR code (`PendingGroupInvite`), or typed in
/// ("초대 코드로 참여", for macOS and testing). The preview shows the group's name, size and
/// who invited before anything is joined. Each refusal (expired, revoked, full, voting,
/// pending deletion, removed) has its own words.
struct GroupJoinSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GroupJoinModel
    @FocusState private var isCodeFocused: Bool
    /// Called with the group's ID once the user is a member.
    var onJoined: (UUID) -> Void

    init(groups: GroupsController, request: GroupJoinRequest, onJoined: @escaping (UUID) -> Void) {
        _model = StateObject(wrappedValue: GroupJoinModel(groups: groups, code: request.code))
        self.onJoined = onJoined
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("XXXX-XXXX-XXXX", text: $model.codeText)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        #if os(iOS)
                    .textInputAutocapitalization(.characters)
                        #endif
                        .focused($isCodeFocused)
                        .onSubmit { Task { await model.loadPreview() } }
                        .onChange(of: model.codeText) { _, _ in model.codeDidChange() }
                    Button("초대 확인하기") {
                        Task { await model.loadPreview() }
                    }
                    .disabled(model.code == nil || model.isWorking)
                } header: {
                    Text("초대 코드")
                } footer: {
                    Text("초대 링크 끝의 12자예요. 대소문자와 하이픈은 상관없어요.")
                }

                if let preview = model.preview {
                    previewSection(preview)
                }

                if model.isWorking {
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
                        if model.preview == nil, model.code != nil {
                            Button("다시 시도") { Task { await model.loadPreview() } }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(JournalTheme.canvas)
            .navigationTitle("그룹에 참여")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
            .task {
                if model.code != nil, model.preview == nil {
                    await model.loadPreview()
                } else if model.code == nil {
                    isCodeFocused = true
                }
            }
        }
        .frame(minWidth: 400, minHeight: 420)
    }

    @ViewBuilder
    private func previewSection(_ preview: InvitePreviewResponse) -> some View {
        Section {
            VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
                Text(preview.groupName)
                    .font(.title3.bold())
                    .foregroundStyle(JournalTheme.ink)
                Label("멤버 \(preview.memberCount)명", systemImage: "person.2")
                if let invitedBy = preview.invitedBy {
                    Label("\(invitedBy.displayName)님이 초대했어요", systemImage: "envelope.open")
                }
                Label(
                    "\(GroupDateText.dayAndTime(preview.expiresAt))까지 쓸 수 있는 초대예요",
                    systemImage: "clock")
            }
            .font(.callout)
            .foregroundStyle(JournalTheme.inkSecondary)
            .padding(.vertical, JournalTheme.Spacing.small)

            if preview.alreadyMember {
                Text("이미 참여한 그룹이에요.")
                    .foregroundStyle(JournalTheme.inkSecondary)
                Button("그룹 열기") { finish(preview.groupId) }
            } else {
                if preview.requiresSubscription {
                    Text("이 그룹에 참여하려면 구독이 필요해요.")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                Button {
                    Task {
                        if let groupID = await model.accept() { finish(groupID) }
                    }
                } label: {
                    Text("참여하기").fontWeight(.semibold)
                }
                .disabled(model.isWorking)
            }
        } header: {
            Text("초대받은 그룹")
        } footer: {
            Text("참여하면 이 그룹의 멤버가 내 이름과 프로필 사진, 내가 올린 글을 볼 수 있어요.")
        }
    }

    private func finish(_ groupID: UUID) {
        onJoined(groupID)
        dismiss()
    }
}
