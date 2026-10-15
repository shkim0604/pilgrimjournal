import JournalDomain
import SwiftUI

/// "유형 편집": reorder, delete, restore and open the editor for journal kinds.
struct KindManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var path: [KindEditorRoute] = []
    @State private var errorMessage: String?
    @State private var pendingDeletion: KindDeletionDialog?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    ForEach(model.kindCatalog.creatableKinds) { definition in
                        kindRow(definition)
                            .deleteDisabled(!definition.kind.canBeDeleted)
                    }
                    .onMove(perform: moveKinds)
                    .onDelete { offsets in
                        requestDeletion(at: offsets, in: model.kindCatalog.creatableKinds)
                    }

                    // Kinds from another device whose catalog has not arrived
                    // yet. Not movable: reordering would store the placeholder
                    // name, which would then win over the real one when the
                    // other device's catalog arrives.
                    ForEach(unknownDefinitions) { definition in
                        kindRow(definition)
                            .moveDisabled(true)
                    }
                    .onDelete { offsets in
                        requestDeletion(at: offsets, in: unknownDefinitions)
                    }

                    KindRowLabel(definition: model.kindDefinition(for: .unclassified))
                        .foregroundStyle(.secondary)
                        .opacity(0.6)
                        .disabled(true)

                    Button {
                        errorMessage = nil
                        path.append(.create)
                    } label: {
                        Label("유형 추가", systemImage: "plus.circle")
                            .foregroundStyle(JournalTheme.brandPrimary)
                    }
                    .buttonStyle(.plain)
                }

                if !model.kindCatalog.deletedBuiltIns.isEmpty {
                    Section("삭제한 기본 유형") {
                        ForEach(model.kindCatalog.deletedBuiltIns) { definition in
                            HStack {
                                KindRowLabel(definition: definition)
                                Spacer(minLength: JournalTheme.Spacing.small)
                                Button("되살리기") { restore(definition.kind) }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(JournalTheme.brandPrimary)
                            }
                        }
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle("유형 편집")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .navigationDestination(for: KindEditorRoute.self) { route in
                switch route {
                case .create:
                    KindDetailEditor(
                        editing: nil,
                        initialColor: KindDetailEditor.newKindColor(
                            activeKinds: model.kindCatalog.activeKinds)
                    )
                case .edit(let kind):
                    KindDetailEditor(
                        editing: model.kindDefinition(for: kind),
                        isKnown: model.kindCatalog.isKnown(kind),
                        initialColor: model.kindDefinition(for: kind).colorToken
                    )
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .confirmationDialog(
            pendingDeletion.map { "‘\($0.name)’을(를) 삭제할까요?" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { dialog in
            ForEach(dialog.targets) { target in
                Button("\(target.name)(으)로 옮기고 삭제") {
                    delete(dialog.kind, moveTo: target.kind)
                }
            }
            Button("취소", role: .cancel) {}
        } message: { dialog in
            Text("기록 \(dialog.entryCount)개를 어디로 옮길까요?")
        }
    }

    private var unknownDefinitions: [KindDefinition] {
        model.unknownKinds.map(KindCatalog.unknownDefinition(for:))
    }

    private func kindRow(_ definition: KindDefinition) -> some View {
        Button {
            errorMessage = nil
            path.append(.edit(definition.kind))
        } label: {
            HStack {
                KindRowLabel(definition: definition)
                Spacer(minLength: JournalTheme.Spacing.small)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("이름, 색, 아이콘을 바꿉니다.")
        #if os(macOS)
        .contextMenu {
            if definition.kind.canBeDeleted {
                Button("삭제", role: .destructive) { requestDeletion(of: definition) }
            }
        }
        #endif
    }

    private func moveKinds(from source: IndexSet, to destination: Int) {
        var ordered = model.kindCatalog.creatableKinds.map(\.kind)
        ordered.move(fromOffsets: source, toOffset: destination)
        perform { try model.reorderKinds(ordered) }
    }

    private func requestDeletion(at offsets: IndexSet, in definitions: [KindDefinition]) {
        guard let index = offsets.first, definitions.indices.contains(index) else { return }
        requestDeletion(of: definitions[index])
    }

    /// Deletes straight away when nothing needs moving; otherwise asks where
    /// the kind's entries should go.
    private func requestDeletion(of definition: KindDefinition) {
        errorMessage = nil
        // The domain still accepts these deletions (older builds and other
        // devices may send them); the app just never starts one.
        guard definition.kind.canBeDeleted else { return }
        do {
            let count = try model.entryCount(for: definition.kind)
            guard count > 0 else {
                delete(definition.kind, moveTo: .unclassified)
                return
            }
            pendingDeletion = KindDeletionDialog(
                kind: definition.kind,
                name: definition.name,
                entryCount: count,
                targets: KindDeletionDialog.moveTargets(
                    excluding: definition.kind,
                    activeKinds: model.kindCatalog.activeKinds,
                    unclassified: model.kindDefinition(for: .unclassified)
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ kind: JournalKind, moveTo target: JournalKind) {
        pendingDeletion = nil
        #if os(iOS)
        // Deleting the selected kind falls back to 전체 기록 and selects its
        // first entry, which on iPhone would push that entry's detail once
        // the sheet closes. Match the sidebar, which clears it on iOS.
        let wasSelected = model.selectedKind == kind
        perform { try model.deleteKind(kind, moveTo: target) }
        if wasSelected { model.selectEntry(nil) }
        #else
        perform { try model.deleteKind(kind, moveTo: target) }
        #endif
    }

    private func restore(_ kind: JournalKind) {
        perform { try model.restoreKind(kind) }
    }

    private func perform(_ action: () throws -> Void) {
        errorMessage = nil
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum KindEditorRoute: Hashable {
    case create
    case edit(JournalKind)
}

/// The kind a deletion is waiting on, with the entry count and the kinds its
/// entries may move to.
struct KindDeletionDialog: Equatable {
    let kind: JournalKind
    let name: String
    let entryCount: Int
    let targets: [KindDefinition]

    /// 미분류 first, then every other active kind in sidebar order.
    static func moveTargets(
        excluding kind: JournalKind,
        activeKinds: [KindDefinition],
        unclassified: KindDefinition
    ) -> [KindDefinition] {
        [unclassified]
            + activeKinds.filter { $0.kind != kind && !$0.kind.isUnclassified }
    }
}

/// Name, colour and icon of a new kind or an existing one.
struct KindDetailEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    private let editing: KindDefinition?
    @State private var name: String
    @State private var colorToken: KindColorToken
    @State private var iconToken: String
    @State private var errorMessage: String?

    init(editing: KindDefinition?, isKnown: Bool = true, initialColor: KindColorToken) {
        self.editing = editing
        _name = State(initialValue: Self.initialName(editing: editing, isKnown: isKnown))
        _colorToken = State(initialValue: initialColor)
        _iconToken = State(
            initialValue: editing.map { KindIconCatalog.displaySymbol(for: $0.iconToken) }
                ?? "tag")
    }

    /// The name field starts empty for a new kind and for a kind the catalog
    /// does not know yet, whose "이름 없는 유형" is only a placeholder: saving it
    /// as the real name would win over the name from the other device.
    static func initialName(editing: KindDefinition?, isKnown: Bool) -> String {
        guard let editing, isKnown else { return "" }
        return editing.name
    }

    /// The first colour no active kind uses, or teal when all are taken.
    static func newKindColor(activeKinds: [KindDefinition]) -> KindColorToken {
        let used = Set(activeKinds.map(\.colorToken))
        return KindColorToken.allCases.first { !used.contains($0) } ?? .teal
    }

    var body: some View {
        Form {
            Section("이름") {
                TextField("유형 이름", text: $name)
                    .onSubmit(save)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("색") {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 36), spacing: JournalTheme.Spacing.medium)
                    ],
                    spacing: JournalTheme.Spacing.medium
                ) {
                    ForEach(KindColorToken.allCases, id: \.self) { token in
                        colorSwatch(token)
                    }
                }
                .padding(.vertical, JournalTheme.Spacing.small)
            }

            Section("아이콘") {
                LazyVGrid(
                    columns: [
                        GridItem(.adaptive(minimum: 44), spacing: JournalTheme.Spacing.small)
                    ],
                    spacing: JournalTheme.Spacing.small
                ) {
                    ForEach(KindIconCatalog.symbols, id: \.self) { symbol in
                        iconCell(symbol)
                    }
                }
                .padding(.vertical, JournalTheme.Spacing.small)
            }

            Section("미리보기") {
                JournalSidebarItem(
                    title: previewName,
                    systemImage: iconToken,
                    accent: JournalTheme.color(for: colorToken),
                    isSelected: false
                ) {}
                .allowsHitTesting(false)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(editing == nil ? "유형 추가" : "유형 수정")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("저장", action: save)
            }
        }
    }

    private var previewName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "유형 이름" : trimmed
    }

    private func colorSwatch(_ token: KindColorToken) -> some View {
        let isSelected = token == colorToken
        return Button {
            colorToken = token
        } label: {
            Circle()
                .fill(JournalTheme.color(for: token))
                .frame(width: 32, height: 32)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(3)
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? JournalTheme.color(for: token) : .clear,
                            lineWidth: 2)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(token.accessibilityName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func iconCell(_ symbol: String) -> some View {
        let isSelected = symbol == iconToken
        return Button {
            iconToken = symbol
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(JournalTheme.color(for: colorToken))
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: JournalTheme.Radius.small, style: .continuous)
                        .fill(isSelected ? JournalTheme.selection : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: JournalTheme.Radius.small, style: .continuous)
                        .stroke(
                            isSelected ? JournalTheme.brandPrimary : JournalTheme.separator,
                            lineWidth: isSelected ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func save() {
        errorMessage = nil
        do {
            if let editing {
                try model.updateKind(
                    editing.kind, name: name, colorToken: colorToken, iconToken: iconToken)
            } else {
                _ = try model.createKind(name: name, colorToken: colorToken, iconToken: iconToken)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Icon and name of a kind, as the sidebar shows them.
private struct KindRowLabel: View {
    let definition: KindDefinition

    var body: some View {
        Label {
            Text(definition.name)
        } icon: {
            Image(systemName: KindIconCatalog.displaySymbol(for: definition.iconToken))
                .foregroundStyle(JournalTheme.categoryColor(for: definition))
        }
    }
}

/// Shown instead of "유형 편집" when kind management is locked.
struct PremiumFeatureNoticeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: JournalTheme.Spacing.regular) {
            Image(systemName: "lock.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(JournalTheme.brandPrimary)
                .accessibilityHidden(true)
            Text("유료 기능")
                .font(.title2.weight(.semibold))
                .foregroundStyle(JournalTheme.ink)
            Text("유형 추가·삭제·편집은 유료 버전에서 쓸 수 있습니다. 지금 있는 유형으로 기록을 쓰고 옮기는 것은 계속 할 수 있습니다.")
                .multilineTextAlignment(.center)
                .foregroundStyle(JournalTheme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("닫기") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(JournalTheme.brandPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(JournalTheme.Spacing.large)
        .frame(maxWidth: 420)
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }
}

extension KindColorToken {
    fileprivate var accessibilityName: String {
        switch self {
        case .amber: "호박색"
        case .sage: "세이지색"
        case .slate: "청회색"
        case .clay: "점토색"
        case .iris: "보라색"
        case .stone: "회색"
        case .teal: "청록색"
        case .rose: "장미색"
        }
    }
}
