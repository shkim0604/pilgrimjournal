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

/// Which parts of the iPhone entry editor stay on screen.
///
/// Focus mode (집중 모드) keeps only the title and the body. The body's text
/// view is deliberately not part of this: it stays mounted in both layouts,
/// so switching can never re-create it mid-typing and drop keystrokes (see
/// the editor input section of docs/known-issues.md).
struct EntryEditorFocusLayout: Equatable {
    /// 완료 and the save status pill.
    var showsNavigationBar: Bool
    /// Metadata chips, tags, attachments and footer.
    var showsEntryDetails: Bool
    /// The kind-specific block above the body. A prayer note keeps its
    /// 기도제목 checklist even in focus mode — the checklist IS the writing.
    var showsTypeSpecificFields: Bool
    /// The body editor's Markdown menu row and its slash-command hint.
    var showsMarkdownChrome: Bool
    /// The corner button that leaves focus mode while the keyboard is down.
    var showsExitButton: Bool
    /// A failed save must stay visible once the status pill is hidden.
    var showsSaveFailure: Bool

    init(isFocusMode: Bool, saveState: EditorSaveState, isPrayerNote: Bool = false) {
        showsNavigationBar = !isFocusMode
        showsEntryDetails = !isFocusMode
        showsTypeSpecificFields = !isFocusMode || isPrayerNote
        showsMarkdownChrome = !isFocusMode
        showsExitButton = isFocusMode
        if isFocusMode, case .failed = saveState {
            showsSaveFailure = true
        } else {
            showsSaveFailure = false
        }
    }
}

#if os(iOS)
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
    /// Per editor session on purpose: every open starts in the normal layout,
    /// so tags and kind are never hidden by a mode the user forgot about.
    @State private var isFocusMode = false
    // See the matching field on InlineEntryEditorView (macOS).
    @State private var bodyCharacterCount: Int
    /// Photos added with 사진/촬영/파일 or the keyboard bar go into the body
    /// at its caret through this, not only into the 첨부 list.
    @State private var bodyImageInserter = MarkdownImageInserter()
    /// A photo asked for from the keyboard bar or the body's edit menu; the
    /// 첨부 section presents the picker or camera and stores the result.
    @State private var photoRequest: AttachmentPhotoSource?
    /// The keyboard bar's 📷 asks 사진 보관함 or 촬영 first.
    @State private var isChoosingPhotoSource = false

    private var focusLayout: EntryEditorFocusLayout {
        EntryEditorFocusLayout(
            isFocusMode: isFocusMode,
            saveState: saveState,
            isPrayerNote: draft.kind.builtIn == .prayer
        )
    }

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
                    // Focus mode only wraps the body's siblings in `if`, so
                    // the body editor keeps its structural identity and its
                    // text view, caret and in-flight input survive a toggle.
                    VStack(alignment: .leading, spacing: JournalTheme.Spacing.regular) {
                        if focusLayout.showsEntryDetails {
                            mobileMetadataBar
                        }

                        TextField("제목", text: $draft.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.largeTitle.bold())
                            .foregroundStyle(JournalTheme.ink)
                            .accessibilityLabel("제목")

                        if focusLayout.showsTypeSpecificFields {
                            typeSpecificFields
                        }

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
                            attachmentRevision: model.attachmentRevision,
                            showsChrome: focusLayout.showsMarkdownChrome,
                            imageInserter: bodyImageInserter,
                            requestImageInsertion: { photoRequest = $0 }
                        )
                        .environment(\.markdownKeyboardAccessory, keyboardAccessory)

                        if focusLayout.showsEntryDetails {
                            Rectangle()
                                .fill(JournalTheme.separator)
                                .frame(height: 1)

                            mobileTagsEditor
                        }
                        // Stays mounted in focus mode with its list hidden: it
                        // presents the picker and camera for the keyboard bar's
                        // 📷 and the body's 사진 삽입 too.
                        AttachmentEditorSection(
                            entryID: persistedEntryID,
                            ensureEntryID: ensurePersistedEntryID,
                            showsList: focusLayout.showsEntryDetails,
                            bodyImageInserter: bodyImageInserter,
                            photoRequest: $photoRequest
                        )
                        if focusLayout.showsEntryDetails {
                            mobileFooter
                        }
                    }
                    .padding(JournalTheme.Spacing.large)
                    .background(JournalTheme.paper)
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if focusLayout.showsExitButton {
                        focusModeBar
                    }
                }
            }
            .navigationTitle(draft.id == nil ? "새 기록" : "기록 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(
                focusLayout.showsNavigationBar ? .visible : .hidden,
                for: .navigationBar
            )
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
                // For the SwiftUI fields (title, type fields, tags). The body's
                // UIKit text view never gets this; it shows the same items in
                // its own toolbar (see `MarkdownKeyboardAccessory`).
                ToolbarItemGroup(placement: .keyboard) {
                    ForEach(keyboardAccessory.leading, id: \.title) { item in
                        keyboardToolbarButton(item)
                    }
                    Spacer()
                    ForEach(keyboardAccessory.trailing, id: \.title) { item in
                        keyboardToolbarButton(item)
                    }
                }
            }
        }
        .interactiveDismissDisabled(saveState != .saved)
        .sheet(isPresented: $isShowingMetadata) {
            mobileMetadataSheet
        }
        .onChange(of: draft) { _, newValue in
            bodyCharacterCount = newValue.body.count
            scheduleAutosave()
        }
        .onChange(of: tagsText) { _, _ in scheduleAutosave() }
        .onChange(of: tagInputDraft) { _, _ in scheduleAutosave() }
        .confirmationDialog("사진 넣기", isPresented: $isChoosingPhotoSource) {
            Button("사진 보관함") { photoRequest = .library }
            Button("촬영") { photoRequest = .camera }
            Button("취소", role: .cancel) {}
        }
        // AppModel flushes the open editor before a kind move, then asks it
        // to reload the moved entry — the same pair as the macOS inline
        // editor. Without them the next autosave writes the old kind and
        // body back over the move.
        .onReceive(
            NotificationCenter.default.publisher(for: .saveJournalEntry)
        ) { _ in
            autosaveTask?.cancel()
            _ = performAutosave()
        }
        .onChange(of: model.editorReloadRequest) { _, request in
            guard let request, let id = persistedEntryID,
                request.entryIDs.contains(id)
            else { return }
            resyncDraftFromRepository()
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

    /// See the macOS inline editor's `resyncDraftFromRepository`.
    private func resyncDraftFromRepository() {
        guard let id = persistedEntryID,
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

    private var mobileMetadataBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: JournalTheme.Spacing.small) {
                Button {
                    isShowingMetadata = true
                } label: {
                    MetadataChip {
                        Label(
                            model.kindDefinition(for: draft.kind).displayName,
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
                Section(
                    String(
                        localized: "entryInfo.organizeSection", defaultValue: "분류",
                        comment: "Entry info section holding the type and notebook pickers")
                ) {
                    Picker("기록 유형", selection: kindBinding) {
                        ForEach(model.kindPickerOptions(including: draft.kind), id: \.kind) {
                            definition in
                            Text(definition.displayName).tag(definition.kind)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { isShowingMetadata = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

    /// Focus mode hides the navigation bar, so this is the way out while the
    /// keyboard (and its toolbar button) is down.
    private var focusModeBar: some View {
        HStack(spacing: JournalTheme.Spacing.small) {
            if focusLayout.showsSaveFailure {
                StatusPill(state: saveState)
                Button("다시 저장") { _ = performAutosave() }
                    .font(.caption.weight(.semibold))
            }
            Spacer()
            Button {
                setFocusMode(false)
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("집중 모드 종료")
        }
        .padding(.horizontal, JournalTheme.Spacing.regular)
        .padding(.vertical, JournalTheme.Spacing.small)
        // Opaque up to the screen edge: with the navigation bar hidden,
        // scrolled text would otherwise run under the status bar clock.
        .background(JournalTheme.canvas.ignoresSafeArea(edges: .top))
    }

    /// One list for both keyboard toolbars, so the body and the other fields
    /// can't drift apart. Icons only, and at most six: more overflow a
    /// 390pt-wide iPhone.
    private var keyboardAccessory: MarkdownKeyboardAccessory {
        MarkdownKeyboardAccessory(
            leading: [
                .init(
                    title: String(
                        localized: "editor.heading", defaultValue: "제목",
                        comment: "Markdown heading command"), systemImage: "textformat.size"
                ) {
                    appendCommand(.h2)
                },
                .init(title: String(localized: "불릿"), systemImage: "list.bullet") {
                    appendCommand(.bullet)
                },
                .init(title: String(localized: "내어쓰기"), systemImage: "decrease.indent") {
                    postMarkdownCommand(.outdentList)
                },
                .init(title: String(localized: "하위 불릿"), systemImage: "increase.indent") {
                    postMarkdownCommand(.indentList)
                },
                // No 오늘 button: seven items overflow a 390pt-wide iPhone,
                // and the date is still a `/today` slash command away.
                .init(
                    title: isFocusMode
                        ? String(localized: "집중 모드 종료") : String(localized: "집중 모드"),
                    systemImage: isFocusMode
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right"
                ) {
                    setFocusMode(!isFocusMode)
                },
            ],
            // 📷 took 키보드 닫기's place: six is the limit, and dragging the
            // body down already dismisses the keyboard (`.interactive`).
            trailing: [
                .init(title: String(localized: "사진"), systemImage: "photo") {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        isChoosingPhotoSource = true
                    } else {
                        photoRequest = .library
                    }
                }
            ]
        )
    }

    private func keyboardToolbarButton(_ item: MarkdownKeyboardAccessory.Item) -> some View {
        Button(action: item.action) {
            if let systemImage = item.systemImage {
                Label(item.title, systemImage: systemImage)
            } else {
                Text(item.title)
            }
        }
    }

    private func setFocusMode(_ enabled: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            isFocusMode = enabled
        }
    }

    @ViewBuilder
    private var typeSpecificFields: some View {
        switch draft.kind.builtIn {
        case .prayer?:
            PrayerTopicChecklistEditor(
                topics: prayerTopicsBinding, categories: prayerCategoriesBinding)
        case .bibleStudy?:
            TextField(
                "성경 구절",
                text: optionalBinding(\.scriptureReference)
            )
            .journalMetadataField()
        case .reading?:
            TextField("책 제목", text: optionalBinding(\.bookTitle))
                .journalMetadataField()
            TextField("저자", text: optionalBinding(\.bookAuthor))
                .journalMetadataField()
        case .diary?:
            TextField("기분", text: optionalBinding(\.mood))
                .journalMetadataField()
        case .memo?:
            EmptyView()
        default:
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
        let candidates =
            text
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
        tagsText =
            committedTags
            .filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
            .joined(separator: ", ")
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
        // See the matching comment on the macOS editor's scheduleAutosave —
        // reassigning `.saving` to itself on every keystroke still forces a
        // full re-render of this editor.
        if saveState != .saving { saveState = .saving }
        autosaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: EditorTiming.autosaveDelay)
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
        let hasContent =
            draft.title.contains { !$0.isWhitespace }
            || draft.body.contains { !$0.isWhitespace }
            || draft.details.hasPrayerChecklistContent
        guard force || hasContent || persistedEntryID != nil || draft.id != nil else {
            autosaveTask?.cancel()
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
        guard
            let record = model.saveAndReturnRecord(
                outgoing,
                closeEditor: false,
                selectSavedEntry: false
            )
        else {
            saveState = .failed(model.errorMessage ?? String(localized: "기록을 저장할 수 없습니다."))
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

    private func postMarkdownCommand(_ command: MarkdownKeyboardCommand) {
        NotificationCenter.default.post(
            name: .applyMarkdownKeyboardCommand,
            object: command.rawValue
        )
    }

    private func applyPendingKind() {
        guard let pendingKind else { return }
        draft.kind = pendingKind
        draft.details = (try? draft.details.validated(for: pendingKind)) ?? EntryDetails()
        self.pendingKind = nil
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
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

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
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
