import JournalDomain
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Editable 기도제목 checklist with sections (카테고리) and templates, shown above
/// the body in both entry editors.
///
/// Lives inside `typeSpecificFields`, so the markdown body editor keeps its
/// structural position in the view tree (see docs/known-issues.md on editor
/// input dropping).
struct PrayerTopicChecklistEditor: View {
    @Binding var topics: [PrayerTopic]
    @Binding var categories: [String]
    @EnvironmentObject private var model: AppModel
    @FocusState private var focusedTopicID: UUID?
    @FocusState private var focusedMemoID: UUID?
    @FocusState private var focusedAnswerNoteID: UUID?
    @FocusState private var focusedCategoryIndex: Int?
    @State private var isNamingTemplate = false
    @State private var templateName = ""
    @State private var editingCategoryIndex: Int?
    @State private var editingCategoryName = ""
    @State private var draggingCategory: String?
    @State private var sectionFrames: [String: CGRect] = [:]
    /// Section midlines frozen at lift time, so the target slot is computed
    /// against stable positions instead of frames that move mid-animation.
    @State private var dragSlots: [(category: String, midY: CGFloat)] = []

    private static let reorderSpace = "prayer-section-reorder"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("기도제목")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                templateMenu
            }
            topicRows(category: nil)
            if categories.isEmpty {
                addTopicRow(category: nil)
            }
            ForEach(categories, id: \.self) { category in
                sectionGroup(for: category)
            }
            Button {
                addSection()
            } label: {
                Label("섹션 추가", systemImage: "folder.badge.plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .coordinateSpace(name: Self.reorderSpace)
        .onPreferenceChange(PrayerSectionFramesKey.self) { sectionFrames = $0 }
        .onChange(of: focusedCategoryIndex) { _, newValue in
            if newValue != editingCategoryIndex { commitCategoryRename() }
        }
        .alert("템플릿으로 저장", isPresented: $isNamingTemplate) {
            TextField("템플릿 이름", text: $templateName)
            Button("저장") {
                model.savePrayerTemplate(name: templateName, categories: categories)
                templateName = ""
            }
            Button("취소", role: .cancel) { templateName = "" }
        } message: {
            Text("현재 섹션 구성을 이름 붙여 저장합니다.")
        }
    }

    private var templateMenu: some View {
        Menu {
            if !model.prayerTemplates.isEmpty {
                Section("템플릿에서 시작") {
                    ForEach(model.prayerTemplates) { template in
                        Button(template.name) { apply(template) }
                    }
                }
            }
            Button("현재 구성을 템플릿으로 저장") {
                templateName = ""
                isNamingTemplate = true
            }
            .disabled(categories.isEmpty)
            if !model.prayerTemplates.isEmpty {
                Menu("템플릿 삭제") {
                    ForEach(model.prayerTemplates) { template in
                        Button(template.name, role: .destructive) {
                            model.deletePrayerTemplate(id: template.id)
                        }
                    }
                }
            }
        } label: {
            Label("템플릿", systemImage: "square.on.square.dashed")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(.secondary)
    }

    private func apply(_ template: PrayerNoteTemplate) {
        for name in template.categories where !categories.contains(name) {
            categories.append(name)
        }
    }

    /// One section as a unit (header + its topics + add row), so the whole
    /// block lifts and animates while it is being reordered.
    private func sectionGroup(for category: String) -> some View {
        let isDragging = draggingCategory == category
        return VStack(alignment: .leading, spacing: 12) {
            if category != categories.first || topics.contains(where: { $0.category == nil }) {
                Divider()
            }
            sectionHeader(for: category)
            topicRows(category: category)
            addTopicRow(category: category)
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: PrayerSectionFramesKey.self,
                    value: [category: geometry.frame(in: .named(Self.reorderSpace))]
                )
            }
        )
        .scaleEffect(isDragging ? 1.03 : 1)
        .opacity(isDragging ? 0.9 : 1)
        .shadow(
            color: isDragging ? Color.black.opacity(0.15) : .clear,
            radius: 10, y: 4
        )
        .zIndex(isDragging ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
    }

    private func sectionHeader(for category: String) -> some View {
        let index = categories.firstIndex(of: category)
        return HStack(spacing: 10) {
            if let index, editingCategoryIndex == index {
                TextField("섹션 이름", text: $editingCategoryName)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .focused($focusedCategoryIndex, equals: index)
                    .onSubmit { commitCategoryRename() }
            } else {
                // Plain text while not editing, so a long press starts the
                // reorder gesture instead of fighting a text field; tap to rename.
                Text(category)
                    .font(.title3.weight(.semibold))
                    .onTapGesture {
                        if let index { beginCategoryRename(at: index) }
                    }
            }
            Spacer(minLength: 0)
            Button {
                if let index { removeSection(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "섹션 삭제"))
        }
        .padding(.top, 10)
        .contentShape(Rectangle())
        .gesture(reorderGesture(for: category))
    }

    /// Reminders-style reorder: hold until the section lifts, then slide it —
    /// the other sections step aside as the finger crosses their midlines.
    private func reorderGesture(for category: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(
                before: DragGesture(
                    minimumDistance: 0, coordinateSpace: .named(Self.reorderSpace))
            )
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if draggingCategory != category {
                    commitCategoryRename()
                    draggingCategory = category
                    dragSlots = categories.compactMap { name in
                        sectionFrames[name].map { (category: name, midY: $0.midY) }
                    }
                    liftHaptic()
                }
                if let drag { moveDraggedSection(toPointerY: drag.location.y) }
            }
            .onEnded { _ in
                draggingCategory = nil
                dragSlots = []
            }
    }

    private func moveDraggedSection(toPointerY pointerY: CGFloat) {
        guard let dragging = draggingCategory,
            let from = categories.firstIndex(of: dragging),
            !dragSlots.isEmpty
        else { return }
        // Insertion slot = how many of the other sections' frozen midlines the
        // pointer sits below. Frozen slots keep this stable while views animate.
        let othersAbove = dragSlots.filter {
            $0.category != dragging && $0.midY < pointerY
        }.count
        guard othersAbove != from else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            categories.move(
                fromOffsets: IndexSet(integer: from),
                toOffset: othersAbove > from ? othersAbove + 1 : othersAbove
            )
        }
        stepHaptic()
    }

    private func liftHaptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    private func stepHaptic() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func beginCategoryRename(at index: Int) {
        commitCategoryRename()
        guard categories.indices.contains(index) else { return }
        editingCategoryIndex = index
        editingCategoryName = categories[index]
        focusedCategoryIndex = index
    }

    /// Applies a pending header rename in one step (topics follow the section),
    /// so a half-typed name never merges two sections mid-edit.
    private func commitCategoryRename() {
        guard let index = editingCategoryIndex else { return }
        editingCategoryIndex = nil
        guard categories.indices.contains(index) else { return }
        let old = categories[index]
        let new = editingCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingCategoryName = ""
        guard !new.isEmpty, new != old else { return }
        categories[index] = new
        for topicIndex in topics.indices where topics[topicIndex].category == old {
            topics[topicIndex].category = new
        }
        // Same name as another section: the duplicate collapses on save, so
        // merge the header list right away to match.
        if categories.filter({ $0 == new }).count > 1 {
            var seen = Set<String>()
            categories = categories.filter { seen.insert($0).inserted }
        }
    }

    @ViewBuilder
    private func topicRows(category: String?) -> some View {
        ForEach($topics) { $topic in
            if topic.category == category {
                PrayerTopicEditorRow(
                    topic: $topic,
                    focusedTopicID: $focusedTopicID,
                    focusedMemoID: $focusedMemoID,
                    focusedAnswerNoteID: $focusedAnswerNoteID,
                    onDelete: { topics.removeAll { $0.id == topic.id } }
                )
            }
        }
    }

    private func addTopicRow(category: String?) -> some View {
        Button {
            let topic = PrayerTopic(text: "", createdAt: .now, category: category)
            topics.append(topic)
            focusedTopicID = topic.id
        } label: {
            Label("기도제목 추가", systemImage: "plus")
                .font(.callout)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func addSection() {
        commitCategoryRename()
        // Stored, synced data stays Korean (never localized) like built-in
        // kind names — the user renames it right away via the focused field.
        let base = "새 섹션"
        var name = base
        var counter = 2
        while categories.contains(name) {
            name = base + " \(counter)"
            counter += 1
        }
        categories.append(name)
        editingCategoryIndex = categories.count - 1
        editingCategoryName = name
        focusedCategoryIndex = categories.count - 1
    }

    private func removeSection(at index: Int) {
        guard categories.indices.contains(index) else { return }
        let name = categories.remove(at: index)
        for topicIndex in topics.indices where topics[topicIndex].category == name {
            topics[topicIndex].category = nil
        }
    }

}

/// Section-group frames in the checklist's reorder coordinate space, used to
/// find which section the lifted one is being dragged over.
private struct PrayerSectionFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] { [:] }

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct PrayerTopicEditorRow: View {
    @Binding var topic: PrayerTopic
    var focusedTopicID: FocusState<UUID?>.Binding
    var focusedMemoID: FocusState<UUID?>.Binding
    var focusedAnswerNoteID: FocusState<UUID?>.Binding
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PrayerTopicCheckbox(
                status: topic.status,
                outcome: topic.answerOutcome,
                accessibilityLabel: topic.text
            ) {
                if topic.status == .answered {
                    topic.status = .ongoing
                    topic.answeredAt = nil
                    topic.answerOutcome = nil
                    topic.answerNote = nil
                } else {
                    topic.status = .answered
                    topic.answeredAt = .now
                    topic.answerOutcome = .yes
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                // Single-line on purpose: the vertical-axis field re-measured
                // itself on focus, so a freshly added row's caret rendered too
                // low and then jumped up.
                TextField("기도제목", text: $topic.text)
                    .textFieldStyle(.plain)
                    .submitLabel(.done)
                    .focused(focusedTopicID, equals: topic.id)
                    .strikethrough(topic.status == .answered)
                    .foregroundStyle(topic.status == .answered ? .secondary : .primary)
                // 행은 기본적으로 "[] 제목" 한 줄 — 메모 칸은 내용이 있을 때만
                // 보이고, 없으면 오른쪽의 메모 버튼으로 꺼낸다.
                if topic.memo != nil {
                    TextField("메모", text: memoBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .focused(focusedMemoID, equals: topic.id)
                }
                if topic.status == .answered {
                    Picker("응답 결과", selection: outcomeBinding) {
                        ForEach(PrayerAnswerOutcome.allCases, id: \.self) { outcome in
                            Text(verbatim: outcome.carryOverLabel).tag(outcome)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    HStack(spacing: 10) {
                        if let answeredAt = topic.answeredAt {
                            Text("응답 \(answeredAt, format: .dateTime.year().month().day())")
                                .font(.caption)
                                .foregroundStyle(.green)
                                .lineLimit(1)
                        }
                        if topic.answerNote == nil {
                            Button {
                                topic.answerNote = ""
                                focusedAnswerNoteID.wrappedValue = topic.id
                            } label: {
                                Label("응답 메모", systemImage: "plus.bubble")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                    if topic.answerNote != nil {
                        TextField("응답 메모", text: answerNoteBinding, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .focused(focusedAnswerNoteID, equals: topic.id)
                    }
                }
            }
            Spacer(minLength: 0)
            if topic.memo == nil {
                Button {
                    topic.memo = ""
                    focusedMemoID.wrappedValue = topic.id
                } label: {
                    Image(systemName: "note.text.badge.plus")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "메모 추가"))
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "기도제목 삭제"))
        }
        .padding(.vertical, 3)
    }

    // While the field is visible, keep empty text as "" (not nil) so the field
    // doesn't vanish mid-edit; validation turns "" into nil on save.
    private var memoBinding: Binding<String> {
        Binding(
            get: { topic.memo ?? "" },
            set: { topic.memo = $0 }
        )
    }

    private var answerNoteBinding: Binding<String> {
        Binding(
            get: { topic.answerNote ?? "" },
            set: { topic.answerNote = $0 }
        )
    }

    private var outcomeBinding: Binding<PrayerAnswerOutcome> {
        Binding(
            get: { topic.answerOutcome ?? .yes },
            set: { topic.answerOutcome = $0 }
        )
    }
}

/// Read-only 기도제목 list (sections included) for the iOS detail screen.
struct PrayerTopicReadOnlyList: View {
    let topics: [PrayerTopic]
    let categories: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            rows(for: nil)
            ForEach(categories, id: \.self) { category in
                if category != categories.first || topics.contains(where: { $0.category == nil }) {
                    Divider()
                }
                Text(category)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)
                rows(for: category)
            }
        }
    }

    @ViewBuilder
    private func rows(for category: String?) -> some View {
        ForEach(topics.filter { $0.category == category }) { topic in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(
                    systemName: topic.status == .answered
                        ? "checkmark.square.fill" : "square"
                )
                .foregroundStyle(topic.status == .answered ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(topic.text)
                            .strikethrough(topic.status == .answered)
                            .foregroundStyle(
                                topic.status == .answered ? .secondary : .primary)
                        if topic.status == .answered, let outcome = topic.answerOutcome {
                            PrayerOutcomeBadge(outcome: outcome)
                        }
                    }
                    if let answeredAt = topic.answeredAt, topic.status == .answered {
                        Text("응답 \(answeredAt, format: .dateTime.year().month().day())")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let memo = topic.memo {
                        Text(memo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if topic.status == .answered, let note = topic.answerNote {
                        Text("응답 메모: \(note)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One row of the aggregated 기도중/응답 lists in the content column.
struct PrayerTopicItemRow: View {
    let item: PrayerTopicItem
    let noteTitle: String
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PrayerTopicCheckbox(
                status: item.topic.status,
                outcome: item.topic.answerOutcome,
                accessibilityLabel: item.topic.text,
                action: onToggle
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.topic.text)
                        .strikethrough(item.topic.status == .answered)
                    if item.topic.status == .answered, let outcome = item.topic.answerOutcome {
                        PrayerOutcomeBadge(outcome: outcome)
                    }
                }
                if item.topic.status == .answered, let answeredAt = item.topic.answeredAt {
                    Text("응답 \(answeredAt, format: .dateTime.year().month().day())")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let memo = item.topic.memo {
                    Text(memo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.topic.status == .answered, let note = item.topic.answerNote {
                    Text("응답 메모: \(note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var sourceLine: String {
        var parts = [noteTitle]
        if let category = item.topic.category { parts.append(category) }
        parts.append(
            item.entryOccurredAt.formatted(.dateTime.year().month().day()))
        return parts.joined(separator: " · ")
    }
}

/// Yes / No / Wait capsule shown next to answered topics.
struct PrayerOutcomeBadge: View {
    let outcome: PrayerAnswerOutcome

    var body: some View {
        Text(verbatim: outcome.carryOverLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch outcome {
        case .yes: return .green
        case .no: return .secondary
        case .wait: return .orange
        }
    }
}

/// Shared checkbox button that flips a topic between 기도중 and 응답.
private struct PrayerTopicCheckbox: View {
    let status: PrayerStatus
    var outcome: PrayerAnswerOutcome?
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: status == .answered ? "checkmark.square.fill" : "square")
                .foregroundStyle(status == .answered ? Color.green : Color.secondary)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            status == .answered
                ? String(localized: "기도중으로 되돌리기: \(accessibilityLabel)")
                : String(localized: "응답으로 표시: \(accessibilityLabel)"))
    }
}
