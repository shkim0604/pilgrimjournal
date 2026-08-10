import JournalDomain
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var preferredCompactColumn: NavigationSplitViewColumn
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var isFocusMode = false
    @State private var isConfirmingBatchTrash = false
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif

    init() {
        #if DEBUG
        let visualScreen = ProcessInfo.processInfo.environment[
            "PILGRIM_VISUAL_TEST_SCREEN"
        ]
        let initialColumn: NavigationSplitViewColumn = switch visualScreen {
        case "timeline", "search-empty": .content
        case "detail": .detail
        default: .sidebar
        }
        _preferredCompactColumn = State(initialValue: initialColumn)
        #else
        _preferredCompactColumn = State(initialValue: .sidebar)
        #endif
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            JournalSidebar(preferredCompactColumn: $preferredCompactColumn)
        } content: {
            Group {
                if model.isBatchSelecting {
                    List(model.entries, selection: $model.selectedEntryIDs) { entry in
                        EntryRow(entry: entry)
                            .tag(entry.id)
                    }
                    #if os(macOS)
                    .onDeleteCommand {
                        requestBatchTrash()
                    }
                    #endif
                } else {
                    List(selection: entrySelection) {
                        NewEntryListButton {
                            model.beginNewEntry()
                        }

                        Section("노트") {
                            if model.entries.isEmpty,
                               !model.hasActiveSearchCriteria {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("아직 노트가 없습니다.")
                                        .font(.headline)
                                    Text("위의 ‘새 노트’를 눌러 바로 작성하세요.")
                                        .font(.caption)
                                        .foregroundStyle(JournalTheme.inkSecondary)
                                }
                                .padding(.vertical, 8)
                            } else {
                                ForEach(model.entries) { entry in
                                    EntryRowWithActions(entry: entry)
                                        .tag(entry.id)
                                }
                            }
                        }
                    }
                    #if os(macOS)
                    .onDeleteCommand {
                        guard let entry = model.selectedEntry else { return }
                        model.moveToTrash(entry)
                    }
                    #endif
                }
            }
            .overlay {
                if model.entries.isEmpty && model.hasActiveSearchCriteria {
                    JournalEmptyState(
                        title: "검색 결과가 없습니다",
                        description: "검색어나 필터를 바꾸거나 모든 조건을 지워보세요.",
                        systemImage: "magnifyingglass"
                    ) {
                        Button("검색 조건 지우기") {
                            model.clearSearchCriteria()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(JournalTheme.canvas)
            .searchable(text: $model.searchText, prompt: "기록 검색")
            .onSubmit(of: .search) { model.refresh() }
            .onChange(of: model.searchText) { _, _ in model.refresh() }
            .navigationTitle(
                model.selectedNotebookName
                    ?? model.selectedKind?.localizedName
                    ?? "전체 기록"
            )
            .toolbar {
                if model.isBatchSelecting {
                    Button("정리 \(model.selectedEntryIDs.count)") {
                        model.isPresentingBatchOrganizer = true
                    }
                    .disabled(model.selectedEntryIDs.isEmpty)
                    Button(role: .destructive) {
                        requestBatchTrash()
                    } label: {
                        Label(
                            "삭제 \(model.selectedEntryIDs.count)",
                            systemImage: "trash"
                        )
                    }
                    .disabled(model.selectedEntryIDs.isEmpty)
                    Button("완료") {
                        #if os(iOS)
                        editMode = .inactive
                        #endif
                        model.endBatchSelection()
                    }
                } else {
                    Button("선택") {
                        model.beginBatchSelection()
                        #if os(iOS)
                        editMode = .active
                        #endif
                    }
                }
                Button {
                    model.beginNewEntry()
                } label: {
                    Label("새 노트", systemImage: "square.and.pencil")
                }
                #if os(macOS)
                Button {
                    setFocusMode(!isFocusMode)
                } label: {
                    Label(
                        isFocusMode ? "집중 모드 종료" : "집중 모드",
                        systemImage: isFocusMode
                            ? "rectangle.split.3x1"
                            : "rectangle.inset.filled"
                    )
                }
                #endif
            }
            .navigationSplitViewColumnWidth(
                min: JournalTheme.timelineWidth.lowerBound,
                ideal: 330,
                max: JournalTheme.timelineWidth.upperBound
            )
        } detail: {
            #if os(macOS)
            if let entry = model.selectedEntry {
                InlineEntryEditorView(entry: entry)
                    .id(entry.id)
            } else if model.isPresentingEditor {
                InlineEntryEditorView(
                    entry: nil,
                    defaultKind: model.selectedKind?.canCreateManually == true
                        ? model.selectedKind!
                        : .diary,
                    defaultNotebookName: model.newEntryNotebookName
                )
                .id(model.editorSessionID)
            } else {
                SettingsView()
            }
            #else
            if let entry = model.selectedEntry {
                EntryDetailView(entry: entry)
            } else {
                SettingsView()
            }
            #endif
        }
        #if os(iOS)
        .environment(\.editMode, $editMode)
        #endif
        #if os(iOS)
        .fullScreenCover(isPresented: $model.isPresentingEditor) {
            EntryEditorView(
                entry: model.editingEntry,
                defaultKind: model.selectedKind?.canCreateManually == true
                    ? model.selectedKind!
                    : .diary,
                defaultNotebookName: model.newEntryNotebookName
            )
        }
        #endif
        .sheet(isPresented: $model.isPresentingTrash) {
            TrashView()
        }
        #if os(macOS)
        .onReceive(
            NotificationCenter.default.publisher(
                for: .toggleJournalFocusMode
            )
        ) { _ in
            setFocusMode(!isFocusMode)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .toggleJournalSidebar)
        ) { _ in
            toggleSidebar()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .focusJournalSearch)
        ) { _ in
            MacSearchFocus.focus()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .navigateToPreviousJournalEntry
            )
        ) { _ in
            selectAdjacentEntry(offset: -1)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .navigateToNextJournalEntry
            )
        ) { _ in
            selectAdjacentEntry(offset: 1)
        }
        #endif
        .sheet(isPresented: $model.isPresentingBatchOrganizer) {
            BatchOrganizerView()
        }
        .alert(
            "선택한 노트를 삭제할까요?",
            isPresented: $isConfirmingBatchTrash
        ) {
            Button("취소", role: .cancel) {}
            Button("휴지통으로 이동", role: .destructive) {
                if model.moveSelectedEntriesToTrash() {
                    #if os(iOS)
                    editMode = .inactive
                    #endif
                }
            }
        } message: {
            Text(
                "선택한 \(model.selectedEntryIDs.count)개의 노트를 "
                    + "휴지통으로 이동합니다."
            )
        }
        #if os(macOS)
        .sheet(isPresented: $model.isPresentingImporter) {
            DayOneImportView()
        }
        #endif
        .alert(
            "오류",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        #if os(macOS)
        .onExitCommand {
            if MacSearchFocus.isFocused {
                MacSearchFocus.clearFocus()
            } else if isFocusMode {
                setFocusMode(false)
            } else if model.selectedEntryID != nil || model.isPresentingEditor {
                model.showSettings()
            }
        }
        #endif
    }

    private var entrySelection: Binding<UUID?> {
        Binding(
            get: { model.selectedEntryID },
            set: { model.selectEntry($0) }
        )
    }

    private func requestBatchTrash() {
        guard !model.selectedEntryIDs.isEmpty else { return }
        isConfirmingBatchTrash = true
    }

    private func setFocusMode(_ enabled: Bool) {
        isFocusMode = enabled
        let targetVisibility: NavigationSplitViewVisibility = enabled
            ? .detailOnly
            : .all
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = targetVisibility
        }
        Task { @MainActor in
            await Task.yield()
            columnVisibility = targetVisibility
            #if os(macOS)
            MacNavigationSplitFocus.setCollapsed(enabled)
            #endif
        }
    }

    #if os(macOS)
    private func toggleSidebar() {
        if isFocusMode {
            setFocusMode(false)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = columnVisibility == .all ? .doubleColumn : .all
        }
    }

    private func selectAdjacentEntry(offset: Int) {
        guard !model.entries.isEmpty else { return }
        let currentIndex = model.selectedEntryID.flatMap { selectedID in
            model.entries.firstIndex { $0.id == selectedID }
        }
        let targetIndex: Int
        if let currentIndex {
            targetIndex = min(
                model.entries.count - 1,
                max(0, currentIndex + offset)
            )
        } else {
            targetIndex = offset < 0 ? model.entries.count - 1 : 0
        }
        model.selectEntry(model.entries[targetIndex].id)
    }
    #endif
}

#if os(macOS)
@MainActor
private enum MacNavigationSplitFocus {
    static func setCollapsed(_ collapsed: Bool) {
        guard let root = NSApp.keyWindow?.contentViewController else { return }
        let controllers = splitControllers(below: root)
        controllers.forEach { controller in
            guard controller.splitViewItems.count >= 2 else { return }
            for item in controller.splitViewItems.dropLast() {
                item.isCollapsed = collapsed
            }
        }
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let views = splitViews(below: contentView)
        views
            .filter {
                $0.isVertical
                    && $0.bounds.width > 500
                    && $0.bounds.height > 300
            }
            .forEach { splitView in
                for view in splitView.arrangedSubviews.dropLast() {
                    view.isHidden = collapsed
                }
                splitView.needsLayout = true
                splitView.layoutSubtreeIfNeeded()
            }
    }

    private static func splitControllers(
        below controller: NSViewController
    ) -> [NSSplitViewController] {
        let current = (controller as? NSSplitViewController).map { [$0] } ?? []
        return current + controller.children.flatMap(splitControllers(below:))
    }

    private static func splitViews(below view: NSView) -> [NSSplitView] {
        var matches = view.subviews.flatMap(splitViews(below:))
        if let splitView = view as? NSSplitView {
            matches.insert(splitView, at: 0)
        }
        return matches
    }
}

@MainActor
private enum MacSearchFocus {
    static var isFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }
        if responder is NSSearchField { return true }
        return (responder as? NSTextView)?.delegate is NSSearchField
    }

    static func focus() {
        guard let window = NSApp.keyWindow,
              let contentView = window.contentView,
              let searchField = firstSearchField(in: contentView)
        else { return }
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    static func clearFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField { return searchField }
        return view.subviews.lazy.compactMap(firstSearchField(in:)).first
    }
}

extension Notification.Name {
    static let toggleJournalFocusMode = Notification.Name(
        "PilgrimJournal.toggleFocusMode"
    )
    static let toggleJournalSidebar = Notification.Name(
        "PilgrimJournal.toggleSidebar"
    )
    static let focusJournalSearch = Notification.Name(
        "PilgrimJournal.focusSearch"
    )
    static let navigateToPreviousJournalEntry = Notification.Name(
        "PilgrimJournal.navigateToPreviousEntry"
    )
    static let navigateToNextJournalEntry = Notification.Name(
        "PilgrimJournal.navigateToNextEntry"
    )
    static let saveJournalEntry = Notification.Name(
        "PilgrimJournal.saveEntry"
    )
}
#endif

private struct JournalSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @State private var isCreatingNotebook = false
    @State private var newNotebookName = ""
    @State private var notebookPendingDeletion: String?

    var body: some View {
        List {
            Section {
                JournalSidebarItem(
                    title: "전체 기록",
                    systemImage: "books.vertical",
                    accent: JournalTheme.brandPrimary,
                    isSelected: model.selectedKind == nil
                        && model.selectedNotebookName == nil
                ) {
                    selectKind(nil)
                }

                ForEach(JournalKind.allCases) { kind in
                    JournalSidebarItem(
                        title: kind.localizedName,
                        systemImage: icon(for: kind),
                        accent: JournalTheme.categoryColor(for: kind),
                        isSelected: model.selectedKind == kind
                            && model.selectedNotebookName == nil
                    ) {
                        selectKind(kind)
                    }
                }
            }

            Section("노트북") {
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

            Section {
                JournalSidebarItem(
                    title: "설정",
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
        .navigationTitle("Pilgrim Journal")
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

    private func icon(for kind: JournalKind) -> String {
        switch kind {
        case .prayer: "hands.sparkles"
        case .bibleStudy: "book.closed"
        case .reading: "books.vertical"
        case .diary: "pencil.and.scribble"
        case .memo: "note.text"
        case .unclassified: "tray"
        }
    }
}

private struct NewEntryListButton: View {
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

private struct EntryRow: View {
    let entry: JournalEntryRecord

    var body: some View {
        HStack(spacing: JournalTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(JournalTheme.categoryColor(for: entry.kind))
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(EntryListSummaryFormatter.title(
                        explicitTitle: entry.title,
                        body: entry.body,
                        fallback: entry.kind.localizedName
                    ))
                        .font(.headline)
                        .foregroundStyle(JournalTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(JournalTheme.inkSecondary)
                            .accessibilityLabel("고정됨")
                    }
                    if entry.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(JournalTheme.accentWarm)
                            .accessibilityLabel("즐겨찾기")
                    }
                }

                let summary = EntryListSummaryFormatter.summary(from: entry.body)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }

                HStack(spacing: JournalTheme.Spacing.small) {
                    Text(entry.occurredAt, style: .date)
                    if let notebook = entry.notebookName {
                        Text("•")
                            .accessibilityHidden(true)
                        Label(notebook, systemImage: "book.closed")
                    }
                }
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
            }
        }
        .padding(.vertical, JournalTheme.Spacing.small)
        .accessibilityElement(children: .combine)
    }
}

private struct EntryRowWithActions: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntryRecord

    var body: some View {
        EntryRow(entry: entry)
            .contextMenu {
                Button("편집") { edit() }
                Button("휴지통으로 이동", role: .destructive) {
                    model.moveToTrash(entry)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    model.moveToTrash(entry)
                } label: {
                    Label("삭제", systemImage: "trash")
                }
            }
    }

    private func edit() {
        #if os(macOS)
        model.selectEntry(entry.id)
        #else
        model.beginEditing(entry)
        #endif
    }
}
