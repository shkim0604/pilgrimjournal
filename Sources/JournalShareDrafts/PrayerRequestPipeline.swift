import Foundation

/// Gate → extract → tidy, over an injected model. Nothing here stores or logs diary text.
public struct PrayerRequestPipeline: Sendable {
    public static let bodyLimit = 3_000
    private static let gateTokens = 8
    private static let draftTokens = 600

    private let model: any ShareLanguageModel

    public init(model: any ShareLanguageModel) {
        self.model = model
    }

    public func drafts(for source: PrayerRequestSource) async -> PrayerRequestOutcome {
        let language = RequestLanguage.detect(source.title + "\n" + source.body)
        let body = String(source.body.prefix(Self.bodyLimit))

        func prompt(_ template: String) -> String {
            PrayerRequestPrompts.fill(
                template, title: source.title, date: source.dateText, body: body)
        }

        // A failing gate must not hide a diary that has something to pray for.
        let gate = try? await model.respond(
            instructions: PrayerRequestPrompts.gateInstructions(language),
            prompt: prompt(PrayerRequestPrompts.gateTemplate(language)),
            maximumTokens: Self.gateTokens)
        if PrayerRequestLines.gateSaysNo(gate) { return .nothingToPrayFor }
        // A dismissed sheet should not start a second, slower model call.
        if Task.isCancelled { return .noUsableAnswer }

        guard
            let answer = try? await model.respond(
                instructions: PrayerRequestPrompts.instructions(language),
                prompt: prompt(PrayerRequestPrompts.template(language)),
                maximumTokens: Self.draftTokens)
        else { return .noUsableAnswer }

        var lines = PrayerRequestLines.parse(answer)
        // A reply cut off by the token cap ends mid-sentence without its label.
        if lines.contains(where: { PrayerRequestLines.splitLabel($0).label != nil }),
            let last = lines.last, PrayerRequestLines.splitLabel(last).label == nil
        {
            lines.removeLast()
        }
        lines = PrayerRequestLines.withoutRepeats(lines)
        if language == .korean { lines = lines.map(PrayerRequestLines.sharedEnding) }

        // A line that was only a label ("(나/건강)") has no sentence to share.
        let drafts = lines.map { draft(from: $0, language: language) }.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return drafts.isEmpty ? .noUsableAnswer : .drafts(drafts)
    }

    private func draft(from line: String, language: RequestLanguage) -> PrayerRequestDraft {
        let (text, label) = PrayerRequestLines.splitLabel(line)
        var who: String?
        var topic: PrayerRequestTopic?
        if let label {
            let parts = label.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                who = parts[0].isEmpty ? nil : parts[0]
                topic = PrayerRequestTopic(label: parts[1])
            } else {
                who = parts.first.flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        return PrayerRequestDraft(text: text, language: language, topic: topic, who: who)
    }
}
