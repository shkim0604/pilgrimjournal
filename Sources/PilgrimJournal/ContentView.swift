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

    private var listTitle: String {
        model.selectedSharedSpaceTitle
            ?? model.selectedNotebookName
            ?? model.selectedKind.map { model.kindDefinition(for: $0).displayName }
            ?? String(localized: "전체 기록")
    }

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            JournalSidebar(preferredCompactColumn: $preferredCompactColumn)
                #if os(macOS)
            .toolbar(removing: isFocusMode ? .sidebarToggle : nil)
                #endif
        } content: {
            // The timeline contributes search and actions to the window toolbar
            // even when its split pane is hidden.
            if isFocusMode {
                Color.clear
            } else if let groupID = model.selectedGroupID, let groups = model.groups {
                GroupFeedView(
                    groups: groups,
                    groupID: groupID,
                    preferredCompactColumn: $preferredCompactColumn
                )
                .id(groupID)
            } else {
                timeline
            }
        } detail: {
            #if os(macOS)
            Group {
                if model.isPresentingSettings {
                    SettingsView()
                } else if let groupID = model.selectedGroupID, let groups = model.groups {
                    GroupPostDetailView(
                        groups: groups, groupID: groupID, postID: model.selectedGroupPostID)
                } else if let entry = model.selectedEntry {
                    InlineEntryEditorView(entry: entry, isFocusMode: isFocusMode)
                        .id(entry.id)
                } else if model.selectedEntryIDs.count > 1 {
                    JournalEmptyState(
                        title: String(
                            localized: "\(model.selectedEntryIDs.count)개의 노트를 선택했습니다"
                        ),
                        description: String(
                            localized:
                                "도구 막대의 휴지통으로 한 번에 삭제하거나, ‘선택’ → ‘정리’로 유형과 태그를 바꿀 수 있습니다."
                        ),
                        systemImage: "checklist"
                    ) {}
                } else if model.isPresentingEditor {
                    InlineEntryEditorView(
                        entry: nil,
                        isFocusMode: isFocusMode,
                        defaultKind: model.defaultKindForNewEntry,
                        defaultNotebookName: model.newEntryNotebookName
                    )
                    .id(model.editorSessionID)
                } else {
                    JournalEmptyState(
                        title: String(localized: "기록을 선택하세요"),
                        description: String(localized: "왼쪽 목록에서 기록을 고르거나 새 기록을 시작하세요."),
                        systemImage: "doc.text"
                    ) {}
                }
            }
            // Focus mode drops the window toolbar, so this is the visible way
            // out next to ⌘⇧F and Escape.
            .overlay(alignment: .topTrailing) {
                if isFocusMode {
                    Button {
                        setFocusMode(false)
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(JournalTheme.inkSecondary)
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("집중 모드 종료 (⌘⇧F)")
                    .accessibilityLabel("집중 모드 종료")
                    .padding(JournalTheme.Spacing.regular)
                    .transition(.opacity)
                }
            }
            .navigationSplitViewColumnWidth(min: JournalTheme.detailMinWidth, ideal: 560)
            #else
            // Settings is only shown when it was actually asked for. Using it
            // as the "nothing selected" fallback meant any moment where the
            // selection could not be resolved bounced the user into settings.
            if model.isPresentingSettings {
                SettingsView()
            } else if let groupID = model.selectedGroupID, let groups = model.groups {
                GroupPostDetailView(
                    groups: groups, groupID: groupID, postID: model.selectedGroupPostID)
            } else if let entry = model.selectedEntry {
                EntryDetailView(entry: entry)
            } else {
                JournalEmptyState(
                    title: String(localized: "기록을 선택하세요"),
                    description: String(localized: "왼쪽 목록에서 기록을 고르면 여기에 내용이 보입니다."),
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
        #if PILGRIM_SWIFTDATA
        .modifier(SharedSpacesContentModifier())
        #endif
        .sheet(isPresented: $model.isPresentingKindManagement) {
            KindManagementSheet()
        }
        #if os(iOS)
        // 지금 동기화 reopens the store, which rebuilds this view; on iPhone
        // it would otherwise come back on the sidebar instead of settings.
        .onAppear {
            if model.isPresentingSettings { preferredCompactColumn = .detail }
        }
        #endif
        #if os(macOS)
        // Swapping the detail column's content (switching entries, a new
        // note's autosave) makes SwiftUI write its own idea of the layout back
        // into `columnVisibility`. Treating that as "the user reopened the
        // panels" is what made focus mode drop out while typing. Focus mode
        // owns the layout instead: undo any write-back, and leave ending it to
        // explicit commands (the exit button, ⌘⇧F, ⌃⌘S, Escape). With
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
                "선택한 \(model.selectedEntryIDs.count)개의 노트를 휴지통으로 이동합니다."
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

    private var timeline: some View {
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
                #else
                // Bound on the list itself: each split-view column brings its
                // own edit mode, so a binding set around the whole split view
                // never reaches it and the rows stay unselectable.
                .environment(\.editMode, $editMode)
                #endif
            } else if showsPrayerTopicList {
                prayerTopicList
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsPrayerSegments {
                prayerScopePicker
            }
        }
        .overlay {
            if showsPrayerTopicList {
                if model.prayerScope == .ongoing && model.ongoingPrayerItems.isEmpty {
                    JournalEmptyState(
                        title: String(localized: "기도 중인 기도제목이 없습니다"),
                        description: String(localized: "노트 탭에서 노트를 열어 기도제목을 추가해 보세요."),
                        systemImage: "heart"
                    ) {}
                } else if model.prayerScope == .answered && model.answeredPrayerSections.isEmpty {
                    JournalEmptyState(
                        title: String(localized: "아직 응답된 기도제목이 없습니다"),
                        description: String(localized: "기도제목을 체크하면 응답일과 함께 여기에 모입니다."),
                        systemImage: "checkmark.circle"
                    ) {}
                }
            } else if model.entries.isEmpty && model.hasActiveSearchCriteria {
                JournalEmptyState(
                    title: String(localized: "검색 결과가 없습니다"),
                    description: String(localized: "검색어나 필터를 바꾸거나 모든 조건을 지워보세요."),
                    systemImage: "magnifyingglass"
                ) {
                    Button("검색 조건 지우기") {
                        model.clearSearchCriteria()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if model.entries.isEmpty && !model.isBatchSelecting {
                JournalEmptyState(
                    title: String(localized: "아직 노트가 없습니다"),
                    description: String(localized: "위의 ‘새 노트’를 눌러 바로 작성하세요."),
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
        .navigationTitle(listTitle)
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
                setFocusMode(true)
            } label: {
                Label("집중 모드", systemImage: "rectangle.inset.filled")
            }
            #endif
        }
        .navigationSplitViewColumnWidth(
            min: JournalTheme.timelineWidth.lowerBound,
            ideal: 330,
            max: JournalTheme.timelineWidth.upperBound
        )
    }

    private var showsPrayerSegments: Bool {
        model.isPrayerKindSelected && !model.isBatchSelecting && !model.hasActiveSearchFilters
    }

    private var showsPrayerTopicList: Bool {
        showsPrayerSegments && model.prayerScope != .notes
    }

    private var prayerScopePicker: some View {
        Picker("보기", selection: prayerScopeSelection) {
            Text("노트").tag(PrayerScope.notes)
            Text("기도중").tag(PrayerScope.ongoing)
            Text("응답").tag(PrayerScope.answered)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(JournalTheme.canvas)
    }

    private var prayerScopeSelection: Binding<PrayerScope> {
        Binding(
            get: { model.prayerScope },
            set: { model.selectPrayerScope($0) }
        )
    }

    @ViewBuilder
    private var prayerTopicList: some View {
        switch model.prayerScope {
        case .ongoing:
            List {
                ForEach(model.ongoingPrayerItems) { item in
                    prayerTopicRow(item)
                }
            }
        case .answered:
            List {
                ForEach(model.answeredPrayerSections) { section in
                    Section(section.month.formatted(.dateTime.year().month())) {
                        ForEach(section.items) { item in
                            prayerTopicRow(item)
                        }
                    }
                }
            }
        case .notes:
            EmptyView()
        }
    }

    private func prayerTopicRow(_ item: PrayerTopicItem) -> some View {
        PrayerTopicItemRow(
            item: item,
            noteTitle: item.entryTitle.isEmpty
                ? model.kindDefinition(for: .prayer).displayName
                : item.entryTitle
        ) {
            model.setPrayerTopicStatus(
                entryID: item.entryID,
                topicID: item.topic.id,
                status: item.topic.status == .answered ? .ongoing : .answered
            )
        }
        .onTapGesture {
            model.selectEntry(item.entryID)
            #if os(iOS)
            preferredCompactColumn = .detail
            #endif
        }
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

extension Notification.Name {
    /// Saves the open entry editor now (⌘S on macOS, and AppModel's flush
    /// before a kind move on both platforms).
    static let saveJournalEntry = Notification.Name(
        "PilgrimJournal.saveEntry"
    )
}
