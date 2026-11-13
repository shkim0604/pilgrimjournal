import Foundation
import JournalShareDrafts
import XCTest

@testable import PilgrimJournal

/// Answers the gate and the extraction in order; with `held`, waits until `release()` so a test
/// can act while the model is still "thinking".
private actor FakeShareModel: ShareLanguageModel {
    private var answers: [String]
    private let held: Bool
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0

    init(answers: [String], held: Bool = false) {
        self.answers = answers
        self.held = held
    }

    func respond(instructions: String, prompt: String, maximumTokens: Int) async throws -> String {
        calls += 1
        if held && !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        return answers.isEmpty ? "" : answers.removeFirst()
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
final class PrayerRequestShareModelTests: XCTestCase {
    private let koreanSource = PrayerRequestSource(
        title: "수요일", dateText: "2026-11-11", body: "어머니가 수술을 앞두고 계시고 시험도 걱정된다.")

    private let twoRequests = """
        - 어머니가 회복하시도록 기도해 주세요 (어머니/건강)
        - 시험을 잘 준비하도록 기도해 주세요 (나/학업)
        """

    private func model(
        answers: [String], held: Bool = false, availability: ShareModelAvailability = .available
    ) -> (PrayerRequestShareModel, FakeShareModel) {
        let fake = FakeShareModel(answers: answers, held: held)
        let model = PrayerRequestShareModel(
            source: koreanSource, pipeline: PrayerRequestPipeline(model: fake),
            availability: availability)
        return (model, fake)
    }

    /// A ready model with two drafted rows (Korean).
    private func readyModel() async -> PrayerRequestShareModel {
        let (model, _) = model(answers: ["예", twoRequests])
        await model.start()
        return model
    }

    func testStartShowsDraftsSelected() async {
        let model = await readyModel()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(model.rows.allSatisfy { $0.isSelected && !$0.isEdited })
        XCTAssertEqual(model.shareLanguage, .korean)
        XCTAssertEqual(model.rows.first?.topic, .health)
    }

    func testUnavailableModelShowsManualFromTheStartWithoutSpinner() {
        let model = PrayerRequestShareModel(
            source: koreanSource, pipeline: nil, availability: .appleIntelligenceOff)
        XCTAssertEqual(model.phase, .manual(reason: .modelUnavailable(.appleIntelligenceOff)))
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertTrue(model.rows[0].isSelected)
    }

    func testPromptDateIsIsoInTheEntrysTimeZone() {
        // 2026-11-11 16:30 UTC is already the 12th in Seoul and still the 11th in Los Angeles.
        let date = Date(timeIntervalSince1970: 1_794_414_600)
        XCTAssertEqual(
            PrayerRequestShareSheet.promptDate(date, timeZoneIdentifier: "Asia/Seoul"),
            "2026-11-12")
        XCTAssertEqual(
            PrayerRequestShareSheet.promptDate(date, timeZoneIdentifier: "America/Los_Angeles"),
            "2026-11-11")
    }

    func testSecondStartChangesNothing() async {
        let (model, fake) = model(answers: ["예", twoRequests, "예", twoRequests])
        await model.start()
        let id = model.rows[0].id
        model.edit(id, text: "고친 문장")
        let rows = model.rows

        await model.start()

        XCTAssertEqual(model.rows, rows)
        XCTAssertEqual(model.phase, .ready)
        let calls = await fake.calls
        XCTAssertEqual(calls, 2)
    }

    func testUnavailableModelOpensManualWithOneEmptyRow() async {
        let model = PrayerRequestShareModel(
            source: koreanSource, pipeline: nil, availability: .appleIntelligenceOff)
        await model.start()
        XCTAssertEqual(model.phase, .manual(reason: .modelUnavailable(.appleIntelligenceOff)))
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows[0].text, "")
        XCTAssertTrue(model.rows[0].isSelected)
        XCTAssertEqual(model.rows[0].language, .korean)
    }

    func testUnavailableAvailabilityWithPipelineStillSkipsTheModel() async {
        let (model, fake) = model(answers: ["예", twoRequests], availability: .modelNotReady)
        await model.start()
        XCTAssertEqual(model.phase, .manual(reason: .modelUnavailable(.modelNotReady)))
        let calls = await fake.calls
        XCTAssertEqual(calls, 0)
    }

    func testNothingToPrayForOpensManual() async {
        let (model, _) = model(answers: ["아니오"])
        await model.start()
        XCTAssertEqual(model.phase, .manual(reason: .nothingToPrayFor))
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.rows[0].text, "")
    }

    func testNoUsableAnswerOpensManual() async {
        let (model, _) = model(answers: ["예", "없음"])
        await model.start()
        XCTAssertEqual(model.phase, .manual(reason: .noUsableAnswer))
        XCTAssertEqual(model.rows.count, 1)
    }

    func testEnglishDiaryManualRowUsesDetectedLanguage() async {
        let source = PrayerRequestSource(
            title: "Wednesday", dateText: "2026-11-11", body: "Worried about the exam.")
        let model = PrayerRequestShareModel(
            source: source, pipeline: nil, availability: .disabled)
        await model.start()
        XCTAssertEqual(model.shareLanguage, .english)
        XCTAssertEqual(model.rows[0].language, .english)
    }

    func testWriteManuallyDuringDraftingIgnoresLateDrafts() async {
        let (model, fake) = model(answers: ["예", twoRequests], held: true)
        let drafting = Task { await model.start() }
        while await fake.calls == 0 { await Task.yield() }

        model.writeManually()
        XCTAssertEqual(model.phase, .manual(reason: .userChoice))
        XCTAssertEqual(model.rows.count, 1)
        let manualRowID = model.rows[0].id

        await fake.release()
        await drafting.value

        XCTAssertEqual(model.phase, .manual(reason: .userChoice))
        XCTAssertEqual(model.rows.map(\.id), [manualRowID])
    }

    func testEditMarksRowEditedAndSetsText() async {
        let model = await readyModel()
        let id = model.rows[0].id
        model.edit(id, text: "어머니 수술이 잘 되도록")
        XCTAssertEqual(model.rows[0].text, "어머니 수술이 잘 되도록")
        XCTAssertTrue(model.rows[0].isEdited)
        XCTAssertFalse(model.rows[1].isEdited)
    }

    func testAddRowAppendsEmptySelectedRow() async {
        let model = await readyModel()
        model.addRow()
        XCTAssertEqual(model.rows.count, 3)
        XCTAssertEqual(model.rows[2].text, "")
        XCTAssertTrue(model.rows[2].isSelected)
        XCTAssertEqual(model.rows[2].language, model.shareLanguage)
    }

    func testTranslationRequestSkipsRowsAlreadyInTarget() async {
        let model = await readyModel()
        XCTAssertNil(model.translationRequest(to: .korean))

        let request = model.translationRequest(to: .english)
        XCTAssertEqual(request?.from, .korean)
        XCTAssertEqual(request?.ids, model.rows.map(\.id))
        // Shortened Korean lines get their request tail back for the translator.
        XCTAssertEqual(
            request?.texts,
            model.rows.map { PrayerRequestLines.translationInput($0.text, from: .korean) })
    }

    func testTranslationRequestIgnoresEmptyRowsAndRowsInTarget() async {
        let model = await readyModel()
        model.addRow()
        let request = model.translationRequest(to: .english)
        XCTAssertEqual(request?.ids.count, 2)

        model.applyTranslation(
            ["Pray that mom recovers", "Pray for the exam"], for: request!.ids, to: .english)
        // Both drafted rows are English now; the empty added row is still empty, so not pending.
        XCTAssertNil(model.translationRequest(to: .english))
    }

    func testApplyTranslationPolishesAndSetsLanguage() async {
        let model = await readyModel()
        let request = model.translationRequest(to: .english)!
        model.applyTranslation(
            ["Please pray that mom recovers.", "Please pray for my exam."],
            for: request.ids, to: .english)
        XCTAssertEqual(model.rows[0].text, "Pray that mom recovers")
        XCTAssertEqual(model.rows[1].text, "Pray for my exam")
        XCTAssertTrue(model.rows.allSatisfy { $0.language == .english })
        XCTAssertEqual(model.shareLanguage, .english)
        XCTAssertNil(model.notice)
    }

    func testRowEditedBeforeAskingIsStillTranslated() async {
        let model = await readyModel()
        model.edit(model.rows[0].id, text: "어머니가 건강하시도록")
        let request = model.translationRequest(to: .english)!
        XCTAssertTrue(request.ids.contains(model.rows[0].id))
        model.applyTranslation(
            ["Please pray that mom stays well.", "Please pray for my exam."],
            for: request.ids, to: .english)
        XCTAssertEqual(model.rows[0].text, "Pray that mom stays well")
    }

    func testEditedRowIsNotOverwrittenByTranslation() async {
        let model = await readyModel()
        let request = model.translationRequest(to: .english)!
        // The person types into the first row while the translation is in flight.
        model.edit(model.rows[0].id, text: "어머니 수술이 잘 되도록")
        model.applyTranslation(
            ["Please pray that mom recovers.", "Please pray for my exam."],
            for: request.ids, to: .english)
        XCTAssertEqual(model.rows[0].text, "어머니 수술이 잘 되도록")
        XCTAssertEqual(model.rows[0].language, .korean)
        XCTAssertEqual(model.rows[1].text, "Pray for my exam")
        XCTAssertEqual(model.rows[1].language, .english)
    }

    func testApplyTranslationSkipsRowsOutsideThePendingRequest() async {
        let model = await readyModel()
        let request = model.translationRequest(to: .english)!
        // A row typed after the request was made is not part of it, even if a result names it.
        model.addRow()
        let typedID = model.rows[2].id
        model.edit(typedID, text: "새로 쓴 기도제목")
        model.applyTranslation(
            ["Please pray that mom recovers.", "Please pray for my exam.", "Stale result."],
            for: request.ids + [typedID], to: .english)
        XCTAssertEqual(model.rows[2].text, "새로 쓴 기도제목")
        XCTAssertEqual(model.rows[2].language, .korean)

        // A late, second result for the same request finds no pending request and changes nothing.
        let afterFirst = model.rows
        model.applyTranslation(["Late one.", "Late two."], for: request.ids, to: .english)
        XCTAssertEqual(model.rows, afterFirst)
    }

    func testApplyTranslationRetagsEmptyRowsToTarget() async {
        let model = await readyModel()
        model.addRow()
        let request = model.translationRequest(to: .english)!
        model.applyTranslation(
            ["Please pray that mom recovers.", "Please pray for my exam."],
            for: request.ids, to: .english)
        // Text typed into the empty row afterwards is already in the share language.
        XCTAssertEqual(model.rows[2].language, .english)
        model.edit(model.rows[2].id, text: "Pray for my sister")
        XCTAssertNil(model.translationRequest(to: .english))
    }

    func testSwitchingLanguageWithNothingToTranslateRetagsEmptyRows() async {
        let model = PrayerRequestShareModel(
            source: koreanSource, pipeline: nil, availability: .disabled)
        await model.start()
        // The sheet applies an empty result when there is nothing to translate.
        XCTAssertNil(model.translationRequest(to: .english))
        model.applyTranslation([], for: [], to: .english)
        XCTAssertEqual(model.shareLanguage, .english)
        XCTAssertEqual(model.rows[0].language, .english)
    }

    func testTranslationFailureKeepsTextAndSetsNotice() async {
        let model = await readyModel()
        let before = model.rows
        model.translationFailed("번역하지 못했어요")
        XCTAssertEqual(model.notice, "번역하지 못했어요")
        XCTAssertEqual(model.rows, before)
        XCTAssertEqual(model.shareLanguage, .korean)
    }

    func testShareTextUsesOnlySelectedNonEmptyRows() async {
        let model = await readyModel()
        model.addRow() // empty, selected
        model.rows[1].isSelected = false
        XCTAssertEqual(model.shareText, model.rows[0].text)

        model.rows[1].isSelected = true
        let expected = PrayerRequestShareText.text(
            for: model.rows.filter(\.isSelected).map {
                PrayerRequestDraft(id: $0.id, text: $0.text, language: $0.language)
            })
        XCTAssertEqual(model.shareText, expected)
        XCTAssertFalse(model.shareText.contains("\n\n"))
    }

    func testCanShareIsFalseWithNothingSelected() async {
        let model = await readyModel()
        XCTAssertTrue(model.canShare)
        for index in model.rows.indices { model.rows[index].isSelected = false }
        XCTAssertFalse(model.canShare)
    }

    func testHasEditsTracksEditsAndTypedManualRows() async {
        let model = await readyModel()
        XCTAssertFalse(model.hasEdits)
        model.edit(model.rows[0].id, text: "고친 문장")
        XCTAssertTrue(model.hasEdits)

        let manual = PrayerRequestShareModel(
            source: koreanSource, pipeline: nil, availability: .disabled)
        await manual.start()
        XCTAssertFalse(manual.hasEdits) // the empty starter row is not an edit
        manual.edit(manual.rows[0].id, text: "직접 쓴 기도제목")
        XCTAssertTrue(manual.hasEdits)
    }
}
