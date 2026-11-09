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
                "휴지통의 \(model.trashEntries.count)개 기록과 수정 이력, 첨부가 이 기기와 iCloud에서 완전히 지워집니다. 되돌릴 수 없습니다. 다른 기기가 동기화된 뒤에 실행하세요."
            )
        }
    }

    @ViewBuilder
    private func trashEntryDescription(_ entry: JournalEntryRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(
                entry.title.isEmpty
                    ? model.kindDefinition(for: entry.kind).displayName : entry.title
            )
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
                        value: String(localized: "\(model.selectedEntryIDs.count)개")
                    )
                }
                Section(
                    String(
                        localized: "organize.typeSection", defaultValue: "유형",
                        comment: "Header of the section that changes the type of selected entries")
                ) {
                    Picker("변경할 유형", selection: $targetKind) {
                        Text("유형 유지").tag(nil as JournalKind?)
                        ForEach(model.kindPickerOptions(), id: \.kind) { definition in
                            Text(definition.displayName).tag(definition.kind as JournalKind?)
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
