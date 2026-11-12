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

struct EntryDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPresentingHistory = false
    @State private var isPresentingPrayerRequestShare = false
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
                Text(
                    entry.title.isEmpty
                        ? model.kindDefinition(for: entry.kind).displayName : entry.title
                )
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
        .sheet(isPresented: $isPresentingPrayerRequestShare) {
            PrayerRequestShareSheet(entry: entry)
        }
    }

    private var kindBadge: some View {
        let definition = model.kindDefinition(for: entry.kind)
        return Text(definition.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(JournalTheme.categoryColor(for: definition))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                JournalTheme.categoryColor(for: definition).opacity(0.12),
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
            if entry.offersPrayerRequestSharing {
                Button("기도제목 나누기") {
                    isPresentingPrayerRequestShare = true
                }
            }
        }
    }

    @ViewBuilder
    private var typeDetails: some View {
        switch entry.kind.builtIn {
        case .prayer?:
            if let topics = entry.details.prayerTopics, !topics.isEmpty {
                PrayerTopicReadOnlyList(
                    topics: topics,
                    categories: entry.details.prayerCategories ?? [])
            }
        case .bibleStudy?:
            if let reference = entry.details.scriptureReference, !reference.isEmpty {
                Label(reference, systemImage: "book.closed")
            }
        case .reading?:
            if let title = entry.details.bookTitle, !title.isEmpty {
                Label(
                    [title, entry.details.bookAuthor].compactMap { $0 }.joined(separator: " · "),
                    systemImage: "books.vertical"
                )
            }
        case .diary?:
            if let mood = entry.details.mood, !mood.isEmpty {
                Label(mood, systemImage: "face.smiling")
            }
        case .memo?:
            EmptyView()
        default:
            EmptyView()
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
                        Text(
                            revision.snapshot.title.isEmpty
                                ? String(localized: "제목 없음") : revision.snapshot.title
                        )
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
