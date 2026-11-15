import JournalData
import SwiftUI

enum AccountDeletionGuidance {
    /// Where the user stops using Sign in with Apple for this app. Without a
    /// server the app cannot revoke the Apple token itself (see
    /// docs/privacy.md), so every deletion screen points here.
    static var unlinkPath: String {
        String(localized: "설정 › Apple 계정 › Apple로 로그인 › Pilgrim › 사용 중단")
    }
}

/// Settings › Apple 로그인 › 계정 삭제. Says what goes, warns about other
/// devices, then asks once more before deleting.
struct AccountDeletionView: View {
    @EnvironmentObject private var authentication: AppleAuthenticationCoordinator
    @EnvironmentObject private var journalSession: JournalSessionController
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirming = false

    var body: some View {
        Form {
            Section {
                Label("iCloud에 저장된 모든 기록과 첨부", systemImage: "icloud")
                Label("내가 공유한 노트북과 기록(함께 보던 가족에게서도 사라짐)과 참여 중인 공유", systemImage: "person.2")
                Label("이 기기의 기록, 첨부, 검색 인덱스와 기기별 설정", systemImage: "internaldrive")
                Label("이 기기에 저장된 Apple 로그인 정보와 앱 잠금 설정", systemImage: "key")
            } header: {
                Text("삭제되는 항목")
            } footer: {
                Text("삭제한 기록과 첨부는 되돌릴 수 없습니다.")
            }

            // Only while groups are on: `AppModel.groups` is nil otherwise.
            if let groups = journalSession.appModel?.groups {
                GroupAccountDeletionSection(groups: groups)
            }

            Section("삭제 전에 확인하세요") {
                #if os(macOS)
                Label("필요하면 먼저 전체 백업을 내보내세요", systemImage: "externaldrive")
                    .font(.headline)
                Text("설정 › 백업 및 복원 › 전체 백업 내보내기…로 백업 파일을 만들어 두면 나중에 다시 복원할 수 있습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                #endif
                Label("다른 기기에서 먼저 앱을 삭제하세요", systemImage: "laptopcomputer.and.iphone")
                    .font(.headline)
                Text(
                    "다른 iPhone이나 Mac에서도 Pilgrim을 쓰고 있다면 그 기기에서 먼저 앱을 삭제하세요. 그대로 두면 그 기기에 남은 기록이 iCloud에 다시 올라갈 수 있습니다."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                if isUsingLocalOnlyStorage {
                    Label("지금은 iCloud에 연결되어 있지 않습니다", systemImage: "icloud.slash")
                        .font(.headline)
                    Text("이 기기의 데이터만 삭제됩니다. iCloud에 저장된 기록까지 지우려면 기기에서 iCloud에 로그인한 뒤 다시 삭제하세요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Apple 로그인 연결 해제") {
                Text(
                    "Pilgrim에는 자체 서버가 없어 Apple 로그인 연결은 기기 설정에서 끊습니다. 삭제가 끝나면 다음 경로에서 ‘사용 중단’을 누르세요."
                )
                .font(.callout)
                Text(AccountDeletionGuidance.unlinkPath)
                    .font(.callout.weight(.semibold))
                    .textSelection(.enabled)
            }

            Section {
                Button(role: .destructive) {
                    isConfirming = true
                } label: {
                    Label("계정 삭제", systemImage: "trash")
                }
                .disabled(authentication.isDeletingAccount)
                // iOS 26 shows the confirmation as a popover without its own
                // cancel button, so this screen keeps one of its own.
                Button("취소") { dismiss() }
                    .disabled(authentication.isDeletingAccount)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle("계정 삭제")
        .task {
            if let groups = journalSession.appModel?.groups {
                await GroupAccountDeletionSection.load(groups)
            }
        }
        .confirmationDialog(
            "계정과 모든 데이터를 삭제할까요?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("계정 삭제", role: .destructive) {
                Task { await authentication.deleteAccount(using: journalSession) }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("iCloud와 이 기기의 기록이 모두 삭제되며 되돌릴 수 없습니다.")
        }
    }

    /// A pending local-to-iCloud migration also opens the local scope, but
    /// iCloud is reachable then and the cloud step still runs.
    private var isUsingLocalOnlyStorage: Bool {
        journalSession.activeScope?.storageLocation == .localOnly
            && journalSession.pendingMigration == nil
    }
}

/// The group part of the deletion screen: the group-server account goes first, groups I run
/// move to a member vote, and an App Store subscription is not cancelled for the user.
/// Hidden until a group profile is loaded (never signed in, or the server is unreachable).
private struct GroupAccountDeletionSection: View {
    @ObservedObject var groups: GroupsController

    var body: some View {
        let notice = GroupAccountDeletionNotice(me: groups.me, groups: groups.groups)
        if notice.hasGroupAccount {
            Section {
                Label("그룹 서버의 내 계정과 내가 올린 글, 댓글, 반응, 스티커, 사진", systemImage: "person.3")
                if notice.adminGroupCount > 0 {
                    Label(
                        "내가 관리하는 그룹 \(notice.adminGroupCount)개는 멤버 투표로 다음 관리자를 정해요",
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    Text("남은 멤버가 한 명이면 그 사람이 바로 관리자가 되고, 아무도 없으면 그룹이 삭제돼요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if notice.hasAppStoreSubscription {
                    Label("구독은 App Store 설정에서 직접 해지해야 해요", systemImage: "creditcard")
                    Text("계정을 삭제해도 App Store 구독은 자동으로 해지되지 않아요.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Link(
                        "App Store 구독 관리 열기",
                        destination: GroupAccountDeletionNotice.manageSubscriptionsURL)
                }
            } header: {
                Text("그룹")
            } footer: {
                Text("그룹 서버의 계정을 가장 먼저 지웁니다. 그룹 로그인이 만료됐다면 Apple 인증을 한 번 더 요청해요.")
            }
        }
    }

    /// Fresh counts: the sidebar may not have loaded the groups this launch.
    static func load(_ groups: GroupsController) async {
        await groups.loadAccount()
        if groups.accountState.hasGroupAccess {
            await groups.refresh()
        }
    }
}

/// Covers the whole window while an account deletion runs or after it
/// failed. The settings screen is gone by then: the journal closes before
/// anything is deleted.
struct AccountDeletionStatusView: View {
    let phase: AppleAuthenticationCoordinator.AccountDeletionPhase
    let retry: () -> Void
    let returnToJournal: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch phase {
            case .idle:
                EmptyView()
            case .deleting:
                ProgressView()
                    .controlSize(.large)
                Text("계정을 삭제하는 중")
                    .font(.headline)
                    .foregroundStyle(JournalTheme.ink)
                Text("iCloud와 이 기기의 기록을 지우고 있습니다. 끝날 때까지 앱을 닫지 마세요.")
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .multilineTextAlignment(.center)
            case let .failed(message, canReturnToJournal):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("계정을 삭제하지 못했습니다")
                    .font(.headline)
                    .foregroundStyle(JournalTheme.ink)
                Text(message)
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("다시 시도", action: retry)
                    .buttonStyle(.borderedProminent)
                if canReturnToJournal {
                    Button("기록으로 돌아가기", action: returnToJournal)
                } else {
                    Text("iCloud의 기록은 이미 삭제되었습니다. 이 기기에 남은 데이터를 지워야 계속할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: 440)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JournalTheme.canvas)
    }
}

/// Shown on the sign-in screen right after a deletion.
struct AccountDeletionCompletedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("계정과 데이터가 삭제되었습니다", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(JournalTheme.brandPrimary)
            Text("Apple 로그인 연결도 끊으려면 다음 경로에서 ‘사용 중단’을 누르세요.")
                .font(.callout)
                .foregroundStyle(JournalTheme.inkSecondary)
            Text(AccountDeletionGuidance.unlinkPath)
                .font(.callout.weight(.semibold))
                .foregroundStyle(JournalTheme.ink)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 440, alignment: .leading)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
