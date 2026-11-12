import JournalDomain
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif
#if os(iOS)
import QuickLook
import UIKit
#endif

#if os(macOS)
struct InlineEntryEditorView: View {
    private enum FocusedField: Hashable {
        case title
        case tags
    }

    @EnvironmentObject private var model: AppModel
    @AppStorage(EditorTextScale.storageKey) private var editorTextScale =
        EditorTextScale.defaultValue
    @FocusState private var focusedField: FocusedField?
    @State private var draft: JournalEntryDraft
    /// Comma-joined *committed* tags only — a tag leaves the raw text the
    /// moment it's finished (comma, Return, or autosave) and becomes just a
    /// chip. See `tagInputDraft` for what's still being typed.
    @State private var tagsText: String
    /// The tag currently being typed, not yet committed to `tagsText`. Kept
    /// separate so the text field only ever shows the in-progress tag, not
    /// every previously-typed tag alongside its own chip.
    @State private var tagInputDraft = ""
    @State private var lastSavedDraft: JournalEntryDraft
    @State private var lastSavedTagsText: String
    @State private var lastSavedTagInputDraft = ""
    @State private var pendingKind: JournalKind?
    @State private var isConfirmingTypeChange = false
    @State private var isPresentingHistory = false
    @State private var saveState = EditorSaveState.saved
    @State private var lastSavedAt: Date?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var persistedEntryID: UUID?
    // Grapheme-cluster counting the whole body is O(body length) — cheap
    // once, but the footer used to compute `draft.body.count` directly in
    // `body`, which reruns on every SwiftUI render pass (multiple per
    // keystroke). Computed once per actual body change instead, in the
    // `onChange(of: draft)` handler below.
    @State private var bodyCharacterCount: Int
    private let entry: JournalEntryRecord?
    private let isFocusMode: Bool

    init(
        entry: JournalEntryRecord?,
        isFocusMode: Bool,
        defaultKind: JournalKind = .diary,
        defaultNotebookName: String? = nil
    ) {
        var initial = entry?.draft ?? JournalEntryDraft(kind: defaultKind)
        if entry == nil { initial.notebookName = defaultNotebookName }
        let initialTags = initial.visibleTags.joined(separator: ", ")
        self.isFocusMode = isFocusMode
        self.entry = entry
        _draft = State(initialValue: initial)
        _tagsText = State(initialValue: initialTags)
        _lastSavedDraft = State(initialValue: initial)
        _lastSavedTagsText = State(initialValue: initialTags)
        _lastSavedAt = State(initialValue: entry?.updatedAt)
        _persistedEntryID = State(initialValue: entry?.id)
        _bodyCharacterCount = State(initialValue: initial.body.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isFocusMode {
                editorToolbar
                Rectangle()
                    .fill(JournalTheme.separator)
                    .frame(height: 1)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                PaperEditorSurface {
                    VStack(alignment: .leading, spacing: JournalTheme.Spacing.regular) {
                        TextField("제목", text: $draft.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(
                                .system(
                                    size: 32 * editorTextScale,
                                    weight: .bold
                                )
                            )
                            .foregroundStyle(JournalTheme.ink)
                            .focused($focusedField, equals: .title)
                            .accessibilityLabel("제목")

                        // A prayer note keeps its 기도제목 checklist in focus
                        // mode — the checklist is part of the writing itself.
                        if !isFocusMode || draft.kind.builtIn == .prayer {
                            typeSpecificFields
                        }

                        MarkdownBodyEditor(
                            text: $draft.body,
                            minHeight: 320,
                            autoFocus: entry == nil,
                            storeImageAttachment: { data, name, mime in
                                guard let targetID = persistedEntryID ?? ensurePersistedEntryID()
                                else { return nil }
                                return await model.addAttachment(
                                    data: data,
                                    originalName: name,
                                    mimeType: mime,
                                    to: targetID
                                )
                            },
                            attachmentImage: { id in model.attachmentData(for: id) },
                            attachmentRevision: model.attachmentRevision,
                            showsChrome: !isFocusMode
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if !isFocusMode {
                            Rectangle()
                                .fill(JournalTheme.separator)
                                .frame(height: 1)

                            tagsEditor
                            AttachmentEditorSection(
                                entryID: persistedEntryID,
                                ensureEntryID: ensurePersistedEntryID
                            )
                            editorFooter
                        } else if case .failed = saveState {
                            saveStatusButton
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .background(isFocusMode ? JournalTheme.paper : JournalTheme.canvas)
        .onChange(of: draft) { _, newValue in
            bodyCharacterCount = newValue.body.count
            scheduleAutosave()
        }
        .onChange(of: tagsText) { _, _ in scheduleAutosave() }
        .onChange(of: tagInputDraft) { _, _ in scheduleAutosave() }
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
        // A kind deletion or reconcile moved this entry (new kind, carried-over
        // details in the body). AppModel flushed this editor first, so nothing
        // unsaved is lost; without the reload the next keystroke would save the
        // old kind and body back over the move.
        .onChange(of: model.editorReloadRequest) { _, request in
            guard let request, let id = persistedEntryID ?? entry?.id,
                request.entryIDs.contains(id)
            else { return }
            resyncDraftFromRepository()
        }
        .sheet(isPresented: $isPresentingHistory) {
            if let entry {
                RevisionHistoryView(entry: entry, onRestore: resyncDraftFromRepository)
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
            ForEach(model.kindPickerOptions(including: draft.kind), id: \.kind) {
                definition in
                Text(definition.displayName).tag(definition.kind)
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
    }

    @ViewBuilder
    private var typeSpecificFields: some View {
        switch draft.kind.builtIn {
        case .prayer?:
            PrayerTopicChecklistEditor(
                topics: prayerTopicsBinding, categories: prayerCategoriesBinding)
        case .bibleStudy?:
            TextField("성경 구절", text: optionalBinding(\.scriptureReference))
                .journalMetadataField()
        case .reading?:
            HStack {
                TextField("책 제목", text: optionalBinding(\.bookTitle))
                    .journalMetadataField()
                TextField("저자", text: optionalBinding(\.bookAuthor))
                    .journalMetadataField()
            }
        case .diary?:
            TextField("오늘의 기분", text: optionalBinding(\.mood))
                .journalMetadataField()
        case .memo?:
            EmptyView()
        default:
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

    private var prayerTopicsBinding: Binding<[PrayerTopic]> {
        Binding(
            get: { draft.details.prayerTopics ?? [] },
            set: { draft.details.prayerTopics = $0.isEmpty ? nil : $0 }
        )
    }

    private var prayerCategoriesBinding: Binding<[String]> {
        Binding(
            get: { draft.details.prayerCategories ?? [] },
            set: { draft.details.prayerCategories = $0.isEmpty ? nil : $0 }
        )
    }

    private var discardedDetailLabels: [String] {
        var labels: [String] = []
        guard let pendingKind else { return labels }
        let details = draft.details
        if pendingKind != .prayer,
            details.prayerStatus != nil || details.answeredAt != nil
                || !(details.prayerTopics ?? []).isEmpty
                || !(details.prayerCategories ?? []).isEmpty
        {
            labels.append(String(localized: "기도제목·기도 상태"))
        }
        if pendingKind != .bibleStudy,
            !(details.scriptureReference ?? "").isEmpty
        {
            labels.append(String(localized: "성경 구절"))
        }
        if pendingKind != .reading,
            !(details.bookTitle ?? "").isEmpty || !(details.bookAuthor ?? "").isEmpty
        {
            labels.append(String(localized: "책 제목·저자"))
        }
        if pendingKind != .diary, !(details.mood ?? "").isEmpty {
            labels.append(String(localized: "기분"))
        }
        return labels
    }

    /// Tags already committed to `tagsText` — these, and only these, render
    /// as chips.
    private var committedTags: [String] {
        Self.parseTags(tagsText)
    }

    /// Committed tags plus whatever's currently typed but not yet
    /// comma/Return-committed — this is what actually gets saved, so
    /// autosave never requires a trailing comma to pick up the tag you're
    /// mid-typing.
    private var parsedTags: [String] {
        Self.mergingTag(tagInputDraft, into: committedTags)
    }

    private static func parseTags(_ text: String) -> [String] {
        var result: [String] = []
        let candidates =
            text
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

    private static func mergingTag(_ tag: String, into tags: [String]) -> [String] {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return tags }
        return tags + [trimmed]
    }

    /// Commits `tagInputDraft` (and anything else typed up to a trailing
    /// comma) into `tagsText`, then clears the field — a tag disappears
    /// from the raw text the moment it's finished, leaving only its chip.
    private func commitTagInput(_ rawValue: String) {
        let pieces = rawValue.split(separator: ",", omittingEmptySubsequences: false)
        let completed = pieces.dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !completed.isEmpty {
            var merged = committedTags
            for tag in completed {
                merged = Self.mergingTag(tag, into: merged)
            }
            tagsText = merged.joined(separator: ", ")
        }
        tagInputDraft = String(pieces.last ?? "")
    }

    private func commitCurrentTagInputDraft() {
        guard !tagInputDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        tagsText = Self.mergingTag(tagInputDraft, into: committedTags)
            .joined(separator: ", ")
        tagInputDraft = ""
    }

    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            Text("태그")
                .font(.caption.weight(.semibold))
                .foregroundStyle(JournalTheme.inkSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: JournalTheme.Spacing.small) {
                    ForEach(committedTags, id: \.self) { tag in
                        TagChip(tag: tag) { removeTag(tag) }
                    }
                    TextField(
                        "태그 추가 (쉼표로 구분)",
                        text: Binding(
                            get: { tagInputDraft },
                            set: { commitTagInput($0) }
                        )
                    )
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .tags)
                    .onSubmit { commitCurrentTagInputDraft() }
                    // Fixed, not minWidth: a TextField's intrinsic
                    // width otherwise grows with its text content, so
                    // every keystroke changed this HStack's total
                    // width — inside a horizontal ScrollView, that
                    // forces a content-size relayout on every
                    // keystroke, which can interrupt an in-progress
                    // IME composition (Korean input showing as
                    // uncombined jamo instead of composed syllables).
                    .frame(width: 190)
                }
            }
        }
    }

    private var editorFooter: some View {
        HStack(spacing: JournalTheme.Spacing.medium) {
            Label("\(bodyCharacterCount)자", systemImage: "character.cursor.ibeam")
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
        tagsText =
            committedTags
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
        draft != lastSavedDraft
            || tagsText != lastSavedTagsText
            || tagInputDraft != lastSavedTagInputDraft
    }

    private func scheduleAutosave() {
        guard isDirty else { return }
        // `trimmingCharacters(in:).isEmpty` allocates a full trimmed copy of
        // the body just to answer a yes/no question; `contains(where:)`
        // short-circuits at the first non-whitespace character instead (the
        // common case, since content is usually near the start).
        let hasContent =
            draft.title.contains { !$0.isWhitespace }
            || draft.body.contains { !$0.isWhitespace }
            || draft.details.hasPrayerChecklistContent
        guard hasContent || persistedEntryID != nil || draft.id != nil else {
            autosaveTask?.cancel()
            saveState = .saved
            return
        }
        autosaveTask?.cancel()
        // Reassigning `.saving` to itself on every keystroke still forces a
        // SwiftUI re-render of this whole editor (state writes aren't
        // diffed against the current value) — while continuously typing,
        // this was doubling every render the body-length/binding-echo path
        // already causes. Only the *first* keystroke after becoming dirty
        // needs to flip the state.
        if saveState != .saving { saveState = .saving }
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: EditorTiming.autosaveDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            performAutosave()
        }
    }

    /// `force` skips the `isDirty`/`hasContent` guards — needed when a
    /// caller (attachment paste/picker/drag-drop) needs an entry to exist
    /// *right now* so it can attach a file, even on an otherwise-untouched
    /// blank new entry that wouldn't normally trigger an autosave yet.
    private func performAutosave(force: Bool = false) {
        guard !model.isEntryDeleted(persistedEntryID ?? draft.id) else {
            saveState = .saved
            return
        }
        guard force || isDirty else {
            saveState = .saved
            return
        }
        // `trimmingCharacters(in:).isEmpty` allocates a full trimmed copy of
        // the body just to answer a yes/no question; `contains(where:)`
        // short-circuits at the first non-whitespace character instead (the
        // common case, since content is usually near the start).
        let hasContent =
            draft.title.contains { !$0.isWhitespace }
            || draft.body.contains { !$0.isWhitespace }
            || draft.details.hasPrayerChecklistContent
        guard force || hasContent || persistedEntryID != nil || draft.id != nil else {
            autosaveTask?.cancel()
            saveState = .saved
            return
        }
        autosaveTask?.cancel()
        saveState = .saving
        var outgoing = draft
        outgoing.id = persistedEntryID ?? outgoing.id
        outgoing.tags = NotebookTagCodec.replacingVisibleTags(
            in: draft.tags,
            with: parsedTags
        )
        guard
            let record = model.saveAndReturnRecord(
                outgoing,
                closeEditor: false,
                selectSavedEntry: false
            )
        else {
            saveState = .failed(model.errorMessage ?? String(localized: "기록을 저장할 수 없습니다."))
            return
        }
        persistedEntryID = record.id
        lastSavedDraft = draft
        lastSavedTagsText = tagsText
        lastSavedTagInputDraft = tagInputDraft
        lastSavedAt = record.updatedAt
        saveState = .saved
    }

    private func ensurePersistedEntryID() -> UUID? {
        performAutosave(force: persistedEntryID == nil)
        return persistedEntryID
    }

    private func applyPendingKind() {
        guard let pendingKind else { return }
        draft.kind = pendingKind
        draft.details = (try? draft.details.validated(for: pendingKind)) ?? EntryDetails()
        self.pendingKind = nil
    }

    /// `draft` is only seeded from `entry` once, in `init`, and the editor
    /// keeps the same SwiftUI identity (`.id(entry.id)`) across a revision
    /// restore or a kind move. Without this, the sidebar reflects the new
    /// content but the open editor keeps showing (and saving) the old draft.
    private func resyncDraftFromRepository() {
        guard let id = persistedEntryID ?? entry?.id,
            let latest = model.entryRecord(id: id)
        else { return }
        autosaveTask?.cancel()
        let initial = latest.draft
        draft = initial
        tagsText = initial.visibleTags.joined(separator: ", ")
        tagInputDraft = ""
        lastSavedDraft = initial
        lastSavedTagsText = tagsText
        lastSavedTagInputDraft = tagInputDraft
        lastSavedAt = latest.updatedAt
        saveState = .saved
    }
}
#endif
