import JournalDomain
import SwiftUI

#if os(macOS)
struct InlineEntryEditorView: View {
    private enum FocusedField: Hashable {
        case title
        case tags
    }

    @EnvironmentObject private var model: AppModel
    @FocusState private var focusedField: FocusedField?
    @State private var draft: JournalEntryDraft
    @State private var tagsText: String
    @State private var lastSavedDraft: JournalEntryDraft
    @State private var lastSavedTagsText: String
    @State private var pendingKind: JournalKind?
    @State private var isConfirmingTypeChange = false
    @State private var isPresentingHistory = false
    private let entry: JournalEntryRecord?

    init(entry: JournalEntryRecord?, defaultKind: JournalKind = .diary) {
        let initial = entry?.draft ?? JournalEntryDraft(kind: defaultKind)
        let initialTags = initial.tags.joined(separator: ", ")
        self.entry = entry
        _draft = State(initialValue: initial)
        _tagsText = State(initialValue: initialTags)
        _lastSavedDraft = State(initialValue: initial)
        _lastSavedTagsText = State(initialValue: initialTags)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                TextField("제목", text: $draft.title)
                    .textFieldStyle(.plain)
                    .font(.largeTitle.bold())
                    .focused($focusedField, equals: .title)
                    .accessibilityLabel("제목")

                typeSpecificFields

                MarkdownBodyEditor(
                    text: $draft.body,
                    minHeight: 280,
                    autoFocus: entry == nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                HStack(spacing: 8) {
                    Image(systemName: "number")
                        .foregroundStyle(.secondary)
                    TextField("태그를 쉼표로 구분해 입력", text: $tagsText)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .tags)
                }
            }
            .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDisappear {
            guard isDirty else { return }
            var outgoing = draft
            outgoing.tags = parsedTags
            model.autosaveOnEditorExit(outgoing)
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
        HStack(spacing: 12) {
            Picker("기록 유형", selection: kindBinding) {
                ForEach(JournalKind.allCases.filter(\.canCreateManually)) { kind in
                    Text(kind.localizedName).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            DatePicker(
                "기록 시각",
                selection: $draft.occurredAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .fixedSize()

            Spacer()

            Button {
                draft.isStarred.toggle()
            } label: {
                Label(
                    draft.isStarred ? "즐겨찾기 해제" : "즐겨찾기",
                    systemImage: draft.isStarred ? "star.fill" : "star"
                )
            }
            .labelStyle(.iconOnly)

            Button {
                draft.isPinned.toggle()
            } label: {
                Label(
                    draft.isPinned ? "고정 해제" : "고정",
                    systemImage: draft.isPinned ? "pin.fill" : "pin"
                )
            }
            .labelStyle(.iconOnly)

            if entry != nil {
                Button {
                    isPresentingHistory = true
                } label: {
                    Label("수정 이력", systemImage: "clock.arrow.circlepath")
                }
                .labelStyle(.iconOnly)
            }

            if isDirty {
                Text("저장 안 됨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("저장") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!isDirty && entry != nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
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
                .textFieldStyle(.roundedBorder)
        case .reading:
            HStack {
                TextField("책 제목", text: optionalBinding(\.bookTitle))
                TextField("저자", text: optionalBinding(\.bookAuthor))
            }
            .textFieldStyle(.roundedBorder)
        case .diary:
            TextField("오늘의 기분", text: optionalBinding(\.mood))
                .textFieldStyle(.roundedBorder)
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
        tagsText
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var isDirty: Bool {
        draft != lastSavedDraft || tagsText != lastSavedTagsText
    }

    private func save() {
        var outgoing = draft
        outgoing.tags = parsedTags
        guard model.save(outgoing) else { return }
        draft = outgoing
        lastSavedDraft = outgoing
        lastSavedTagsText = tagsText
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
                HStack {
                    Text(entry.kind.localizedName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.tint.opacity(0.12), in: Capsule())
                    Spacer()
                    Button("편집") {
                        model.beginEditing(entry)
                    }
                    Button("이력") {
                        isPresentingHistory = true
                    }
                }
                Text(entry.title.isEmpty ? entry.kind.localizedName : entry.title)
                    .font(.largeTitle.bold())
                Text(entry.occurredAt.formatted(date: .long, time: .shortened))
                    .foregroundStyle(.secondary)
                typeDetails
                MarkdownPreviewView(markdown: entry.body)
                if !entry.tags.isEmpty {
                    HStack {
                        ForEach(entry.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
        }
        .sheet(isPresented: $isPresentingHistory) {
            RevisionHistoryView(entry: entry)
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
    @State private var pendingKind: JournalKind?
    @State private var isConfirmingTypeChange = false
    @State private var isConfirmingDiscard = false
    private let initialDraft: JournalEntryDraft
    private let initialTagsText: String

    init(entry: JournalEntryRecord?) {
        let initial = entry?.draft ?? JournalEntryDraft(kind: .diary)
        initialDraft = initial
        initialTagsText = initial.tags.joined(separator: ", ")
        _draft = State(initialValue: initial)
        _tagsText = State(initialValue: initialTagsText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("기록 유형", selection: kindBinding) {
                    ForEach(JournalKind.allCases.filter(\.canCreateManually)) { kind in
                        Text(kind.localizedName).tag(kind)
                    }
                }
                TextField("제목", text: $draft.title)
                DatePicker("기록 시각", selection: $draft.occurredAt)
                MarkdownBodyEditor(text: $draft.body)
                TextField("태그 (쉼표로 구분)", text: $tagsText)
                Toggle("즐겨찾기", isOn: $draft.isStarred)
                Toggle("고정", isOn: $draft.isPinned)
                typeSpecificFields
            }
            .formStyle(.grouped)
            .navigationTitle(draft.id == nil ? "새 기록" : "기록 편집")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") {
                        if isDirty {
                            isConfirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        draft.tags = tagsText
                            .split(separator: ",")
                            .map { String($0).trimmingCharacters(in: .whitespaces) }
                        if model.save(draft) {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 520)
        #endif
        .interactiveDismissDisabled(isDirty)
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
        .confirmationDialog(
            "저장하지 않은 변경을 버릴까요?",
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("변경 버리기", role: .destructive) { dismiss() }
            Button("계속 편집", role: .cancel) {}
        }
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
        case .reading:
            TextField("책 제목", text: optionalBinding(\.bookTitle))
            TextField("저자", text: optionalBinding(\.bookAuthor))
        case .diary:
            TextField("기분", text: optionalBinding(\.mood))
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
        draft != initialDraft || tagsText != initialTagsText
    }

    private func applyPendingKind() {
        guard let pendingKind else { return }
        draft.kind = pendingKind
        draft.details = (try? draft.details.validated(for: pendingKind)) ?? EntryDetails()
        self.pendingKind = nil
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
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title.isEmpty ? entry.kind.localizedName : entry.title)
                            .font(.headline)
                        if let deletedAt = entry.deletedAt {
                            Text("삭제 \(deletedAt.formatted())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("복원") {
                        model.restoreFromTrash(entry)
                    }
                }
            }
            .overlay {
                if model.trashEntries.isEmpty {
                    ContentUnavailableView("휴지통이 비었습니다", systemImage: "trash")
                }
            }
            .navigationTitle("휴지통")
            .toolbar {
                Button("닫기") { dismiss() }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
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
