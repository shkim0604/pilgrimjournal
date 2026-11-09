import JournalDomain
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct JournalSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @State private var isCreatingNotebook = false
    @State private var newNotebookName = ""
    @State private var notebookPendingDeletion: String?
    @State private var notebookPendingShare: String?

    var body: some View {
        List {
            Section {
                JournalSidebarItem(
                    title: String(localized: "전체 기록"),
                    systemImage: "books.vertical",
                    accent: JournalTheme.brandPrimary,
                    isSelected: model.selectedKind == nil
                        && model.selectedNotebookName == nil
                        && model.selectedSharedSpaceID == nil
                ) {
                    selectKind(nil)
                }

            }

            Section("유형") {
                ForEach(model.sidebarKinds, id: \.kind) { definition in
                    JournalSidebarItem(
                        title: definition.displayName,
                        systemImage: KindIconCatalog.displaySymbol(
                            for: definition.iconToken
                        ),
                        accent: JournalTheme.categoryColor(for: definition),
                        isSelected: model.selectedKind == definition.kind
                            && model.selectedNotebookName == nil
                    ) {
                        selectKind(definition.kind)
                    }
                }
            }

            Section(
                String(
                    localized: "sidebar.notebooks", defaultValue: "노트북",
                    comment: "Sidebar section header listing notebooks")
            ) {
                ForEach(model.notebooks, id: \.self) { notebook in
                    JournalSidebarItem(
                        title: notebook,
                        systemImage: "book.closed",
                        accent: JournalTheme.brandPrimary,
                        isSelected: model.selectedNotebookName == notebook
                    ) {
                        selectNotebook(notebook)
                    }
                    .contextMenu {
                        if model.canShare {
                            Button {
                                notebookPendingShare = notebook
                            } label: {
                                Label("공유…", systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                        Button("노트북 삭제", role: .destructive) {
                            notebookPendingDeletion = notebook
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("삭제", role: .destructive) {
                            notebookPendingDeletion = notebook
                        }
                    }
                }
                Button {
                    newNotebookName = ""
                    isCreatingNotebook = true
                } label: {
                    Label("노트북 추가", systemImage: "plus.circle")
                        .foregroundStyle(JournalTheme.brandPrimary)
                }
                .buttonStyle(.plain)
            }

            #if PILGRIM_SWIFTDATA
            if let sharing = model.familySharing {
                SharedSpacesSidebarSection(
                    sharing: sharing,
                    preferredCompactColumn: $preferredCompactColumn
                )
            }
            #endif

            Section {
                JournalSidebarItem(
                    title: String(localized: "설정"),
                    systemImage: "gearshape",
                    accent: JournalTheme.inkSecondary,
                    isSelected: false
                ) {
                    openSettings()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(JournalTheme.surfaceMuted)
        .alert("새 노트북", isPresented: $isCreatingNotebook) {
            TextField("노트북 이름", text: $newNotebookName)
            Button("취소", role: .cancel) {}
            Button("추가") { addNotebook() }
        } message: {
            Text("기록을 모아 볼 노트북 이름을 입력하세요.")
        }
        .confirmationDialog(
            "노트북을 삭제할까요?",
            isPresented: Binding(
                get: { notebookPendingDeletion != nil },
                set: { if !$0 { notebookPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("노트북 삭제", role: .destructive) {
                if let notebookPendingDeletion {
                    _ = model.deleteNotebook(named: notebookPendingDeletion)
                }
                notebookPendingDeletion = nil
            }
            Button("취소", role: .cancel) {
                notebookPendingDeletion = nil
            }
        } message: {
            Text("문서는 삭제하지 않고 ‘노트북 없음’으로 이동합니다.")
        }
        .confirmationDialog(
            "노트북을 공유할까요?",
            isPresented: Binding(
                get: { notebookPendingShare != nil },
                set: { if !$0 { notebookPendingShare = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("공유하고 초대하기") {
                if let notebook = notebookPendingShare {
                    Task { await model.shareNotebook(named: notebook) }
                }
                notebookPendingShare = nil
            }
            Button("취소", role: .cancel) {
                notebookPendingShare = nil
            }
        } message: {
            Text("노트북의 기록이 ‘공유됨’으로 옮겨집니다. 초대한 사람은 함께 보고 고칠 수 있고, 공유를 끝내면 다시 내 노트북으로 돌아옵니다.")
        }
        .navigationTitle("Pilgrim Journal")
        #if os(iOS)
        // 접근성 글자 크기에서 large title은 줄바꿈 없이 잘리므로 inline으로 낮춘다.
        .navigationBarTitleDisplayMode(
            dynamicTypeSize.isAccessibilitySize ? .inline : .large
        )
        #endif
        .navigationSplitViewColumnWidth(
            min: JournalTheme.sidebarWidth.lowerBound,
            ideal: 240,
            max: JournalTheme.sidebarWidth.upperBound
        )
    }

    private func selectKind(_ kind: JournalKind?) {
        model.selectKind(kind)
        #if os(iOS)
        model.selectEntry(nil)
        #endif
        preferredCompactColumn = .content
    }

    private func selectNotebook(_ notebook: String) {
        model.selectNotebook(notebook)
        #if os(iOS)
        model.selectEntry(nil)
        #endif
        preferredCompactColumn = .content
    }

    private func addNotebook() {
        guard let created = model.createNotebook(named: newNotebookName) else {
            return
        }
        selectNotebook(created)
    }

    private func openSettings() {
        model.showSettings()
        preferredCompactColumn = .detail
    }
}

struct NewEntryListButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("새 노트", systemImage: "square.and.pencil")
                .font(.headline)
                .foregroundStyle(JournalTheme.brandPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("빈 노트를 오른쪽 편집기에 엽니다.")
    }
}
