import JournalDomain
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
struct InlineEntryEditorView: View {
    private enum FocusedField: Hashable {
        case title
        case tags
    }

    @EnvironmentObject private var model: AppModel
    @AppStorage("editor-text-scale") private var editorTextScale =
        EditorTextScale.defaultValue
    @FocusState private var focusedField: FocusedField?
    @State private var draft: JournalEntryDraft
    @State private var tagsText: String
    @State private var lastSavedDraft: JournalEntryDraft
    @State private var lastSavedTagsText: String
    @State private var pendingKind: JournalKind?
    @State private var isConfirmingTypeChange = false
    @State private var isPresentingHistory = false
    @State private var saveState = EditorSaveState.saved
    @State private var lastSavedAt: Date?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var persistedEntryID: UUID?
    private let entry: JournalEntryRecord?

    init(
        entry: JournalEntryRecord?,
        defaultKind: JournalKind = .diary,
        defaultNotebookName: String? = nil
    ) {
        var initial = entry?.draft ?? JournalEntryDraft(kind: defaultKind)
        if entry == nil { initial.notebookName = defaultNotebookName }
        let initialTags = initial.visibleTags.joined(separator: ", ")
        self.entry = entry
        _draft = State(initialValue: initial)
        _tagsText = State(initialValue: initialTags)
        _lastSavedDraft = State(initialValue: initial)
        _lastSavedTagsText = State(initialValue: initialTags)
        _lastSavedAt = State(initialValue: entry?.updatedAt)
        _persistedEntryID = State(initialValue: entry?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Rectangle()
                .fill(JournalTheme.separator)
                .frame(height: 1)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PaperEditorSurface {
                    VStack(alignment: .leading, spacing: JournalTheme.Spacing.regular) {
                        TextField("제목", text: $draft.title)
                            .textFieldStyle(.plain)
                            .font(.system(
                                size: 32 * editorTextScale,
                                weight: .bold
                            ))
                            .foregroundStyle(JournalTheme.ink)
                            .focused($focusedField, equals: .title)
                            .accessibilityLabel("제목")

                        typeSpecificFields

                        MarkdownBodyEditor(
                            text: $draft.body,
                            minHeight: 320,
                            autoFocus: entry == nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Rectangle()
                            .fill(JournalTheme.separator)
                            .frame(height: 1)

                        tagsEditor
                        AttachmentEditorSection(
                            entryID: persistedEntryID,
                            ensureEntryID: ensurePersistedEntryID
                        )
                        editorFooter
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(JournalTheme.canvas)
        .onChange(of: draft) { _, _ in scheduleAutosave() }
        .onChange(of: tagsText) { _, _ in scheduleAutosave() }
        .onReceive(
            NotificationCenter.default.publisher(for: .saveJournalEntry)
        ) { _ in
            autosaveTask?.cancel()
            performAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            performAutosave()
        }
        .sheet(isPresented: $isPresentingHistory) {
            if let entry {
                RevisionHistoryView(entry: entry)
            }
        }
        .confirmationDialog(
            "기록 유형을 바꾸면 일부 상세 정보가 제거됩니다.",
            isPresented: $isConfirmingTypeChange,
            titleVisibility: .visible
        ) {
            Button("유형 변경", role: .destructive) {
                applyPendingKind()
            }
            Button("취소", role: .cancel) {
                pendingKind = nil
            }
        } message: {
            Text(discardedDetailLabels.joined(separator: ", "))
        }
    }

    private var editorToolbar: some View {
        ViewThatFits(in: .horizontal) {
            fullMetadataToolbar
            compactMetadataToolbar
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(JournalTheme.paper)
    }

    private var fullMetadataToolbar: some View {
        HStack(spacing: JournalTheme.Spacing.small) {
            MetadataChip { kindPicker }
            MetadataChip { notebookPicker }
            MetadataChip {
                DatePicker(
                    "기록 시각",
                    selection: $draft.occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .labelsHidden()
                .fixedSize()
            }
            Spacer(minLength: JournalTheme.Spacing.small)
            editorActions
            saveStatusButton
        }
    }

    private var compactMetadataToolbar: some View {
        HStack(spacing: JournalTheme.Spacing.small) {
            MetadataChip { kindPicker }
            MetadataChip { notebookPicker }
            Spacer(minLength: JournalTheme.Spacing.small)
            Menu {
                DatePicker("기록 시각", selection: $draft.occurredAt)
                Toggle("즐겨찾기", isOn: $draft.isStarred)
                Toggle("고정", isOn: $draft.isPinned)
                if entry != nil {
                    Button("수정 이력") { isPresentingHistory = true }
                }
            } label: {
                Label("기록 정보", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            saveStatusButton
        }
    }

    private var kindPicker: some View {
        Picker("기록 유형", selection: kindBinding) {
            ForEach(JournalKind.allCases.filter(\.canCreateManually)) { kind in
                Text(kind.localizedName).tag(kind)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var notebookPicker: some View {
        Picker("노트북", selection: notebookBinding) {
            Text("노트북 없음").tag(nil as String?)
            ForEach(model.notebooks, id: \.self) { notebook in
                Text(notebook).tag(notebook as String?)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var editorActions: some View {
        HStack(spacing: JournalTheme.Spacing.small) {
            Button {
                draft.isStarred.toggle()
            } label: {
                Label(
                    draft.isStarred ? "즐겨찾기 해제" : "즐겨찾기",
                    systemImage: draft.isStarred ? "star.fill" : "star"
                )
            }
            .foregroundStyle(
                draft.isStarred ? JournalTheme.accentWarm : JournalTheme.inkSecondary
            )
            .labelStyle(.iconOnly)

            Button {
                draft.isPinned.toggle()
            } label: {
                Label(
                    draft.isPinned ? "고정 해제" : "고정",
                    systemImage: draft.isPinned ? "pin.fill" : "pin"
                )
            }
            .foregroundStyle(JournalTheme.inkSecondary)
            .labelStyle(.iconOnly)

            if entry != nil {
                Button {
                    isPresentingHistory = true
                } label: {
                    Label("수정 이력", systemImage: "clock.arrow.circlepath")
                }
                .foregroundStyle(JournalTheme.inkSecondary)
                .labelStyle(.iconOnly)
            }
        }
    }

    private var saveStatusButton: some View {
        Button {
            performAutosave()
        } label: {
            StatusPill(state: saveState)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(saveState == .saved ? "모든 변경이 저장되었습니다." : "지금 다시 저장")
    }

    @ViewBuilder
    private var typeSpecificFields: some View {
        switch draft.kind {
        case .prayer:
            HStack {
                Picker(
                    "기도 상태",
                    selection: Binding(
                        get: { draft.details.prayerStatus ?? .ongoing },
                        set: { draft.details.prayerStatus = $0 }
                    )
                ) {
                    Text("기도 중").tag(PrayerStatus.ongoing)
                    Text("응답됨").tag(PrayerStatus.answered)
                }
                .pickerStyle(.menu)
                if draft.details.prayerStatus == .answered {
                    DatePicker(
                        "응답일",
                        selection: Binding(
                            get: { draft.details.answeredAt ?? .now },
                            set: { draft.details.answeredAt = $0 }
                        ),
                        displayedComponents: .date
                    )
                }
            }
        case .bibleStudy:
            TextField("성경 구절", text: optionalBinding(\.scriptureReference))
                .journalMetadataField()
        case .reading:
            HStack {
                TextField("책 제목", text: optionalBinding(\.bookTitle))
                    .journalMetadataField()
                TextField("저자", text: optionalBinding(\.bookAuthor))
                    .journalMetadataField()
            }
        case .diary:
            TextField("오늘의 기분", text: optionalBinding(\.mood))
                .journalMetadataField()
        case .memo:
            EmptyView()
        case .unclassified:
            EmptyView()
        }
    }

    private var kindBinding: Binding<JournalKind> {
        Binding(
            get: { draft.kind },
            set: { newKind in
                guard newKind != draft.kind else { return }
                pendingKind = newKind
                if discardedDetailLabels.isEmpty {
                    applyPendingKind()
                } else {
                    isConfirmingTypeChange = true
                }
            }
        )
    }

    private func optionalBinding(
        _ keyPath: WritableKeyPath<EntryDetails, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft.details[keyPath: keyPath] ?? "" },
            set: { draft.details[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var discardedDetailLabels: [String] {
        var labels: [String] = []
        guard let pendingKind else { return labels }
        let details = draft.details
        if pendingKind != .prayer,
           details.prayerStatus != nil || details.answeredAt != nil {
            labels.append("기도 상태·응답일")
        }
        if pendingKind != .bibleStudy,
           !(details.scriptureReference ?? "").isEmpty {
            labels.append("성경 구절")
        }
        if pendingKind != .reading,
           !(details.bookTitle ?? "").isEmpty || !(details.bookAuthor ?? "").isEmpty {
            labels.append("책 제목·저자")
        }
        if pendingKind != .diary, !(details.mood ?? "").isEmpty {
            labels.append("기분")
        }
        return labels
    }

    private var parsedTags: [String] {
        var result: [String] = []
        let candidates = tagsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for tag in candidates {
            if !result.contains(where: {
                $0.caseInsensitiveCompare(tag) == .orderedSame
            }) {
                result.append(tag)
            }
        }
        return result
    }

    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            Text("태그")
                .font(.caption.weight(.semibold))
                .foregroundStyle(JournalTheme.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: JournalTheme.Spacing.small) {
                    ForEach(parsedTags, id: \.self) { tag in
                        TagChip(tag: tag) { removeTag(tag) }
                    }
                    TextField("태그 추가 (쉼표로 구분)", text: $tagsText)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .tags)
                        .frame(minWidth: 190)
                }
            }
        }
    }

    private var editorFooter: some View {
        HStack(spacing: JournalTheme.Spacing.medium) {
            Label("\(draft.body.count)자", systemImage: "character.cursor.ibeam")
            if let lastSavedAt {
                Label(
                    lastSavedAt.formatted(date: .omitted, time: .shortened),
                    systemImage: "clock"
                )
            }
            Spacer()
            if case let .failed(message) = saveState {
                Button("다시 저장") { performAutosave() }
                    .help(message)
            }
        }
        .font(.caption)
        .foregroundStyle(JournalTheme.inkSecondary)
        .accessibilityElement(children: .combine)
    }

    private func removeTag(_ tag: String) {
        tagsText = parsedTags
            .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            .joined(separator: ", ")
    }

    private var notebookBinding: Binding<String?> {
        Binding(
            get: { draft.notebookName },
            set: { draft.notebookName = $0 }
        )
    }

    private var isDirty: Bool {
        draft != lastSavedDraft || tagsText != lastSavedTagsText
    }

    private func scheduleAutosave() {
        guard isDirty else { return }
        let hasContent = !draft.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty || !draft.body.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        guard hasContent else { return }
        autosaveTask?.cancel()
        saveState = .saving
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            performAutosave()
        }
    }

    private func performAutosave() {
        guard !model.isEntryDeleted(persistedEntryID ?? draft.id) else {
            saveState = .saved
            return
        }
        guard isDirty else {
            saveState = .saved
            return
        }
        let hasContent = !draft.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty || !draft.body.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        guard hasContent else { return }
        autosaveTask?.cancel()
        saveState = .saving
        var outgoing = draft
        outgoing.id = persistedEntryID ?? outgoing.id
        outgoing.tags = NotebookTagCodec.replacingVisibleTags(
            in: draft.tags,
            with: parsedTags
        )
        guard let record = model.saveAndReturnRecord(
            outgoing,
            closeEditor: false,
            selectSavedEntry: false
        ) else {
            saveState = .failed(model.errorMessage ?? "기록을 저장할 수 없습니다.")
            return
        }
        persistedEntryID = record.id
        lastSavedDraft = draft
        lastSavedTagsText = tagsText
        lastSavedAt = record.updatedAt
        saveState = .saved
    }

    private func ensurePersistedEntryID() -> UUID? {
        performAutosave()
        return persistedEntryID
    }

    private func applyPendingKind() {
        guard let pendingKind else { return }
        draft.kind = pendingKind
        draft.details = (try? draft.details.validated(for: pendingKind)) ?? EntryDetails()
        self.pendingKind = nil
    }
}
#endif

struct EntryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPresentingHistory = false
    let entry: JournalEntryRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        kindBadge
                        Spacer(minLength: JournalTheme.Spacing.regular)
                        detailActions
                    }
                    VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
                        kindBadge
                        detailActions
                    }
                }
                if let notebook = entry.notebookName {
                    Label(notebook, systemImage: "book.closed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(entry.title.isEmpty ? entry.kind.localizedName : entry.title)
                    .font(.largeTitle.bold())
                    .foregroundStyle(JournalTheme.ink)
                Text(entry.occurredAt.formatted(date: .long, time: .shortened))
                    .foregroundStyle(JournalTheme.inkSecondary)
                typeDetails
                MarkdownPreviewView(markdown: entry.body)
                AttachmentEditorSection(
                    entryID: entry.id,
                    ensureEntryID: { entry.id },
                    allowsImport: false
                )
                if !entry.visibleTags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(entry.visibleTags, id: \.self) { tag in
                                TagChip(tag: tag)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .background(JournalTheme.paper)
        }
        .background(JournalTheme.canvas)
        .sheet(isPresented: $isPresentingHistory) {
            RevisionHistoryView(entry: entry)
        }
    }

    private var kindBadge: some View {
        Text(entry.kind.localizedName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(JournalTheme.categoryColor(for: entry.kind))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                JournalTheme.categoryColor(for: entry.kind).opacity(0.12),
                in: Capsule()
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailActions: some View {
        HStack(spacing: JournalTheme.Spacing.regular) {
            Button("편집") {
                model.beginEditing(entry)
            }
            Button("이력") {
                isPresentingHistory = true
            }
        }
    }

    @ViewBuilder
    private var typeDetails: some View {
        switch entry.kind {
        case .prayer:
            if let status = entry.details.prayerStatus {
                Label(
                    status == .answered ? "응답됨" : "기도 중",
                    systemImage: status == .answered ? "checkmark.circle" : "heart"
                )
            }
        case .bibleStudy:
            if let reference = entry.details.scriptureReference, !reference.isEmpty {
                Label(reference, systemImage: "book.closed")
            }
        case .reading:
            if let title = entry.details.bookTitle, !title.isEmpty {
                Label(
                    [title, entry.details.bookAuthor].compactMap { $0 }.joined(separator: " · "),
                    systemImage: "books.vertical"
                )
            }
        case .diary:
            if let mood = entry.details.mood, !mood.isEmpty {
                Label(mood, systemImage: "face.smiling")
            }
        case .memo:
            EmptyView()
        case .unclassified:
            EmptyView()
        }
    }
}

struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var draft: JournalEntryDraft
    @State private var tagsText: String
    @State private var lastSavedDraft: JournalEntryDraft
    @State private var lastSavedTagsText: String
    @State private var saveState = EditorSaveState.saved
    @State private var lastSavedAt: Date?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var persistedEntryID: UUID?
    @State private var pendingKind: JournalKind?
    @State private var isConfirmingTypeChange = false
    @State private var isShowingMetadata = false

    init(
        entry: JournalEntryRecord?,
        defaultKind: JournalKind = .diary,
        defaultNotebookName: String? = nil
    ) {
        var initial = entry?.draft ?? JournalEntryDraft(kind: defaultKind)
        if entry == nil { initial.notebookName = defaultNotebookName }
        let initialTags = initial.visibleTags.joined(separator: ", ")
        _draft = State(initialValue: initial)
        _tagsText = State(initialValue: initialTags)
        _lastSavedDraft = State(initialValue: initial)
        _lastSavedTagsText = State(initialValue: initialTags)
        _lastSavedAt = State(initialValue: entry?.updatedAt)
        _persistedEntryID = State(initialValue: entry?.id)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                JournalTheme.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: JournalTheme.Spacing.regular) {
                        mobileMetadataBar

                        TextField("제목", text: $draft.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.bold())
                            .foregroundStyle(JournalTheme.ink)
                            .accessibilityLabel("제목")

                        typeSpecificFields

                        MarkdownBodyEditor(text: $draft.body, minHeight: 380)

                        Rectangle()
                            .fill(JournalTheme.separator)
                            .frame(height: 1)

                        mobileTagsEditor
                        AttachmentEditorSection(
                            entryID: persistedEntryID,
                            ensureEntryID: ensurePersistedEntryID
                        )
                        mobileFooter
                    }
                    .padding(JournalTheme.Spacing.large)
                    .background(JournalTheme.paper)
                }
            }
            .navigationTitle(draft.id == nil ? "새 기록" : "기록 편집")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("완료") {
                        autosaveTask?.cancel()
                        if performAutosave() { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    StatusPill(state: saveState)
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Button { appendCommand(.h2) } label: {
                        Label("제목", systemImage: "textformat.size")
                    }
                    Button { appendCommand(.bullet) } label: {
                        Label("불릿", systemImage: "list.bullet")
                    }
                    Button { postMarkdownCommand(.outdentList) } label: {
                        Label("내어쓰기", systemImage: "decrease.indent")
                    }
                    Button { postMarkdownCommand(.indentList) } label: {
                        Label("하위 불릿", systemImage: "increase.indent")
                    }
                    Button { appendCommand(.today) } label: {
                        Label("오늘", systemImage: "calendar")
                    }
                    Spacer()
                    Button("키보드 닫기") { dismissKeyboard() }
                }
                #endif
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .interactiveDismissDisabled(saveState == .saving)
        .sheet(isPresented: $isShowingMetadata) {
            mobileMetadataSheet
        }
        .onChange(of: draft) { _, _ in scheduleAutosave() }
        .onChange(of: tagsText) { _, _ in scheduleAutosave() }
        .confirmationDialog(
            "기록 유형을 바꾸면 일부 상세 정보가 제거됩니다.",
            isPresented: $isConfirmingTypeChange,
            titleVisibility: .visible
        ) {
            Button("유형 변경", role: .destructive) {
                applyPendingKind()
            }
            Button("취소", role: .cancel) {
                pendingKind = nil
            }
        } message: {
            Text(discardedDetailLabels.joined(separator: ", "))
        }
    }

    private var mobileMetadataBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JournalTheme.Spacing.small) {
                Button {
                    isShowingMetadata = true
                } label: {
                    MetadataChip {
                        Label(
                            draft.kind.localizedName,
                            systemImage: "slider.horizontal.3"
                        )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("기록 유형, 노트북과 날짜를 편집합니다.")

                if let notebookName = draft.notebookName {
                    MetadataChip {
                        Label(notebookName, systemImage: "book.closed")
                    }
                }

                MetadataChip {
                    Label(
                        draft.occurredAt.formatted(date: .abbreviated, time: .omitted),
                        systemImage: "calendar"
                    )
                }
                Button {
                    draft.isStarred.toggle()
                } label: {
                    Image(systemName: draft.isStarred ? "star.fill" : "star")
                        .foregroundStyle(
                            draft.isStarred
                                ? JournalTheme.accentWarm
                                : JournalTheme.inkSecondary
                        )
                        .frame(width: 34, height: 34)
                        .background(JournalTheme.surfaceMuted, in: Circle())
                }
                .accessibilityLabel(draft.isStarred ? "즐겨찾기 해제" : "즐겨찾기")
                Button {
                    draft.isPinned.toggle()
                } label: {
                    Image(systemName: draft.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(JournalTheme.inkSecondary)
                        .frame(width: 34, height: 34)
                        .background(JournalTheme.surfaceMuted, in: Circle())
                }
                .accessibilityLabel(draft.isPinned ? "고정 해제" : "고정")
            }
        }
    }

    private var mobileMetadataSheet: some View {
        NavigationStack {
            Form {
                Section("분류") {
                    Picker("기록 유형", selection: kindBinding) {
                        ForEach(JournalKind.allCases.filter(\.canCreateManually)) { kind in
                            Text(kind.localizedName).tag(kind)
                        }
                    }
                    Picker("노트북", selection: notebookBinding) {
                        Text("노트북 없음").tag(nil as String?)
                        ForEach(model.notebooks, id: \.self) { notebook in
                            Text(notebook).tag(notebook as String?)
                        }
                    }
                }
                Section("기록 시각") {
                    DatePicker(
                        "날짜",
                        selection: $draft.occurredAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
                Section("표시") {
                    Toggle("즐겨찾기", isOn: $draft.isStarred)
                    Toggle("상단에 고정", isOn: $draft.isPinned)
                }
            }
            .scrollContentBackground(.hidden)
            .background(JournalTheme.canvas)
            .navigationTitle("기록 정보")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { isShowingMetadata = false }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private var mobileTagsEditor: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            Text("태그")
                .font(.caption.weight(.semibold))
                .foregroundStyle(JournalTheme.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: JournalTheme.Spacing.small) {
                    ForEach(parsedTags, id: \.self) { tag in
                        TagChip(tag: tag) { removeTag(tag) }
                    }
                    TextField("태그 추가", text: $tagsText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 140)
                }
            }
        }
    }

    private var mobileFooter: some View {
        HStack {
            Label("\(draft.body.count)자", systemImage: "character.cursor.ibeam")
            if let lastSavedAt {
                Label(
                    lastSavedAt.formatted(date: .omitted, time: .shortened),
                    systemImage: "clock"
                )
            }
            Spacer()
            if case .failed = saveState {
                Button("다시 저장") { _ = performAutosave() }
            }
        }
        .font(.caption)
        .foregroundStyle(JournalTheme.inkSecondary)
    }

    @ViewBuilder
    private var typeSpecificFields: some View {
        switch draft.kind {
        case .prayer:
            Picker(
                "기도 상태",
                selection: Binding(
                    get: { draft.details.prayerStatus ?? .ongoing },
                    set: { draft.details.prayerStatus = $0 }
                )
            ) {
                Text("기도 중").tag(PrayerStatus.ongoing)
                Text("응답됨").tag(PrayerStatus.answered)
            }
            if draft.details.prayerStatus == .answered {
                DatePicker(
                    "응답일",
                    selection: Binding(
                        get: { draft.details.answeredAt ?? .now },
                        set: { draft.details.answeredAt = $0 }
                    ),
                    displayedComponents: .date
                )
            }
        case .bibleStudy:
            TextField(
                "성경 구절",
                text: optionalBinding(\.scriptureReference)
            )
            .journalMetadataField()
        case .reading:
            TextField("책 제목", text: optionalBinding(\.bookTitle))
                .journalMetadataField()
            TextField("저자", text: optionalBinding(\.bookAuthor))
                .journalMetadataField()
        case .diary:
            TextField("기분", text: optionalBinding(\.mood))
                .journalMetadataField()
        case .memo:
            EmptyView()
        case .unclassified:
            EmptyView()
        }
    }

    private func optionalBinding(
        _ keyPath: WritableKeyPath<EntryDetails, String?>
    ) -> Binding<String> {
        Binding(
            get: { draft.details[keyPath: keyPath] ?? "" },
            set: { draft.details[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private var kindBinding: Binding<JournalKind> {
        Binding(
            get: { draft.kind },
            set: { newKind in
                guard newKind != draft.kind else { return }
                pendingKind = newKind
                if discardedDetailLabels.isEmpty {
                    applyPendingKind()
                } else {
                    isConfirmingTypeChange = true
                }
            }
        )
    }

    private var notebookBinding: Binding<String?> {
        Binding(
            get: { draft.notebookName },
            set: { draft.notebookName = $0 }
        )
    }

    private var discardedDetailLabels: [String] {
        var labels: [String] = []
        guard let pendingKind else { return labels }
        let details = draft.details
        if pendingKind != .prayer,
           details.prayerStatus != nil || details.answeredAt != nil {
            labels.append("기도 상태·응답일")
        }
        if pendingKind != .bibleStudy,
           !(details.scriptureReference ?? "").isEmpty {
            labels.append("성경 구절")
        }
        if pendingKind != .reading,
           !(details.bookTitle ?? "").isEmpty || !(details.bookAuthor ?? "").isEmpty {
            labels.append("책 제목·저자")
        }
        if pendingKind != .diary, !(details.mood ?? "").isEmpty {
            labels.append("기분")
        }
        return labels
    }

    private var isDirty: Bool {
        draft != lastSavedDraft || tagsText != lastSavedTagsText
    }

    private var parsedTags: [String] {
        var result: [String] = []
        let candidates = tagsText
            .split(separator: ",")
            .map({ String($0).trimmingCharacters(in: .whitespaces) })
            .filter({ !$0.isEmpty })
        for tag in candidates {
            if !result.contains(where: {
                $0.caseInsensitiveCompare(tag) == .orderedSame
            }) {
                result.append(tag)
            }
        }
        return result
    }

    private func removeTag(_ tag: String) {
        tagsText = parsedTags
            .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            .joined(separator: ", ")
    }

    private func scheduleAutosave() {
        guard isDirty else { return }
        let hasContent = !draft.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty || !draft.body.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        guard hasContent else { return }
        autosaveTask?.cancel()
        saveState = .saving
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = performAutosave()
        }
    }

    @discardableResult
    private func performAutosave() -> Bool {
        guard !model.isEntryDeleted(persistedEntryID ?? draft.id) else {
            saveState = .saved
            return true
        }
        guard isDirty else {
            saveState = .saved
            return true
        }
        let hasContent = !draft.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty || !draft.body.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        guard hasContent else {
            saveState = .saved
            return true
        }
        autosaveTask?.cancel()
        saveState = .saving
        var outgoing = draft
        outgoing.id = persistedEntryID ?? outgoing.id
        outgoing.tags = NotebookTagCodec.replacingVisibleTags(
            in: draft.tags,
            with: parsedTags
        )
        guard let record = model.saveAndReturnRecord(
            outgoing,
            closeEditor: false,
            selectSavedEntry: false
        ) else {
            saveState = .failed(model.errorMessage ?? "기록을 저장할 수 없습니다.")
            return false
        }
        persistedEntryID = record.id
        lastSavedDraft = draft
        lastSavedTagsText = tagsText
        lastSavedAt = record.updatedAt
        saveState = .saved
        return true
    }

    private func ensurePersistedEntryID() -> UUID? {
        guard performAutosave() else { return nil }
        return persistedEntryID
    }

    private func appendCommand(_ command: MarkdownSlashCommand) {
        draft.body = MarkdownCommandProcessor.applying(command, to: draft.body)
    }

    #if os(iOS)
    private func postMarkdownCommand(_ command: MarkdownKeyboardCommand) {
        NotificationCenter.default.post(
            name: .applyMarkdownKeyboardCommand,
            object: command.rawValue
        )
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
    #endif

    private func applyPendingKind() {
        guard let pendingKind else { return }
        draft.kind = pendingKind
        draft.details = (try? draft.details.validated(for: pendingKind)) ?? EntryDetails()
        self.pendingKind = nil
    }
}

private struct AttachmentEditorSection: View {
    @EnvironmentObject private var model: AppModel
    let entryID: UUID?
    let ensureEntryID: () -> UUID?
    var allowsImport = true
    @State private var attachments: [AttachmentRecord] = []
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            HStack {
                Text("첨부")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JournalTheme.inkSecondary)
                Spacer()
                if allowsImport {
                    Button {
                        guard entryID != nil || ensureEntryID() != nil else {
                            model.errorMessage = "첨부 전에 제목이나 본문을 입력해 기록을 저장해 주세요."
                            return
                        }
                        isImporting = true
                    } label: {
                        Label("첨부 추가", systemImage: "paperclip")
                    }
                    .buttonStyle(.borderless)
                }
            }

            if attachments.isEmpty {
                Text("첨부 파일 없음")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
            } else {
                ForEach(attachments) { attachment in
                    HStack(spacing: JournalTheme.Spacing.small) {
                        Image(systemName: attachmentIcon(for: attachment.mimeType))
                            .foregroundStyle(JournalTheme.brandPrimary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.originalName)
                                .lineLimit(1)
                            Text(attachmentStatus(attachment))
                                .font(.caption2)
                                .foregroundStyle(
                                    attachment.state == .failed
                                        ? Color.red
                                        : JournalTheme.inkSecondary
                                )
                        }
                        Spacer()
                        attachmentAction(attachment)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image, .movie, .audio, .pdf, .data],
            allowsMultipleSelection: false
        ) { result in
            do {
                let url = try result.get().first
                guard let url else { return }
                guard let targetID = entryID ?? ensureEntryID() else {
                    model.errorMessage = "첨부할 기록을 먼저 저장해 주세요."
                    return
                }
                if model.addAttachment(from: url, to: targetID) {
                    attachments = model.attachments(for: targetID)
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .onAppear { attachments = model.attachments(for: entryID) }
        .onChange(of: entryID) { _, newValue in
            attachments = model.attachments(for: newValue)
        }
        .onChange(of: model.attachmentRevision) { _, _ in
            attachments = model.attachments(for: entryID)
        }
    }

    private func attachmentIcon(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        return "doc"
    }

    private func attachmentStatus(_ attachment: AttachmentRecord) -> String {
        let size = ByteCountFormatter.string(
            fromByteCount: attachment.byteCount,
            countStyle: .file
        )
        let state = switch attachment.state {
        case .local: "이 기기에 저장됨"
        case .pending: "iCloud 업로드 대기"
        case .uploaded: "iCloud에 저장됨"
        case .downloading: "다운로드 중"
        case .failed: "전송 실패 · 다시 시도 필요"
        }
        return "\(size) · \(state)"
    }

    @ViewBuilder
    private func attachmentAction(_ attachment: AttachmentRecord) -> some View {
        if attachment.state == .failed {
            Button("재시도") {
                model.retryAttachmentTransfer(attachment.id)
            }
            .buttonStyle(.bordered)
        } else if attachment.state == .pending || attachment.state == .downloading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(attachmentStatus(attachment))
        } else if !model.hasLocalBinary(for: attachment.id) {
            Button("다운로드") {
                model.requestAttachmentDownload(attachment.id)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct RevisionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntryRecord

    var body: some View {
        NavigationStack {
            List(model.revisions(for: entry.id)) { revision in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(revision.snapshot.title.isEmpty ? "제목 없음" : revision.snapshot.title)
                            .font(.headline)
                        if revision.id == entry.currentRevisionID {
                            Text("현재")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(revision.snapshot.body)
                        .lineLimit(3)
                        .foregroundStyle(.secondary)
                    Text("\(revision.createdAt.formatted()) · \(revision.deviceID)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if revision.id != entry.currentRevisionID {
                        Button("이 버전으로 복원") {
                            model.restoreRevision(entryID: entry.id, revisionID: revision.id)
                            dismiss()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("수정 이력")
            .toolbar {
                Button("닫기") { dismiss() }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

struct TrashView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List(model.trashEntries) { entry in
                #if os(iOS)
                VStack(alignment: .leading, spacing: 10) {
                    trashEntryDescription(entry)
                    Button {
                        model.restoreFromTrash(entry)
                    } label: {
                        Label("복원", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
                #else
                HStack {
                    trashEntryDescription(entry)
                    Spacer()
                    Button("복원") {
                        model.restoreFromTrash(entry)
                    }
                }
                #endif
            }
            .overlay {
                if model.trashEntries.isEmpty {
                    ContentUnavailableView("휴지통이 비었습니다", systemImage: "trash")
                }
            }
            .navigationTitle("휴지통")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .onAppear { model.refreshTrash() }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #endif
    }

    @ViewBuilder
    private func trashEntryDescription(_ entry: JournalEntryRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title.isEmpty ? entry.kind.localizedName : entry.title)
                .font(.headline)
                .lineLimit(2)
            if let deletedAt = entry.deletedAt {
                Text("삭제 \(deletedAt.formatted())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct BatchOrganizerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var targetKind: JournalKind?
    @State private var tagsText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(
                        "선택한 기록",
                        value: "\(model.selectedEntryIDs.count)개"
                    )
                }
                Section("유형") {
                    Picker("변경할 유형", selection: $targetKind) {
                        Text("유형 유지").tag(nil as JournalKind?)
                        ForEach(
                            JournalKind.allCases.filter(\.canCreateManually)
                        ) { kind in
                            Text(kind.localizedName).tag(kind as JournalKind?)
                        }
                    }
                    Text("유형을 바꾸면 각 기록에 새 revision이 생성되고 해당 유형에 맞지 않는 상세 필드는 정리됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("태그 추가") {
                    TextField("쉼표로 여러 태그 입력", text: $tagsText)
                    Text("기존 태그는 유지하며 중복 태그는 한 번만 저장합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("선택 기록 정리")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("적용") {
                        if model.organizeSelectedEntries(
                            targetKind: targetKind,
                            addingTags: parsedTags
                        ) {
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(targetKind == nil && parsedTags.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    private var parsedTags: [String] {
        tagsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
