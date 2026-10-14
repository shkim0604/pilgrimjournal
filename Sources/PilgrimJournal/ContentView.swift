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
        let initialColumn: NavigationSplitViewColumn =
            switch visualScreen {
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
                #if os(macOS)
            // While focused, the system panel toggle would only fight
            // `FocusModeLayoutPolicy`; the toolbar's own "집중 모드 종료"
            // button is the way out.
            .toolbar(removing: isFocusMode ? .sidebarToggle : nil)
                #endif
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
                    // macOS binds the whole selection set even outside batch
                    // mode so shift- and command-click stay in sync with the
                    // model. iOS keeps the single-id binding: a set binding
                    // there swallows taps unless edit mode is active.
                    #if os(macOS)
                    List(selection: multipleEntrySelection) {
                        entryListContent
                    }
                    .onDeleteCommand {
                        requestBatchTrash()
                    }
                    #else
                    List(selection: entrySelection) {
                        entryListContent
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
                } else if model.entries.isEmpty && !model.isBatchSelecting {
                    JournalEmptyState(
                        title: "아직 노트가 없습니다",
                        description: "위의 ‘새 노트’를 눌러 바로 작성하세요.",
                        systemImage: "square.and.pencil"
                    ) {}
                    // The list still owns the 새 노트 button underneath.
                    .allowsHitTesting(false)
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
                    #if os(macOS)
                    // Shift-click already selects a range here, so the trash
                    // has to work without entering batch mode.
                    Button(role: .destructive) {
                        requestBatchTrash()
                    } label: {
                        Label(
                            model.selectedEntryIDs.count > 1
                                ? "삭제 \(model.selectedEntryIDs.count)"
                                : "삭제",
                            systemImage: "trash"
                        )
                    }
                    .disabled(model.selectedEntryIDs.isEmpty)
                    #endif
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
            Group {
                if model.isPresentingSettings {
                    SettingsView()
                } else if let entry = model.selectedEntry {
                    InlineEntryEditorView(entry: entry)
                        .id(entry.id)
                } else if model.selectedEntryIDs.count > 1 {
                    JournalEmptyState(
                        title: "\(model.selectedEntryIDs.count)개의 노트를 선택했습니다",
                        description: "도구 막대의 휴지통으로 한 번에 삭제하거나, "
                            + "‘선택’ → ‘정리’로 유형과 태그를 바꿀 수 있습니다.",
                        systemImage: "checklist"
                    ) {}
                } else if model.isPresentingEditor {
                    InlineEntryEditorView(
                        entry: nil,
                        defaultKind: model.defaultKindForNewEntry,
                        defaultNotebookName: model.newEntryNotebookName
                    )
                    .id(model.editorSessionID)
                } else {
                    JournalEmptyState(
                        title: "기록을 선택하세요",
                        description: "왼쪽 목록에서 기록을 고르거나 새 기록을 시작하세요.",
                        systemImage: "doc.text"
                    ) {}
                }
            }
            .navigationSplitViewColumnWidth(min: JournalTheme.detailMinWidth, ideal: 560)
            #else
            // Settings is only shown when it was actually asked for. Using it
            // as the "nothing selected" fallback meant any moment where the
            // selection could not be resolved bounced the user into settings.
            if model.isPresentingSettings {
                SettingsView()
            } else if let entry = model.selectedEntry {
                EntryDetailView(entry: entry)
            } else {
                JournalEmptyState(
                    title: "기록을 선택하세요",
                    description: "왼쪽 목록에서 기록을 고르면 여기에 내용이 보입니다.",
                    systemImage: "doc.text"
                ) {}
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
                defaultKind: model.defaultKindForNewEntry,
                defaultNotebookName: model.newEntryNotebookName
            )
        }
        #endif
        .sheet(isPresented: $model.isPresentingTrash) {
            TrashView()
        }
        #if os(macOS)
        // Swapping the detail column's content (switching entries, a new
        // note's autosave) makes SwiftUI write its own idea of the layout back
        // into `columnVisibility`. Treating that as "the user reopened the
        // panels" is what made focus mode drop out while typing. Focus mode
        // owns the layout instead: undo any write-back, and leave ending it to
        // explicit commands (toolbar button, ⌘⇧F, ⌃⌘S, Escape). With
        // `.doubleColumn` (see `FocusModeLayoutPolicy`) SwiftUI no longer
        // writes back at all; this is the safety net if a later macOS does.
        .onChange(of: columnVisibility) { _, newValue in
            guard
                FocusModeLayoutPolicy.shouldReassert(
                    isFocusMode: isFocusMode,
                    visibility: newValue
                )
            else { return }
            DispatchQueue.main.async {
                guard isFocusMode else { return }
                applyFocusLayout(animated: false)
            }
        }
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
        // Anchored here rather than in settings: the settings form scrolls and
        // can be dismissed, and a backup that finishes with no visible result
        // reads as a backup that did not happen.
        .alert(
            item: $model.lastOperationOutcome
        ) { outcome in
            Alert(
                title: Text(outcome.title),
                message: Text(outcome.message),
                dismissButton: .default(Text("확인"))
            )
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

    @ViewBuilder
    private var entryListContent: some View {
        NewEntryListButton {
            model.beginNewEntry()
        }

        // The section always renders the same ForEach. Swapping it for a
        // placeholder view when the last entry goes away changes the list
        // structure mid swipe-to-delete, which trips UIKit's row-count check
        // and crashes.
        Section("노트") {
            ForEach(model.entries) { entry in
                EntryRowWithActions(entry: entry)
                    .tag(entry.id)
            }
        }
    }

    private var entrySelection: Binding<UUID?> {
        Binding(
            get: { model.selectedEntryID },
            set: { model.selectEntry($0) }
        )
    }

    private var multipleEntrySelection: Binding<Set<UUID>> {
        Binding(
            get: { model.selectedEntryIDs },
            set: { model.selectEntries($0) }
        )
    }

    private func requestBatchTrash() {
        guard !model.selectedEntryIDs.isEmpty else { return }
        isConfirmingBatchTrash = true
    }

    private func setFocusMode(_ enabled: Bool) {
        isFocusMode = enabled
        applyFocusLayout(animated: true)
    }

    private func applyFocusLayout(animated: Bool) {
        let targetVisibility = FocusModeLayoutPolicy.visibility(
            isFocusMode: isFocusMode
        )
        if animated {
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = targetVisibility
            }
        } else {
            columnVisibility = targetVisibility
        }
        #if os(macOS)
        let hidesTimeline = isFocusMode
        // Dispatched (not `Task.yield()`) so this runs strictly after the
        // current SwiftUI update cycle's own AppKit layout pass finishes,
        // rather than after just one Swift concurrency suspension point —
        // MacNavigationSplitFocus mutates the same view hierarchy SwiftUI is
        // still settling.
        DispatchQueue.main.async {
            MacNavigationSplitFocus.setTimelineHidden(hidesTimeline)
        }
        #endif
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

/// The split view layout focus mode keeps on macOS.
///
/// A three-column `NavigationSplitView` on macOS ignores `.detailOnly`, but
/// honours `.doubleColumn`. So focus mode lets SwiftUI collapse the sidebar
/// with `.doubleColumn` — SwiftUI then knows the true layout and has nothing
/// to "correct" — and only the timeline column is hidden behind its back
/// (`MacNavigationSplitFocus`). While focused, any other visibility is a
/// SwiftUI write-back to undo, not a request to leave focus mode.
enum FocusModeLayoutPolicy {
    static func visibility(isFocusMode: Bool) -> NavigationSplitViewVisibility {
        isFocusMode ? .doubleColumn : .all
    }

    static func shouldReassert(
        isFocusMode: Bool,
        visibility: NavigationSplitViewVisibility
    ) -> Bool {
        isFocusMode && visibility != Self.visibility(isFocusMode: true)
    }
}

#if os(macOS)
@MainActor
private enum MacNavigationSplitFocus {
    /// Hides the middle (timeline) column of the journal's split view.
    ///
    /// SwiftUI cannot hide that column itself on macOS (see
    /// `FocusModeLayoutPolicy`), and it never re-shows it on its own, so a
    /// plain `isHidden` on the arranged subview holds across detail swaps.
    /// Because it mutates AppKit's split view hierarchy directly and outside
    /// SwiftUI's diffing, it must never touch a view that isn't actually
    /// still attached to the key window — SwiftUI can swap the whole detail
    /// column's content (e.g. a fresh `InlineEntryEditorView` from a
    /// new-entry action) around the same moment this runs, and mutating a
    /// torn-down hierarchy is exactly the kind of thing that produces a
    /// hard-to-reproduce AppKit crash.
    static func setTimelineHidden(_ hidden: Bool) {
        guard let keyWindow = NSApp.keyWindow,
            let contentView = keyWindow.contentView
        else { return }
        splitViews(below: contentView)
            .filter {
                $0.window === keyWindow
                    && $0.isVertical
                    && $0.arrangedSubviews.count == 3
            }
            .forEach { splitView in
                let timeline = splitView.arrangedSubviews[1]
                guard timeline.window === keyWindow,
                    timeline.isHidden != hidden
                else { return }
                timeline.isHidden = hidden
                splitView.needsLayout = true
                splitView.layoutSubtreeIfNeeded()
            }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
                    Text(
                        EntryListSummaryFormatter.title(
                            explicitTitle: entry.title,
                            body: entry.body,
                            fallback: entry.kind.localizedName
                        )
                    )
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
