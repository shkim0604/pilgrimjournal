import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// "새 그룹": a name (1–40 characters) and the group exists with me as its admin. A failed
/// create keeps the name and retries with the same `clientId`, so a lost response never makes
/// two groups.
struct GroupCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var groups: GroupsController
    /// Called with the new group's ID after it is created.
    var onCreated: (UUID) -> Void

    @State private var name = ""
    @State private var clientID = UUID()
    @State private var isSaving = false
    @State private var message: String?

    private var canCreate: Bool { GroupNameRules.isValidGroupName(name) && !isSaving }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("예: 수요 기도모임", text: $name)
                        .onSubmit(create)
                    Text(
                        "\(GroupNameRules.normalized(name).count)/\(APILimits.groupName.upperBound)"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        GroupNameRules.normalized(name).count > APILimits.groupName.upperBound
                            ? .red : JournalTheme.inkSecondary)
                } header: {
                    Text("그룹 이름")
                } footer: {
                    Text("만든 사람이 관리자가 돼요. 그룹을 만든 뒤 초대 링크나 QR 코드로 멤버를 부를 수 있어요.")
                }

                if let message {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(JournalTheme.canvas)
            .navigationTitle("새 그룹")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("만들기", action: create)
                            .disabled(!canCreate)
                    }
                }
            }
            .onChange(of: name) { _, _ in message = nil }
        }
        .frame(minWidth: 380, minHeight: 280)
    }

    private func create() {
        guard canCreate else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                let detail = try await groups.createGroup(named: name, clientID: clientID)
                onCreated(detail.id)
                dismiss()
            } catch {
                let error = GroupsController.normalize(error)
                if error.code == .subscriptionRequired {
                    groups.requestSubscription()
                    return
                }
                message = GroupMessages.text(for: error)
            }
        }
    }
}
