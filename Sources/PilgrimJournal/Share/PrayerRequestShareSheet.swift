import JournalDomain
import JournalShareDrafts
import SwiftUI

#if canImport(Translation)
import Translation
#endif
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

extension JournalEntryRecord {
    /// Whether "share prayer requests" is offered: there must be text to read, outside the trash.
    var offersPrayerRequestSharing: Bool {
        !isDeleted && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Lets the person pick, edit and share prayer requests drawn from one entry. The sheet is the
/// confirmation step; nothing in it is saved, so closing it drops every line.
struct PrayerRequestShareSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PrayerRequestShareModel
    @State private var translation: PrayerRequestTranslationJob?
    @State private var isConfirmingDiscard = false

    init(entry: JournalEntryRecord) {
        _model = StateObject(wrappedValue: Self.makeModel(for: entry))
    }

    private static func makeModel(for entry: JournalEntryRecord) -> PrayerRequestShareModel {
        PrayerRequestShareModel(
            source: PrayerRequestSource(
                title: entry.title,
                dateText: entry.occurredAt.formatted(date: .long, time: .shortened),
                body: entry.body),
            pipeline: ShareDraftFeature.makeModel().map(PrayerRequestPipeline.init(model:)),
            availability: ShareDraftFeature.availability())
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.phase == .drafting {
                    draftingSection
                } else {
                    rowsSection
                }
                languageSection
                Section {
                    Text("다른 사람 이야기가 들어 있다면 나누기 전에 한 번 더 확인해 주세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .bottom) { shareBar }
            .navigationTitle("기도제목 나누기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기", action: close)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .interactiveDismissDisabled(model.hasEdits)
        .confirmationDialog(
            "작성한 기도제목을 버릴까요?", isPresented: $isConfirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("버리기", role: .destructive) { dismiss() }
            Button("계속 쓰기", role: .cancel) {}
        }
        .prayerRequestTranslation(translation) { finishTranslation($0, $1) }
        .task { await model.start() }
    }

    // MARK: - Sections

    private var draftingSection: some View {
        Section {
            HStack(spacing: JournalTheme.Spacing.regular) {
                ProgressView()
                Text("기도제목을 찾는 중…")
                    .foregroundStyle(.secondary)
            }
            Button("직접 쓰기") { model.writeManually() }
        }
    }

    private var rowsSection: some View {
        Section {
            ForEach(model.rows) { row in
                rowView(row)
            }
            Button {
                model.addRow()
            } label: {
                // Own keys: the prayer-note checklist already owns "기도제목 추가" / "기도제목"
                // with "prayer topic" wording in English.
                Label(
                    String(
                        localized: "prayerShare.addRequest", defaultValue: "기도제목 추가",
                        comment: "Adds an empty line to the share-prayer-requests sheet"),
                    systemImage: "plus")
            }
        } footer: {
            if let manualNotice {
                Text(manualNotice)
            }
        }
    }

    private func rowView(_ row: PrayerRequestShareModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: JournalTheme.Spacing.regular) {
            Button {
                toggleSelection(of: row.id)
            } label: {
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(row.text.isEmpty ? Self.requestPlaceholder : row.text))
            .accessibilityAddTraits(row.isSelected ? .isSelected : [])

            VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
                TextField(
                    Self.requestPlaceholder,
                    text: Binding(get: { row.text }, set: { model.edit(row.id, text: $0) }),
                    axis: .vertical
                )
                .labelsHidden()
                if let topic = row.topic {
                    Text(verbatim: topic.name(in: row.language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var languageSection: some View {
        if #available(iOS 18, macOS 15, *) {
            Section {
                Picker("나눌 언어", selection: languageSelection) {
                    ForEach(RequestLanguage.allCases, id: \.self) { language in
                        Text(verbatim: Self.languageName(language)).tag(language)
                    }
                }
                .disabled(model.phase == .drafting || translation != nil)
            } footer: {
                if let notice = model.notice {
                    Text(notice)
                }
            }
        }
    }

    private var shareBar: some View {
        HStack(spacing: JournalTheme.Spacing.regular) {
            Button(action: copy) {
                Label("복사", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            ShareLink(item: model.shareText) {
                Label("나누기", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .disabled(!model.canShare)
        .padding()
        .background(.bar)
    }

    // MARK: - Behaviour

    private var manualNotice: LocalizedStringKey? {
        switch model.phase {
        case .manual(reason: .nothingToPrayFor), .manual(reason: .noUsableAnswer):
            "이 기록에서는 기도제목을 찾지 못했어요. 직접 적어 보세요."
        case .manual(reason: .modelUnavailable):
            "이 기기에서는 자동 제안을 쓸 수 없어요. 직접 적어 보세요."
        case .manual(reason: .userChoice), .drafting, .ready:
            nil
        }
    }

    /// The picker shows the language being translated into while a translation runs, and the
    /// model's share language otherwise (so a failed translation puts it back).
    private var languageSelection: Binding<RequestLanguage> {
        Binding(
            get: { translation?.target ?? model.shareLanguage },
            set: { startTranslation(to: $0) })
    }

    private static var requestPlaceholder: String {
        String(
            localized: "prayerShare.requestPlaceholder", defaultValue: "기도제목",
            comment: "Placeholder of one line in the share-prayer-requests sheet")
    }

    private static func languageName(_ language: RequestLanguage) -> String {
        switch language {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    private func toggleSelection(of id: UUID) {
        guard let index = model.rows.firstIndex(where: { $0.id == id }) else { return }
        model.rows[index].isSelected.toggle()
    }

    private func startTranslation(to target: RequestLanguage) {
        guard translation == nil, target != model.shareLanguage else { return }
        guard let request = model.translationRequest(to: target) else {
            // Every filled line is already in `target`: just switch, nothing to translate.
            model.applyTranslation([], for: [], to: target)
            return
        }
        translation = PrayerRequestTranslationJob(
            texts: request.texts, ids: request.ids, source: request.from, target: target)
    }

    private func finishTranslation(_ job: PrayerRequestTranslationJob, _ texts: [String]?) {
        // A job already given up on (see the start grace in the translation modifier) is ignored.
        guard job.id == translation?.id else { return }
        if let texts {
            model.applyTranslation(texts, for: job.ids, to: job.target)
        } else {
            model.translationFailed(String(localized: "번역하지 못했어요. 원래 언어로 나눕니다."))
        }
        translation = nil
    }

    private func close() {
        if model.hasEdits {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = model.shareText
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.shareText, forType: .string)
        #endif
    }
}

/// Receives a finished job with its texts in order, or nil when translating failed.
typealias PrayerRequestTranslationCompletion =
    @MainActor @Sendable (PrayerRequestTranslationJob, [String]?) -> Void

/// One pending translation of the sheet's lines.
struct PrayerRequestTranslationJob: Equatable, Identifiable, Sendable {
    let id = UUID()
    let texts: [String]
    let ids: [UUID]
    let source: RequestLanguage
    let target: RequestLanguage
}

extension View {
    /// Runs `job` through Apple's on-device Translation framework where it exists (iOS 18 /
    /// macOS 15); `completion` gets the texts in order, or nil when translating failed.
    @ViewBuilder
    func prayerRequestTranslation(
        _ job: PrayerRequestTranslationJob?,
        completion: @escaping PrayerRequestTranslationCompletion
    ) -> some View {
        #if canImport(Translation)
        if #available(iOS 18, macOS 15, *) {
            modifier(PrayerRequestTranslationTask(job: job, completion: completion))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18, macOS 15, *)
private struct PrayerRequestTranslationTask: ViewModifier {
    let job: PrayerRequestTranslationJob?
    // Nonisolated so the app target (default main-actor isolation) keeps it Sendable when it is
    // handed to the nonisolated action below.
    nonisolated let completion: PrayerRequestTranslationCompletion
    @State private var configuration: TranslationSession.Configuration?
    /// The job whose action has been entered, so a job the task never picks up can be failed.
    @State private var startedJobID: UUID?

    /// How long a job may wait for `translationTask` to enter its action before it counts as
    /// failed. The action is entered right after the configuration changes; downloads happen
    /// inside it, so this does not limit how long a translation itself may take.
    private static let startGrace: Duration = .seconds(5)

    func body(content: Content) -> some View {
        content
            .translationTask(
                configuration,
                action: Self.action(
                    for: job, started: { startedJobID = $0 }, completion: completion)
            )
            .onChange(of: job?.id) {
                guard let job else { return }
                configuration = PrayerRequestTranslationTrigger.configuration(
                    after: configuration, source: job.source.locale, target: job.target.locale)
            }
            .task(id: job?.id) {
                // Never leave the sheet waiting on a job the translation task did not pick up.
                guard let job else { return }
                try? await Task.sleep(for: Self.startGrace)
                guard !Task.isCancelled, startedJobID != job.id else { return }
                completion(job, nil)
            }
    }

    /// The session is not Sendable, so the action is built outside the main actor and the session
    /// never leaves the task it is handed to; only the resulting strings go back to the sheet.
    nonisolated private static func action(
        for job: PrayerRequestTranslationJob?,
        started: @escaping @MainActor @Sendable (UUID) -> Void,
        completion: @escaping PrayerRequestTranslationCompletion
    ) -> (TranslationSession) async -> Void {
        { session in
            guard let job else { return }
            await started(job.id)
            let texts = try? await translate(job.texts, with: session)
            await completion(job, texts)
        }
    }

    /// Translates in one batch; the system asks to download missing languages and throws when
    /// that is declined. Results are matched back by index, not by arrival order.
    nonisolated private static func translate(
        _ texts: [String], with session: TranslationSession
    ) async throws -> [String] {
        let requests = texts.enumerated().map {
            TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
        }
        let responses = try await session.translations(from: requests)
        var byIndex: [Int: String] = [:]
        for response in responses {
            if let index = response.clientIdentifier.flatMap(Int.init) {
                byIndex[index] = response.targetText
            }
        }
        // A missing line would be shared untranslated but tagged as translated, so fail instead.
        return try texts.indices.map { index in
            guard let text = byIndex[index] else { throw IncompleteTranslation() }
            return text
        }
    }

    private struct IncompleteTranslation: Error {}
}

/// Chooses the configuration that makes `translationTask` run once more. The task re-runs only
/// when its configuration changes, and a fresh configuration for the same pair compares equal, so
/// a retry of the same pair invalidates the current one (bumping its version) instead.
@available(iOS 18, macOS 15, *)
enum PrayerRequestTranslationTrigger {
    static func configuration(
        after current: TranslationSession.Configuration?, source: Locale.Language,
        target: Locale.Language
    ) -> TranslationSession.Configuration {
        if var same = current, same.source == source, same.target == target {
            same.invalidate()
            return same
        }
        return TranslationSession.Configuration(source: source, target: target)
    }
}
#endif

#if DEBUG
#Preview("기도제목 나누기") {
    // Synthetic entry; without Apple Intelligence (or on older systems) it opens in manual mode.
    PrayerRequestShareSheet(
        entry: JournalEntryRecord(
            id: UUID(), kind: .diary, title: "수요일",
            body: "내일 친구가 면접을 본다. 마음이 많이 떨린다고 했다.", occurredAt: .now,
            originalTimeZone: nil, tags: [], isStarred: false, isPinned: false,
            details: EntryDetails(), sourceUUID: nil, sourceMetadata: nil,
            currentRevisionID: UUID(), updatedAt: .now, modifiedByDeviceID: "preview"))
}
#endif
