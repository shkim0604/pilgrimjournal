import Combine
import Foundation
import JournalShareDrafts

/// Translates prayer-request sentences; the app implements it over Apple's Translation framework.
protocol ShareTextTranslating: Sendable {
    func translate(_ texts: [String], from: RequestLanguage, to: RequestLanguage) async throws
        -> [String]
}

/// State of the "share prayer requests" sheet. Everything lives in memory only: no diary text,
/// draft or translation is stored, synced or logged.
@MainActor
final class PrayerRequestShareModel: ObservableObject {
    enum ManualReason: Equatable {
        case modelUnavailable(ShareModelAvailability)
        case nothingToPrayFor
        case noUsableAnswer
        case userChoice
    }

    enum Phase: Equatable {
        case drafting
        case ready
        case manual(reason: ManualReason)
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        var text: String
        var language: RequestLanguage
        var topic: PrayerRequestTopic?
        var isSelected: Bool
        var isEdited: Bool
    }

    @Published private(set) var phase: Phase = .drafting
    @Published var rows: [Row] = []
    @Published private(set) var shareLanguage: RequestLanguage
    @Published private(set) var notice: String?

    private let source: PrayerRequestSource
    private let pipeline: PrayerRequestPipeline?
    private let availability: ShareModelAvailability
    /// Bumped by `start()` and `writeManually()`; a draft result only lands if it is unchanged.
    private var generation = 0
    /// The sheet's `.task` can run again (for example when the view reappears); drafting must
    /// not restart and overwrite rows the person has edited.
    private var hasStarted = false
    /// Rows the person created (starter row, "add a line"), as opposed to drafted ones.
    private var addedRowIDs: Set<UUID> = []
    /// Each row's text when a translation was requested, so one edited meanwhile is left alone.
    private var translationSnapshot: [UUID: String] = [:]

    init(
        source: PrayerRequestSource, pipeline: PrayerRequestPipeline?,
        availability: ShareModelAvailability
    ) {
        self.source = source
        self.pipeline = pipeline
        self.availability = availability
        shareLanguage = RequestLanguage.detect(source.title + "\n" + source.body)
        // Without a usable model there is nothing to wait for: open the write-by-hand form at once
        // instead of flashing a spinner.
        if pipeline == nil || availability != .available {
            phase = .manual(reason: .modelUnavailable(availability))
            addRow()
        }
    }

    // MARK: - Drafting

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        generation += 1
        let mine = generation
        guard let pipeline, availability == .available else { return }
        phase = .drafting
        let outcome = await pipeline.drafts(for: source)
        // A cancelled task means the sheet is gone; its result has nowhere to land.
        guard mine == generation, !Task.isCancelled else { return }

        switch outcome {
        case .drafts(let drafts):
            rows = drafts.map {
                Row(
                    id: $0.id, text: $0.text, language: $0.language, topic: $0.topic,
                    isSelected: true, isEdited: false)
            }
            if let language = drafts.first?.language { shareLanguage = language }
            phase = .ready
        case .nothingToPrayFor:
            openManual(.nothingToPrayFor)
        case .noUsableAnswer:
            openManual(.noUsableAnswer)
        }
    }

    func writeManually() {
        generation += 1
        openManual(.userChoice)
    }

    private func openManual(_ reason: ManualReason) {
        phase = .manual(reason: reason)
        if rows.isEmpty { addRow() }
    }

    // MARK: - Rows

    func addRow() {
        let row = Row(
            id: UUID(), text: "", language: shareLanguage, topic: nil, isSelected: true,
            isEdited: false)
        addedRowIDs.insert(row.id)
        rows.append(row)
    }

    func edit(_ id: UUID, text: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].text = text
        rows[index].isEdited = true
    }

    // MARK: - Translation

    /// The rows to translate into `target`, or nil when every filled row is already in it.
    func translationRequest(
        to target: RequestLanguage
    ) -> (texts: [String], ids: [UUID], from: RequestLanguage)? {
        let pending = rows.filter {
            $0.language != target
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Rows needing translation share one language in practice; if not, the first row's wins.
        guard let source = pending.first?.language else { return nil }
        let chosen = pending.filter { $0.language == source }
        translationSnapshot = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.text) })
        return (
            chosen.map { PrayerRequestLines.translationInput($0.text, from: source) },
            chosen.map(\.id), source
        )
    }

    func applyTranslation(_ texts: [String], for ids: [UUID], to target: RequestLanguage) {
        // Only rows of the pending request are replaced: a late or overlapping result finds no
        // snapshot for its rows and leaves them alone.
        for (id, translated) in zip(ids, texts) {
            guard let index = rows.firstIndex(where: { $0.id == id }),
                let asked = translationSnapshot[id], rows[index].text == asked
            else { continue }
            rows[index].text = PrayerRequestLines.polishTranslation(
                translated, in: target, cutEnding: true)
            rows[index].language = target
        }
        // Empty rows hold nothing to translate; what is typed into them next is the new language.
        for index in rows.indices
        where rows[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows[index].language = target
        }
        translationSnapshot = [:]
        shareLanguage = target
        notice = nil
    }

    func translationFailed(_ message: String) {
        translationSnapshot = [:]
        notice = message
    }

    // MARK: - Result

    var shareText: String {
        PrayerRequestShareText.text(
            for: rows.filter(\.isSelected).map {
                PrayerRequestDraft(id: $0.id, text: $0.text, language: $0.language, topic: $0.topic)
            })
    }

    var canShare: Bool { !shareText.isEmpty }

    var hasEdits: Bool {
        rows.contains {
            $0.isEdited
                || (addedRowIDs.contains($0.id)
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
