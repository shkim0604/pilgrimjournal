import JournalDomain
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct EntryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: JournalEntryRecord

    var body: some View {
        HStack(spacing: JournalTheme.Spacing.medium) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(
                    JournalTheme.categoryColor(
                        for: model.kindDefinition(for: entry.kind))
                )
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(
                        EntryListSummaryFormatter.title(
                            explicitTitle: entry.title,
                            body: entry.body,
                            fallback: model.kindDefinition(for: entry.kind).displayName
                        )
                    )
                    .font(.headline)
                    .foregroundStyle(JournalTheme.ink)
                    .lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(JournalTheme.inkSecondary)
                            .accessibilityLabel("고정됨")
                    }
                    if entry.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(JournalTheme.accentWarm)
                            .accessibilityLabel("즐겨찾기")
                    }
                }

                let summary = EntryListSummaryFormatter.summary(from: entry.body)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.callout)
                        .lineLimit(2)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }

                HStack(spacing: JournalTheme.Spacing.small) {
                    Text(entry.occurredAt, style: .date)
                    if entry.kind.builtIn == .prayer,
                        let counts = entry.details.prayerTopicCounts
                    {
                        Text("•")
                            .accessibilityHidden(true)
                        Text("응답 \(counts.answered) · 기도중 \(counts.ongoing)")
                    }
                    if let notebook = entry.notebookName {
                        Text("•")
                            .accessibilityHidden(true)
                        Label(notebook, systemImage: "book.closed")
                    }
                }
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
            }
        }
        .padding(.vertical, JournalTheme.Spacing.small)
        .accessibilityElement(children: .combine)
    }
}

struct EntryRowWithActions: View {
    @EnvironmentObject private var model: AppModel
    @State private var prayerRequestShareEntry: JournalEntryRecord?
    let entry: JournalEntryRecord

    var body: some View {
        EntryRow(entry: entry)
            .contextMenu {
                Button("편집") { edit() }
                if model.canShare, model.sharedSpaceID(for: entry.id) == nil {
                    Button {
                        Task { await model.shareEntry(entry) }
                    } label: {
                        Label("공유…", systemImage: "person.crop.circle.badge.plus")
                    }
                }
                if entry.offersPrayerRequestSharing {
                    Button {
                        sharePrayerRequests()
                    } label: {
                        Label("기도제목 나누기", systemImage: "hands.and.sparkles")
                    }
                }
                Button("휴지통으로 이동", role: .destructive) {
                    model.moveToTrash(entry)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    model.moveToTrash(entry)
                } label: {
                    Label("삭제", systemImage: "trash")
                }
            }
            .sheet(item: $prayerRequestShareEntry) { entry in
                PrayerRequestShareSheet(entry: entry)
            }
    }

    private func sharePrayerRequests() {
        #if os(macOS)
        // The inline editor may hold unsaved text for this entry; the sheet reads the saved one.
        model.flushOpenEditor()
        let saved = model.entryRecord(id: entry.id) ?? entry
        guard saved.offersPrayerRequestSharing else { return }
        prayerRequestShareEntry = saved
        #else
        prayerRequestShareEntry = entry
        #endif
    }

    private func edit() {
        #if os(macOS)
        model.selectEntry(entry.id)
        #else
        model.beginEditing(entry)
        #endif
    }
}
