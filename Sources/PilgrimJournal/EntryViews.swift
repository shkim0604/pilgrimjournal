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
    @AppStorage("editor-text-scale") private var editorTextScale =
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
        _bodyCharacterCount = State(initialValue: initial.body.count)
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
                            attachmentRevision: model.attachmentRevision
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
        let candidates = text
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
        tagsText = committedTags
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
        let hasContent = draft.title.contains { !$0.isWhitespace }
            || draft.body.contains { !$0.isWhitespace }
        guard hasContent else { return }
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
                try await Task.sleep(for: .milliseconds(650))
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
        let hasContent = draft.title.contains { !$0.isWhitespace }
            || draft.body.contains { !$0.isWhitespace }
        guard force || hasContent else { return }
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
    /// restore. Without this, the sidebar reflects the restored content but
    /// the open editor keeps showing the pre-restore draft.
    private func resyncDraftFromRepository() {
        guard let id = persistedEntryID ?? entry?.id,
              let latest = try? model.repository.entry(id: id) else { return }
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
    @State private var saveState = EditorSaveState.saved
    @State private var lastSavedAt: Date?
    @State private var autosaveTask: Task<Void, Never>?
    @State private var persistedEntryID: UUID?
    @State private var pendingKind: JournalKind?
    @State private var isConfirmingTypeChange = false
    @State private var isShowingMetadata = false
    // See the matching field on InlineEntryEditorView (macOS).
    @State private var bodyCharacterCount: Int

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
        _bodyCharacterCount = State(initialValue: initial.body.count)
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

                        MarkdownBodyEditor(
                            text: $draft.body,
                            minHeight: 380,
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
                            attachmentRevision: model.attachmentRevision
                        )

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
        .onChange(of: draft) { _, newValue in
            bodyCharacterCount = newValue.body.count
            scheduleAutosave()
        }
        .onChange(of: tagsText) { _, _ in scheduleAutosave() }
        .onChange(of: tagInputDraft) { _, _ in scheduleAutosave() }
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
                    ForEach(committedTags, id: \.self) { tag in
                        TagChip(tag: tag) { removeTag(tag) }
                    }
                    TextField(
                        "태그 추가",
                        text: Binding(
                            get: { tagInputDraft },
                            set: { commitTagInput($0) }
                        )
                    )
                        .textFieldStyle(.plain)
                        .onSubmit { commitCurrentTagInputDraft() }
                        // See the matching comment on the macOS tagsEditor.
                        .frame(width: 140)
                }
            }
        }
    }

    private var mobileFooter: some View {
        HStack {
            Label("\(bodyCharacterCount)자", systemImage: "character.cursor.ibeam")
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
        draft != lastSavedDraft
            || tagsText != lastSavedTagsText
            || tagInputDraft != lastSavedTagInputDraft
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
        let candidates = text
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

    private func removeTag(_ tag: String) {
        tagsText = committedTags
            .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            .joined(separator: ", ")
    }

    private func scheduleAutosave() {
        guard isDirty else { return }
        // `trimmingCharacters(in:).isEmpty` allocates a full trimmed copy of
        // the body just to answer a yes/no question; `contains(where:)`
        // short-circuits at the first non-whitespace character instead (the
        // common case, since content is usually near the start).
        let hasContent = draft.title.contains { !$0.isWhitespace }
            || draft.body.contains { !$0.isWhitespace }
        guard hasContent else { return }
        autosaveTask?.cancel()
        // See the matching comment on the macOS editor's scheduleAutosave —
        // reassigning `.saving` to itself on every keystroke still forces a
        // full re-render of this editor.
        if saveState != .saving { saveState = .saving }
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

    /// `force` skips the `isDirty`/`hasContent` guards — needed when a
    /// caller (attachment paste/picker/drag-drop) needs an entry to exist
    /// *right now* so it can attach a file, even on an otherwise-untouched
    /// blank new entry that wouldn't normally trigger an autosave yet.
    @discardableResult
    private func performAutosave(force: Bool = false) -> Bool {
        guard !model.isEntryDeleted(persistedEntryID ?? draft.id) else {
            saveState = .saved
            return true
        }
        guard force || isDirty else {
            saveState = .saved
            return true
        }
        // `trimmingCharacters(in:).isEmpty` allocates a full trimmed copy of
        // the body just to answer a yes/no question; `contains(where:)`
        // short-circuits at the first non-whitespace character instead (the
        // common case, since content is usually near the start).
        let hasContent = draft.title.contains { !$0.isWhitespace }
            || draft.body.contains { !$0.isWhitespace }
        guard force || hasContent else {
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
        lastSavedTagInputDraft = tagInputDraft
        lastSavedAt = record.updatedAt
        saveState = .saved
        return true
    }

    private func ensurePersistedEntryID() -> UUID? {
        guard performAutosave(force: persistedEntryID == nil) else { return nil }
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

#if os(iOS)
private struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
#endif

private struct AttachmentEditorSection: View {
    @EnvironmentObject private var model: AppModel
    let entryID: UUID?
    let ensureEntryID: () -> UUID?
    var allowsImport = true
    @State private var attachments: [AttachmentRecord] = []
    @State private var isImporting = false
    @State private var isPresentingPhotoPicker = false
    @State private var photoPickerSelection: [PhotosPickerItem] = []
    #if os(iOS)
    @State private var previewURL: URL?
    @State private var isPresentingCamera = false
    #endif
    @State private var exportDocument: AttachmentDocument?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "attachment"
    @State private var isExporting = false
    @State private var pendingDelete: AttachmentRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            HStack {
                Text("첨부")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JournalTheme.inkSecondary)
                Spacer()
                if allowsImport {
                    HStack(spacing: JournalTheme.Spacing.small) {
                        Button {
                            requireEntryThenRun { isImporting = true }
                        } label: {
                            Label("파일", systemImage: "paperclip")
                        }
                        .buttonStyle(.borderless)

                        Button {
                            requireEntryThenRun { isPresentingPhotoPicker = true }
                        } label: {
                            Label("사진", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.borderless)

                        #if os(iOS)
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                requireEntryThenRun { isPresentingCamera = true }
                            } label: {
                                Label("촬영", systemImage: "camera")
                            }
                            .buttonStyle(.borderless)
                        }
                        #endif
                    }
                }
            }

            if attachments.isEmpty {
                Text("첨부 파일 없음")
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
            } else {
                // Capped so a record with many attachments scrolls inside
                // this section instead of pushing tags/footer far down the
                // outer editor scroll view.
                ScrollView {
                    VStack(spacing: JournalTheme.Spacing.small) {
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
                                Button(role: .destructive) {
                                    pendingDelete = attachment
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("첨부 삭제")
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                .frame(maxHeight: 240)
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
                Task {
                    if await model.addAttachment(from: url, to: targetID) {
                        attachments = model.attachments(for: targetID)
                    }
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .photosPicker(
            isPresented: $isPresentingPhotoPicker,
            selection: $photoPickerSelection,
            maxSelectionCount: 0,
            matching: .images
        )
        .onChange(of: photoPickerSelection) { _, newValue in
            guard !newValue.isEmpty else { return }
            importPhotoPickerSelection(newValue)
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isPresentingCamera) {
            CameraCaptureView(
                onCapture: { image in
                    isPresentingCamera = false
                    importCapturedPhoto(image)
                },
                onCancel: { isPresentingCamera = false }
            )
            .ignoresSafeArea()
        }
        #endif
        .onAppear { attachments = model.attachments(for: entryID) }
        .onChange(of: entryID) { _, newValue in
            attachments = model.attachments(for: newValue)
        }
        .onChange(of: model.attachmentRevision) { _, _ in
            attachments = model.attachments(for: entryID)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result,
               (error as NSError).code != NSUserCancelledError {
                model.errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
        .confirmationDialog(
            "이 첨부를 삭제할까요?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let attachment = pendingDelete {
                    model.deleteAttachment(attachment.id)
                }
                pendingDelete = nil
            }
            Button("취소", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("이 기기와 iCloud에서 완전히 지워지며 되돌릴 수 없습니다.")
        }
    }

    private func requireEntryThenRun(_ action: () -> Void) {
        guard entryID != nil || ensureEntryID() != nil else {
            model.errorMessage = "첨부 전에 제목이나 본문을 입력해 기록을 저장해 주세요."
            return
        }
        action()
    }

    /// Photos from the library can be tens of megabytes at full resolution
    /// (HEIC, ProRAW-adjacent JPEGs). Only large images are recompressed —
    /// small ones (typically pasted screenshots elsewhere in the editor)
    /// pass through untouched so text stays crisp.
    private nonisolated static let compressionSizeThreshold = 3 * 1024 * 1024
    private nonisolated static let compressionMaxDimension: CGFloat = 2048
    private nonisolated static let compressionQuality: CGFloat = 0.85

    private func importPhotoPickerSelection(_ items: [PhotosPickerItem]) {
        guard let targetID = entryID ?? ensureEntryID() else {
            model.errorMessage = "첨부할 기록을 먼저 저장해 주세요."
            photoPickerSelection = []
            return
        }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    continue
                }
                let contentType = item.supportedContentTypes.first
                let isImage = contentType?.conforms(to: .image) ?? true
                var uploadData = data
                var fileExtension = contentType?.preferredFilenameExtension ?? "jpg"
                var mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
                if isImage, data.count > Self.compressionSizeThreshold {
                    let compressed = await Task.detached(priority: .userInitiated) {
                        Self.compressedForUpload(data)
                    }.value
                    if let compressed {
                        uploadData = compressed
                        fileExtension = "jpg"
                        mimeType = "image/jpeg"
                    }
                }
                await model.addAttachment(
                    data: uploadData,
                    originalName: "\(UUID().uuidString).\(fileExtension)",
                    mimeType: mimeType,
                    to: targetID
                )
            }
            attachments = model.attachments(for: targetID)
            photoPickerSelection = []
        }
    }

    #if os(iOS)
    private func importCapturedPhoto(_ image: UIImage) {
        guard let targetID = entryID ?? ensureEntryID() else {
            model.errorMessage = "첨부할 기록을 먼저 저장해 주세요."
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        Task {
            let uploadData: Data
            if data.count > Self.compressionSizeThreshold {
                uploadData = await Task.detached(priority: .userInitiated) {
                    Self.compressedForUpload(data)
                }.value ?? data
            } else {
                uploadData = data
            }
            await model.addAttachment(
                data: uploadData,
                originalName: "\(UUID().uuidString).jpg",
                mimeType: "image/jpeg",
                to: targetID
            )
            attachments = model.attachments(for: targetID)
        }
    }
    #endif

    /// Decodes, downscales to `compressionMaxDimension` on the longest side
    /// (no upscaling), and re-encodes as JPEG. Called off the main actor —
    /// decoding and re-encoding a large image is itself not free.
    private nonisolated static func compressedForUpload(_ data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > compressionMaxDimension
            ? compressionMaxDimension / longestSide
            : 1
        let targetSize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: compressionQuality)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        let scale = longestSide > compressionMaxDimension
            ? compressionMaxDimension / longestSide
            : 1
        let targetSize = NSSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
        #endif
    }

    private func openAttachment(_ attachment: AttachmentRecord) {
        guard let url = model.temporaryPreviewURL(for: attachment.id) else { return }
        #if os(iOS)
        previewURL = url
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private func beginExport(_ attachment: AttachmentRecord) {
        guard let data = model.attachmentData(for: attachment.id) else { return }
        exportDocument = AttachmentDocument(data: data)
        exportContentType = UTType(mimeType: attachment.mimeType) ?? .data
        let name = attachment.originalName.isEmpty ? "첨부파일" : attachment.originalName
        exportFilename = (name as NSString).deletingPathExtension.isEmpty
            ? name
            : (name as NSString).deletingPathExtension
        isExporting = true
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
        case .uploading: "iCloud 업로드 중"
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
        } else if attachment.state == .downloading {
            AttachmentDownloadStatusView(attachment: attachment)
        } else if attachment.state == .pending || attachment.state == .uploading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(attachmentStatus(attachment))
        } else if !model.hasLocalBinary(for: attachment.id) {
            Button("다운로드") {
                model.requestAttachmentDownload(attachment.id)
            }
            .buttonStyle(.bordered)
        } else {
            HStack(spacing: JournalTheme.Spacing.small) {
                Button {
                    openAttachment(attachment)
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("미리보기")

                Button {
                    beginExport(attachment)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("다른 위치에 저장")
            }
        }
    }
}

/// CloudKit has no public API to force-fetch a single record's asset, so a
/// requested download can only wait for the framework's own background
/// import. This surfaces that honestly instead of spinning forever: while an
/// import operation is actually running (`model.isCloudImportInProgress`) it
/// keeps waiting, otherwise it gives up after a timeout and offers "재시도".
private struct AttachmentDownloadStatusView: View {
    @EnvironmentObject private var model: AppModel
    let attachment: AttachmentRecord
    @State private var timedOut = false

    private static let timeout: Duration = .seconds(25)

    var body: some View {
        Group {
            if timedOut {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("iCloud에서 받아오지 못했습니다")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Button("재시도") {
                        model.retryAttachmentTransfer(attachment.id)
                    }
                    .buttonStyle(.bordered)
                }
            } else if model.isCloudImportInProgress {
                Label("동기화 진행 중", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(JournalTheme.inkSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("다운로드 중")
            }
        }
        .task(id: attachment.updatedAt) {
            timedOut = false
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.timeout)
                guard !Task.isCancelled else { return }
                if model.isCloudImportInProgress { continue }
                timedOut = true
                return
            }
        }
    }
}

struct RevisionHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntryRecord
    var onRestore: (() -> Void)?

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
                            onRestore?()
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
    @State private var selection = Set<UUID>()
    @State private var isConfirmingPurge = false
    @State private var isConfirmingEmptyTrash = false
    #if os(iOS)
    @State private var editMode: EditMode = .active
    #endif

    var body: some View {
        NavigationStack {
            List(model.trashEntries, selection: $selection) { entry in
                trashEntryDescription(entry)
                    .tag(entry.id)
            }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            #if os(macOS)
            .onDeleteCommand {
                guard !selection.isEmpty else { return }
                isConfirmingPurge = true
            }
            #endif
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
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.restoreFromTrash(ids: selection)
                        selection.removeAll()
                    } label: {
                        Label(
                            selection.isEmpty ? "복원" : "복원 \(selection.count)",
                            systemImage: "arrow.uturn.backward"
                        )
                    }
                    .disabled(selection.isEmpty)

                    Button(role: .destructive) {
                        isConfirmingPurge = true
                    } label: {
                        Label(
                            selection.isEmpty ? "영구 삭제" : "영구 삭제 \(selection.count)",
                            systemImage: "trash.slash"
                        )
                    }
                    .disabled(selection.isEmpty)

                    Button("휴지통 비우기", role: .destructive) {
                        isConfirmingEmptyTrash = true
                    }
                    .disabled(model.trashEntries.isEmpty)
                }
            }
        }
        .onAppear { model.refreshTrash() }
        #if os(macOS)
        // 4 labeled toolbar buttons (닫기/복원/영구 삭제/휴지통 비우기) don't
        // fit at 460pt — macOS silently collapses the low-priority ones into
        // an overflow chevron, which reads as "the delete button vanished"
        // rather than "click the >> to find it". Wide enough that all four
        // always render inline.
        .frame(minWidth: 640, minHeight: 420)
        #endif
        .confirmationDialog(
            selection.count > 1
                ? "선택한 \(selection.count)개 기록을 영구히 삭제할까요?"
                : "이 기록을 영구히 삭제할까요?",
            isPresented: $isConfirmingPurge,
            titleVisibility: .visible
        ) {
            Button("영구 삭제", role: .destructive) {
                model.permanentlyDelete(ids: selection)
                selection.removeAll()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("기록과 수정 이력, 첨부가 이 기기와 iCloud에서 완전히 지워집니다. 되돌릴 수 없습니다.")
        }
        .confirmationDialog(
            "휴지통을 비울까요?",
            isPresented: $isConfirmingEmptyTrash,
            titleVisibility: .visible
        ) {
            Button("휴지통 비우기", role: .destructive) {
                model.emptyTrash()
                selection.removeAll()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(
                "휴지통의 \(model.trashEntries.count)개 기록과 수정 이력, 첨부가 이 기기와 "
                    + "iCloud에서 완전히 지워집니다. 되돌릴 수 없습니다. 다른 기기가 동기화된 "
                    + "뒤에 실행하세요."
            )
        }
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
