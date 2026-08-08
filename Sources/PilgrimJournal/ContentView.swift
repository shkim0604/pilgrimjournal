import JournalDomain
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPresentingSearchFilters = false
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar
    #if os(iOS)
    @State private var editMode = EditMode.inactive
    #endif

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            List {
                SidebarCategoryButton(
                    title: "전체 기록",
                    systemImage: "books.vertical",
                    isSelected: model.selectedKind == nil
                ) {
                    selectKind(nil)
                }

                ForEach(JournalKind.allCases) { kind in
                    SidebarCategoryButton(
                        title: kind.localizedName,
                        systemImage: icon(for: kind),
                        isSelected: model.selectedKind == kind
                    ) {
                        selectKind(kind)
                    }
                }
            }
            .navigationTitle("Pilgrim Journal")
        } content: {
            Group {
                if model.isBatchSelecting {
                    List(model.entries, selection: $model.selectedEntryIDs) { entry in
                        EntryRow(entry: entry)
                            .tag(entry.id)
                    }
                } else {
                    List(selection: entrySelection) {
                        Button {
                            model.beginNewEntry()
                        } label: {
                            Label("새 노트", systemImage: "plus.circle.fill")
                                .font(.headline)
                                .foregroundStyle(.tint)
                                .frame(
                                    maxWidth: .infinity,
                                    alignment: .leading
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("빈 노트를 오른쪽 편집기에 엽니다.")

                        Section("노트") {
                            if model.entries.isEmpty,
                               !model.hasActiveSearchCriteria {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("아직 노트가 없습니다.")
                                        .font(.headline)
                                    Text("위의 ‘새 노트’를 눌러 바로 작성하세요.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 8)
                            } else {
                                ForEach(model.entries) { entry in
                                    EntryRow(entry: entry)
                                        .tag(entry.id)
                                        .contextMenu {
                                            Button("편집") {
                                                #if os(macOS)
                                                model.selectEntry(entry.id)
                                                #else
                                                model.beginEditing(entry)
                                                #endif
                                            }
                                            Button(
                                                "휴지통으로 이동",
                                                role: .destructive
                                            ) {
                                                model.moveToTrash(entry)
                                            }
                                        }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if model.entries.isEmpty && model.hasActiveSearchCriteria {
                    ContentUnavailableView {
                        Label("검색 결과가 없습니다", systemImage: "magnifyingglass")
                    } description: {
                        Text("검색어나 필터를 바꾸거나 모든 조건을 지워보세요.")
                    } actions: {
                        Button("검색 조건 지우기") {
                            model.clearSearchCriteria()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .searchable(text: $model.searchText, prompt: "기록 검색")
            .onSubmit(of: .search) { model.refresh() }
            .onChange(of: model.searchText) { _, _ in model.refresh() }
            .navigationTitle(model.selectedKind?.localizedName ?? "전체 기록")
            .toolbar {
                if model.isBatchSelecting {
                    Button("정리 \(model.selectedEntryIDs.count)") {
                        model.isPresentingBatchOrganizer = true
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
                    isPresentingSearchFilters.toggle()
                } label: {
                    Label(
                        "검색 필터",
                        systemImage: model.hasActiveSearchCriteria
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
                .popover(isPresented: $isPresentingSearchFilters) {
                    SearchFilterView()
                        .environmentObject(model)
                }
                Button {
                    model.refreshTrash()
                    model.isPresentingTrash = true
                } label: {
                    Label("휴지통", systemImage: "trash")
                }
                Button {
                    model.beginNewEntry()
                } label: {
                    Label("새 노트", systemImage: "square.and.pencil")
                }
                #if os(macOS)
                Button {
                    model.isPresentingImporter = true
                } label: {
                    Label("Day One 가져오기", systemImage: "square.and.arrow.down")
                }
                #endif
            }
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
                        : .diary
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
            EntryEditorView(entry: model.editingEntry)
        }
        #endif
        .sheet(isPresented: $model.isPresentingTrash) {
            TrashView()
        }
        .sheet(isPresented: $model.isPresentingBatchOrganizer) {
            BatchOrganizerView()
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
    }

    private var entrySelection: Binding<UUID?> {
        Binding(
            get: { model.selectedEntryID },
            set: { model.selectEntry($0) }
        )
    }

    private func selectKind(_ kind: JournalKind?) {
        model.selectKind(kind)
        preferredCompactColumn = .content
    }

    private func icon(for kind: JournalKind) -> String {
        switch kind {
        case .prayer: "hands.sparkles"
        case .bibleStudy: "book.closed"
        case .reading: "books.vertical"
        case .diary: "pencil.and.scribble"
        case .unclassified: "tray"
        }
    }
}

private struct SidebarCategoryButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                }
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowBackground(Color.clear)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SearchFilterView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Picker("기록 유형", selection: $model.selectedKind) {
                Text("모든 유형").tag(nil as JournalKind?)
                ForEach(JournalKind.allCases) { kind in
                    Text(kind.localizedName).tag(kind as JournalKind?)
                }
            }

            TextField("태그", text: $model.searchTagsText, prompt: Text("쉼표로 여러 태그 입력"))
                .textFieldStyle(.roundedBorder)

            Toggle("시작일", isOn: optionalDateToggle($model.searchStartDate))
            if model.searchStartDate != nil {
                DatePicker(
                    "시작일",
                    selection: concreteDate($model.searchStartDate),
                    displayedComponents: .date
                )
                .labelsHidden()
            }

            Toggle("종료일", isOn: optionalDateToggle($model.searchEndDate))
            if model.searchEndDate != nil {
                DatePicker(
                    "종료일",
                    selection: concreteDate($model.searchEndDate),
                    displayedComponents: .date
                )
                .labelsHidden()
            }

            HStack {
                Button("조건 초기화") {
                    model.clearSearchCriteria()
                }
                .disabled(!model.hasActiveSearchCriteria)
                Spacer()
                Button("적용") {
                    model.refresh()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 300)
        .padding()
        .onChange(of: model.selectedKind) { _, _ in model.refresh() }
        .onSubmit { model.refresh() }
    }

    private func optionalDateToggle(_ date: Binding<Date?>) -> Binding<Bool> {
        Binding(
            get: { date.wrappedValue != nil },
            set: { enabled in
                date.wrappedValue = enabled ? (date.wrappedValue ?? .now) : nil
                model.refresh()
            }
        )
    }

    private func concreteDate(_ date: Binding<Date?>) -> Binding<Date> {
        Binding(
            get: { date.wrappedValue ?? .now },
            set: {
                date.wrappedValue = $0
                model.refresh()
            }
        )
    }
}

private struct EntryRow: View {
    let entry: JournalEntryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.title.isEmpty ? entry.kind.localizedName : entry.title)
                    .font(.headline)
                if entry.isPinned { Image(systemName: "pin.fill").foregroundStyle(.secondary) }
                if entry.isStarred { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            Text(entry.body)
                .lineLimit(2)
                .foregroundStyle(.secondary)
            Text(entry.occurredAt, style: .date)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}
