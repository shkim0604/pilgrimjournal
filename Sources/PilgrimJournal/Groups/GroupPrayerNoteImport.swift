import Foundation
import JournalDomain
import PilgrimAPI
import SwiftUI

/// One of my prayer notes as "기도노트에서 가져오기" offers it: its topics grouped by section in the
/// note's order (topics without a section first).
struct GroupPrayerNote: Identifiable, Equatable {
    struct Section: Identifiable, Equatable {
        /// nil: the topics above the first heading.
        var name: String?
        var topics: [PrayerTopic]
        var id: String { name ?? "" }
    }

    let id: UUID
    let title: String
    let occurredAt: Date
    let sections: [Section]

    init(_ record: JournalEntryRecord) {
        id = record.id
        title = record.title.trimmingCharacters(in: .whitespacesAndNewlines)
        occurredAt = record.occurredAt
        let topics = record.details.prayerTopics ?? []
        var names: [String] = []
        for name in (record.details.prayerCategories ?? []) + topics.compactMap(\.category)
        where !names.contains(name) {
            names.append(name)
        }
        let order: [String?] = [nil] + names.map(Optional.some)
        sections = order.compactMap { name in
            let matching = topics.filter { $0.category == name }
            return matching.isEmpty ? nil : Section(name: name, topics: matching)
        }
    }

    var topics: [PrayerTopic] { sections.flatMap(\.topics) }
    var ongoingCount: Int { topics.filter { $0.status != .answered }.count }
    var answeredCount: Int { topics.filter { $0.status == .answered }.count }
}

/// What the composer gets from the journal: the prayer notes to import from, and a callback
/// with the imported lines of a successful post (by posted item index) so their answered marks
/// can follow the journal.
struct GroupPrayerNoteSource {
    var notes: @MainActor () -> [GroupPrayerNote]
    var didPost: @MainActor (PostResponse, [Int: GroupPrayerTopicSource]) -> Void
}

/// Picks one prayer note, then its topics (ongoing ones checked), for the group composer.
struct GroupPrayerNoteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let load: @MainActor () -> [GroupPrayerNote]
    let onImport: (GroupPrayerNote, Set<UUID>) -> Void
    @State private var notes: [GroupPrayerNote]?

    var body: some View {
        NavigationStack {
            Group {
                if let notes, notes.isEmpty {
                    JournalEmptyState(
                        title: String(localized: "가져올 기도노트가 없어요"),
                        description: String(localized: "기도노트에 기도제목을 적으면 여기서 골라 올릴 수 있어요."),
                        systemImage: "hands.sparkles"
                    ) {}
                } else {
                    List(notes ?? []) { note in
                        NavigationLink {
                            GroupPrayerTopicPicker(note: note) { picked in
                                onImport(note, picked)
                                dismiss()
                            }
                        } label: {
                            noteRow(note)
                        }
                    }
                }
            }
            .navigationTitle("기도노트에서 가져오기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
        .task { if notes == nil { notes = load() } }
    }

    private func noteRow(_ note: GroupPrayerNote) -> some View {
        let date = note.occurredAt.formatted(.dateTime.year().month().day())
        return VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: note.title.isEmpty ? date : note.title)
            HStack(spacing: 6) {
                if !note.title.isEmpty { Text(verbatim: date) }
                Text("기도중 \(note.ongoingCount) · 응답 \(note.answeredCount)")
            }
            .font(.caption)
            .foregroundStyle(JournalTheme.inkSecondary)
        }
    }
}

/// The topics of one note, grouped by section; ongoing ones start checked.
private struct GroupPrayerTopicPicker: View {
    let note: GroupPrayerNote
    let onImport: (Set<UUID>) -> Void
    @State private var picked: Set<UUID>

    init(note: GroupPrayerNote, onImport: @escaping (Set<UUID>) -> Void) {
        self.note = note
        self.onImport = onImport
        _picked = State(
            initialValue: Set(note.topics.filter { $0.status != .answered }.map(\.id)))
    }

    var body: some View {
        List {
            ForEach(note.sections) { section in
                Section {
                    ForEach(section.topics) { topic in row(topic) }
                } header: {
                    if let name = section.name { Text(verbatim: name) }
                }
            }
            Section {
            } footer: {
                Text("고른 기도제목의 내용과 섹션 이름만 올라가요. 메모와 노트 본문은 올라가지 않아요.")
            }
        }
        .navigationTitle(
            note.title.isEmpty ? note.occurredAt.formatted(.dateTime.month().day()) : note.title
        )
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("가져오기") { onImport(picked) }
                    .disabled(picked.isEmpty)
            }
        }
    }

    private func row(_ topic: PrayerTopic) -> some View {
        let isPicked = picked.contains(topic.id)
        return Button {
            if isPicked { picked.remove(topic.id) } else { picked.insert(topic.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isPicked ? JournalTheme.brandPrimary : Color.secondary)
                    .imageScale(.large)
                Text(verbatim: topic.text)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if topic.status == .answered {
                    Text("응답")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }
}
