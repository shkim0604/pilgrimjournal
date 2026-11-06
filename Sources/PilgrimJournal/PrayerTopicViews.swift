import JournalDomain
import SwiftUI

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
    @FocusState private var focusedCategoryIndex: Int?
    @State private var isNamingTemplate = false
    @State private var templateName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
            ForEach(categories.indices, id: \.self) { index in
                sectionHeader(index: index)
                topicRows(category: categories[index])
                addTopicRow(category: categories[index])
            }
            Button {
                addSection()
            } label: {
                Label("섹션 추가", systemImage: "folder.badge.plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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

    private func sectionHeader(index: Int) -> some View {
        HStack(spacing: 6) {
            TextField("섹션 이름", text: categoryNameBinding(index))
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .focused($focusedCategoryIndex, equals: index)
            Spacer(minLength: 0)
            Button {
                removeSection(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "섹션 삭제"))
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func topicRows(category: String?) -> some View {
        ForEach($topics) { $topic in
            if topic.category == category {
                PrayerTopicEditorRow(
                    topic: $topic,
                    focusedTopicID: $focusedTopicID,
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
        focusedCategoryIndex = categories.count - 1
    }

    private func removeSection(at index: Int) {
        guard categories.indices.contains(index) else { return }
        let name = categories.remove(at: index)
        for topicIndex in topics.indices where topics[topicIndex].category == name {
            topics[topicIndex].category = nil
        }
    }

    private func categoryNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { categories.indices.contains(index) ? categories[index] : "" },
            set: { newValue in
                guard categories.indices.contains(index) else { return }
                let old = categories[index]
                categories[index] = newValue
                for topicIndex in topics.indices where topics[topicIndex].category == old {
                    topics[topicIndex].category = newValue
                }
            }
        )
    }
}

private struct PrayerTopicEditorRow: View {
    @Binding var topic: PrayerTopic
    var focusedTopicID: FocusState<UUID?>.Binding
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
            VStack(alignment: .leading, spacing: 2) {
                TextField("기도제목", text: $topic.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused(focusedTopicID, equals: topic.id)
                    .strikethrough(topic.status == .answered)
                    .foregroundStyle(topic.status == .answered ? .secondary : .primary)
                TextField("메모", text: memoBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if topic.status == .answered {
                    HStack(spacing: 6) {
                        Picker("응답 결과", selection: outcomeBinding) {
                            ForEach(PrayerAnswerOutcome.allCases, id: \.self) { outcome in
                                Text(verbatim: outcome.carryOverLabel).tag(outcome)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        if let answeredAt = topic.answeredAt {
                            Text("응답 \(answeredAt, format: .dateTime.year().month().day())")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    TextField("응답 메모", text: answerNoteBinding, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "기도제목 삭제"))
        }
    }

    private var memoBinding: Binding<String> {
        Binding(
            get: { topic.memo ?? "" },
            set: { topic.memo = $0.isEmpty ? nil : $0 }
        )
    }

    private var answerNoteBinding: Binding<String> {
        Binding(
            get: { topic.answerNote ?? "" },
            set: { topic.answerNote = $0.isEmpty ? nil : $0 }
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
        VStack(alignment: .leading, spacing: 6) {
            rows(for: nil)
            ForEach(categories, id: \.self) { category in
                Text(category)
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
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
