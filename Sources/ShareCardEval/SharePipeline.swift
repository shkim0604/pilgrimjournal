#if canImport(FoundationModels)
import Foundation
import FoundationModels

// Short fields only: long @Guide descriptions get copied into the output verbatim, and prose
// is asked for separately as free text (roadmap "1차 성능 테스트" findings 2).

@available(macOS 26, iOS 26, *)
@Generable
struct PrayerItemsDraft {
    @Guide(description: "기도제목 목록")
    var items: [PrayerItemDraft]
}

@available(macOS 26, iOS 26, *)
@Generable
struct PrayerItemDraft {
    @Guide(description: "한 줄 요약")
    var summary: String
    // Optional: with a required String the model stamped the entry date on every item (v1).
    @Guide(description: "본문의 마감 날짜 표현 그대로")
    var datePhrase: String?
    @Guide(description: "마감 날짜 YYYY-MM-DD")
    var date: String?
}

@available(macOS 26, iOS 26, *)
@Generable
struct BookFieldsDraft {
    @Guide(description: "책 제목")
    var title: String
    @Guide(description: "저자")
    var author: String
    @Guide(description: "본문 인용문 그대로, 없으면 빈 문자열")
    var quote: String
}

/// The pipeline the roadmap recommends: few-shot yes/no classification first, structured
/// output only for short fields, free text for prose, calendar hints computed in code, and
/// permissive guardrails with a violation treated as "skip".
@available(macOS 26, iOS 26, *)
final class SharePipeline {
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    // Greedy so reruns of the same prompt version compare. The response cap keeps a runaway
    // list from overflowing the ~4K context (v1: one call ran 54s and then failed).
    private let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: 600)
    private let classifierOptions = GenerationOptions(sampling: .greedy, maximumResponseTokens: 8)
    private let includeProse: Bool
    private var calls: [CallRecord] = []

    init(includeProse: Bool) {
        self.includeProse = includeProse
    }

    var availabilityProblem: String? {
        switch model.availability {
        case .available: nil
        case .unavailable(let reason): "온디바이스 모델을 쓸 수 없습니다: \(reason)"
        }
    }

    func run(_ entry: EvalEntry) async -> EntryResult {
        calls = []
        var prediction = Prediction()
        if entry.kind == .reading {
            await readBook(entry, into: &prediction)
        } else {
            await classifyAndExtract(entry, into: &prediction)
        }
        return EntryResult(
            id: entry.id,
            prediction: prediction,
            checks: EvalScorer.checks(for: entry, prediction),
            nameLeaks: EvalScorer.nameLeaks(entry.expected.thirdPartyNames, in: prediction.prose),
            calls: calls
        )
    }

    private func classifyAndExtract(_ entry: EvalEntry, into prediction: inout Prediction) async {
        prediction.hasPrayer = await classify("prayer?", SharePrompts.prayer, entry, &prediction)
        prediction.isTestimony = await classify(
            "testimony?", SharePrompts.testimony, entry, &prediction)
        prediction.mentionsThirdParty = await classify(
            "third-party?", SharePrompts.thirdParty, entry, &prediction)

        if prediction.hasPrayer == true {
            let draft = await structured(
                "prayer-items", PrayerItemsDraft.self,
                instructions: SharePrompts.extractionInstructions,
                prompt: SharePrompts.prayerItems(entry, hints: CalendarHints.text(for: entry.date)))
            prediction.prayerItems = (draft?.items ?? []).map { item in
                let phrase = item.datePhrase ?? ""
                return ExtractedPrayerItem(
                    entryDate: entry.date,
                    summary: item.summary,
                    datePhrase: phrase,
                    modelDate: item.date.flatMap(DayDate.init(iso:)),
                    codeDate: phrase.isEmpty
                        ? nil : DatePhraseResolver.resolve(phrase, from: entry.date)
                )
            }
            if includeProse {
                prediction.prose["prayerCard"] = await text(
                    "prayer-card", instructions: SharePrompts.cardInstructions,
                    prompt: SharePrompts.prayerCard(entry))
            }
        }
        if prediction.isTestimony == true, includeProse {
            prediction.prose["testimonyCard"] = await text(
                "testimony-card", instructions: SharePrompts.cardInstructions,
                prompt: SharePrompts.testimonyCard(entry))
        }
    }

    private func readBook(_ entry: EvalEntry, into prediction: inout Prediction) async {
        if let fields = await structured(
            "book-fields", BookFieldsDraft.self,
            instructions: SharePrompts.extractionInstructions,
            prompt: SharePrompts.bookFields(entry))
        {
            prediction.book = ExtractedBook(
                title: fields.title, author: fields.author, quote: fields.quote)
        }
        if includeProse {
            prediction.prose["bookCard"] = await text(
                "book-card", instructions: SharePrompts.cardInstructions,
                prompt: SharePrompts.bookCard(entry))
        }
    }

    private func classify(
        _ step: String, _ classifier: SharePrompts.Classifier, _ entry: EvalEntry,
        _ prediction: inout Prediction
    ) async -> Bool? {
        guard
            let answer = await text(
                step, instructions: SharePrompts.classifierInstructions,
                prompt: SharePrompts.classification(classifier, entry), options: classifierOptions)
        else { return nil }
        prediction.answers[step] = answer
        guard let value = EvalScorer.parseYesNo(answer) else {
            prediction.unparsedAnswers.append("\(step) \(answer)")
            return nil
        }
        return value
    }

    // Each call gets a fresh session so earlier entries never sit in the context window.

    private func text(
        _ step: String, instructions: String, prompt: String, options: GenerationOptions? = nil
    ) async -> String? {
        await timed(step) {
            let session = LanguageModelSession(model: self.model, instructions: instructions)
            return try await session.respond(to: prompt, options: options ?? self.options).content
        }
    }

    private func structured<Content: Generable>(
        _ step: String, _ type: Content.Type, instructions: String, prompt: String
    ) async -> Content? {
        await timed(step) {
            let session = LanguageModelSession(model: self.model, instructions: instructions)
            return try await session.respond(to: prompt, generating: type, options: self.options)
                .content
        }
    }

    private func timed<Value>(_ step: String, _ body: () async throws -> Value) async -> Value? {
        let clock = ContinuousClock()
        let start = clock.now
        let value: Value?
        let outcome: String
        do {
            value = try await body()
            outcome = "ok"
        } catch let error as LanguageModelSession.GenerationError {
            value = nil
            if case .guardrailViolation = error {
                outcome = "guardrail"
            } else {
                outcome = "error: \(error)"
            }
        } catch {
            value = nil
            outcome = "error: \(error)"
        }
        let elapsed = (clock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        calls.append(CallRecord(step: step, seconds: seconds, outcome: outcome))
        return value
    }
}
#endif
