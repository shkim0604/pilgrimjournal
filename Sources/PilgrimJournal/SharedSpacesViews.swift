#if PILGRIM_SWIFTDATA
import JournalDomain
import SwiftUI

/// The window-level parts of sharing: the system invitation sheet, and pulling changes
/// every few seconds while a shared notebook is on screen, since CloudKit pushes can be
/// late or coalesced.
struct SharedSpacesContentModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel

    func body(content: Content) -> some View {
        content
            .sharedSpaceInvitationSheet(model.familySharing)
            .task(id: model.selectedSharedSpaceID) {
                guard model.selectedSharedSpaceID != nil else { return }
                while !Task.isCancelled {
                    await model.familySharing?.fetchNow()
                    try? await Task.sleep(for: .seconds(8))
                }
            }
    }
}

/// The sidebar's 공유됨 section: notebooks and single notes this user shared or joined.
struct SharedSpacesSidebarSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var sharing: FamilySharingController
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @State private var pendingStop: SharedSpaceRecord?
    @State private var pendingLeave: SharedSpaceRecord?

    var body: some View {
        if !sharing.spaces.isEmpty {
            Section("공유됨") {
                ForEach(sharing.spaces) { space in
                    JournalSidebarItem(
                        title: Self.title(of: space),
                        systemImage: space.scope == .notebook ? "person.2" : "doc.text",
                        accent: JournalTheme.brandPrimary,
                        isSelected: model.selectedSharedSpaceID == space.id
                    ) {
                        model.selectSharedSpace(space.id)
                        #if os(iOS)
                        model.selectEntry(nil)
                        #endif
                        preferredCompactColumn = .content
                    }
                    .contextMenu { menu(for: space) }
                }
            }
            .confirmationDialog(
                "공유를 끝낼까요?",
                isPresented: Binding(
                    get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
                titleVisibility: .visible,
                presenting: pendingStop
            ) { space in
                Button("공유 끝내기", role: .destructive) {
                    Task { await model.stopSharing(space.id) }
                }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("기록은 내 기록장으로 돌아오고, 초대한 사람들의 화면에서는 사라집니다.")
            }
            .confirmationDialog(
                "공유에서 나갈까요?",
                isPresented: Binding(
                    get: { pendingLeave != nil }, set: { if !$0 { pendingLeave = nil } }),
                titleVisibility: .visible,
                presenting: pendingLeave
            ) { space in
                Button("내 기록장에 복사하고 나가기") {
                    Task { await model.leaveSharedSpace(space.id, keepingCopy: true) }
                }
                Button("나가기", role: .destructive) {
                    Task { await model.leaveSharedSpace(space.id, keepingCopy: false) }
                }
                Button("취소", role: .cancel) {}
            } message: { _ in
                Text("나가면 이 기기와 내 iCloud에서 공유 기록이 사라집니다. 공유한 사람의 기록은 그대로입니다.")
            }
        }
    }

    @ViewBuilder
    private func menu(for space: SharedSpaceRecord) -> some View {
        if space.role == .owner {
            Button {
                Task { await model.manageSharing(of: space.id) }
            } label: {
                Label("참여자 관리", systemImage: "person.crop.circle.badge.plus")
            }
            Button("공유 끝내기…", role: .destructive) { pendingStop = space }
        } else {
            Button("나가기…", role: .destructive) { pendingLeave = space }
        }
    }

    static func title(of space: SharedSpaceRecord) -> String {
        let name = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "공유 노트북") : name
    }
}
#endif
