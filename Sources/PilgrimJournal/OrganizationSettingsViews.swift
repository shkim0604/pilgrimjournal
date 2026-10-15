import JournalDomain
import SwiftUI

struct OrganizationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var rules: [ClassificationRuleRecord] = []
    @State private var tags: [String] = []
    @State private var tagToRename: String?
    @State private var newTagName = ""
    @State private var tagToRemove: String?

    var body: some View {
        List {
            Section("태그") {
                if tags.isEmpty {
                    Text("사용 중인 태그가 없습니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Label(tag, systemImage: "number")
                        Spacer()
                        Menu("관리") {
                            Button("이름 변경") {
                                tagToRename = tag
                                newTagName = tag
                            }
                            Button("모든 기록에서 제거", role: .destructive) {
                                tagToRemove = tag
                            }
                        }
                    }
                }
            }

            Section("Day One 분류 규칙") {
                NavigationLink {
                    ClassificationRuleEditorView(rule: nil)
                } label: {
                    Label("새 규칙", systemImage: "plus")
                }
                if rules.isEmpty {
                    Text("태그나 Day One 템플릿을 기록 유형에 연결할 수 있습니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    NavigationLink {
                        ClassificationRuleEditorView(rule: rule)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(sourceName(rule.source)) · \(rule.value)")
                            Text(
                                "\(model.kindDefinition(for: rule.targetKind).displayName) · 우선순위 \(rule.priority)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for offset in offsets {
                        model.deleteClassificationRule(id: rules[offset].id)
                    }
                    reload()
                }
            }
        }
        .navigationTitle("태그 및 분류")
        .onAppear { reload() }
        .alert(
            "태그 이름 변경",
            isPresented: Binding(
                get: { tagToRename != nil },
                set: { if !$0 { tagToRename = nil } }
            )
        ) {
            TextField("새 태그 이름", text: $newTagName)
            Button("변경") {
                guard let oldName = tagToRename else { return }
                if model.renameTag(oldName, to: newTagName) {
                    tagToRename = nil
                    reload()
                }
            }
            Button("취소", role: .cancel) { tagToRename = nil }
        } message: {
            Text("이 태그가 연결된 모든 기록에 revision이 생성됩니다.")
        }
        .confirmationDialog(
            "‘\(removingTagName)’ 태그를 모든 기록에서 제거할까요?",
            isPresented: Binding(
                get: { tagToRemove != nil },
                set: { if !$0 { tagToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("태그 제거", role: .destructive) {
                guard let tag = tagToRemove else { return }
                if model.removeTag(tag) {
                    tagToRemove = nil
                    reload()
                }
            }
            Button("취소", role: .cancel) { tagToRemove = nil }
        } message: {
            Text("기록 자체는 삭제되지 않습니다.")
        }
    }

    private func reload() {
        tags = model.availableTags()
        rules = model.classificationRules()
    }

    private var removingTagName: String { tagToRemove ?? "" }

    private func sourceName(_ source: ClassificationSource) -> String {
        switch source {
        case .tag: String(localized: "태그")
        case .templateUUID: String(localized: "템플릿 UUID")
        case .templateTitle: String(localized: "템플릿 제목")
        }
    }
}

private struct ClassificationRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var rule: ClassificationRuleRecord

    init(rule: ClassificationRuleRecord?) {
        _rule = State(
            initialValue: rule
                ?? ClassificationRuleRecord(
                    source: .tag,
                    value: "",
                    targetKind: .diary
                ))
    }

    var body: some View {
        Form {
            Picker("근거", selection: $rule.source) {
                Text("Day One 태그").tag(ClassificationSource.tag)
                Text("템플릿 UUID").tag(ClassificationSource.templateUUID)
                Text("템플릿 제목").tag(ClassificationSource.templateTitle)
            }
            TextField(valuePrompt, text: $rule.value)
            Picker("대상 유형", selection: $rule.targetKind) {
                ForEach(model.kindPickerOptions(including: rule.targetKind), id: \.kind) {
                    definition in
                    Text(definition.displayName).tag(definition.kind)
                }
            }
            Stepper("우선순위 \(rule.priority)", value: $rule.priority, in: -100...100)
            Text("여러 규칙이 일치하면 우선순위가 가장 높은 규칙을 사용합니다. 같은 우선순위에서 대상 유형이 다르면 미분류로 남깁니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .navigationTitle("분류 규칙")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("저장") {
                    rule.value = rule.value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    rule.updatedAt = .now
                    if model.saveClassificationRule(rule) {
                        dismiss()
                    }
                }
                .disabled(
                    rule.value.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
    }

    private var valuePrompt: String {
        switch rule.source {
        case .tag: String(localized: "태그 이름")
        case .templateUUID: String(localized: "템플릿 UUID")
        case .templateTitle: String(localized: "템플릿 제목")
        }
    }
}
