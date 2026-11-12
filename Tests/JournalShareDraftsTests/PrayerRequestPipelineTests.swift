import Foundation
import XCTest

@testable import JournalShareDrafts

/// Answers the gate call first and the draft call second, and records what it was asked.
private actor FakeModel: ShareLanguageModel {
    struct Call: Equatable {
        let instructions: String
        let prompt: String
        let maximumTokens: Int
    }

    struct Failure: Error {}

    private var answers: [Result<String, Failure>]
    private(set) var calls: [Call] = []

    init(gate: Result<String, Failure>, draft: Result<String, Failure> = .success("")) {
        answers = [gate, draft]
    }

    func respond(instructions: String, prompt: String, maximumTokens: Int) async throws -> String {
        calls.append(Call(instructions: instructions, prompt: prompt, maximumTokens: maximumTokens))
        guard !answers.isEmpty else { throw Failure() }
        return try answers.removeFirst().get()
    }
}

final class PrayerRequestPipelineTests: XCTestCase {
    private func run(
        _ model: FakeModel, title: String = "오늘", body: String = "어머니 검사 결과를 기다린다."
    ) async -> PrayerRequestOutcome {
        await PrayerRequestPipeline(model: model).drafts(
            for: PrayerRequestSource(title: title, dateText: "2026-11-11", body: body))
    }

    private func drafts(_ outcome: PrayerRequestOutcome) -> [PrayerRequestDraft] {
        if case .drafts(let drafts) = outcome { return drafts }
        XCTFail("expected drafts, got \(outcome)")
        return []
    }

    func testKoreanDiaryBecomesTidiedDraftsWithTopics() async {
        let model = FakeModel(
            gate: .success("예"),
            draft: .success(
                "- 어머니 검사 결과가 좋도록 기도해 주세요 (어머니/건강)\n- 동생과 다시 이야기하도록 기도해 주세요 (나/관계)"
            ))
        let found = drafts(await run(model))
        XCTAssertEqual(found.map(\.text), ["어머니 검사 결과가 좋도록", "동생과 다시 이야기하도록"])
        XCTAssertEqual(found.map(\.topic), [.health, .relationships])
        XCTAssertEqual(found.map(\.who), ["어머니", "나"])
        XCTAssertEqual(found.map(\.language), [.korean, .korean])
        let calls = await model.calls
        XCTAssertEqual(calls.map(\.maximumTokens), [8, 600])
        XCTAssertEqual(calls[0].instructions, PrayerRequestPrompts.gateInstructions(.korean))
        XCTAssertEqual(calls[1].instructions, PrayerRequestPrompts.instructions(.korean))
    }

    func testEnglishDiaryUsesEnglishPromptsAndKeepsPrayThat() async {
        let model = FakeModel(
            gate: .success("Yes"),
            draft: .success("- Pray that the surgery goes well (mother/health)"))
        let found = drafts(
            await run(model, title: "Monday", body: "Mom has surgery on Friday. I am worried."))
        XCTAssertEqual(found.first?.text, "Pray that the surgery goes well")
        XCTAssertEqual(found.first?.language, .english)
        XCTAssertEqual(found.first?.topic, .health)
        XCTAssertEqual(found.first?.who, "mother")
        let calls = await model.calls
        XCTAssertEqual(calls[0].instructions, PrayerRequestPrompts.gateInstructions(.english))
        XCTAssertEqual(calls[1].instructions, PrayerRequestPrompts.instructions(.english))
    }

    func testGateNoSkipsTheDraftCall() async {
        let model = FakeModel(gate: .success("아니오"))
        let outcome = await run(model)
        XCTAssertEqual(outcome, .nothingToPrayFor)
        let count = await model.calls.count
        XCTAssertEqual(count, 1)
    }

    func testGateFailureStillDrafts() async {
        let model = FakeModel(
            gate: .failure(.init()), draft: .success("- 건강을 위해 기도해 주세요 (나/건강)"))
        let found = drafts(await run(model))
        XCTAssertEqual(found.count, 1)
    }

    func testLongBodyIsCutToTheLimit() async {
        let model = FakeModel(gate: .success("아니오"))
        _ = await run(model, body: String(repeating: "뷁", count: 10_000))
        let prompt = await model.calls[0].prompt
        XCTAssertEqual(prompt.filter { $0 == "뷁" }.count, PrayerRequestPipeline.bodyLimit)
    }

    func testLoopedAnswerKeepsThreeDistinctLines() async {
        let loop = Array(repeating: "- 어머니 건강을 위해 기도해 주세요 (어머니/건강)", count: 40)
        let others = [
            "- 직장 일이 잘 풀리도록 기도해 주세요 (나/직장)",
            "- 동생과 화해하도록 기도해 주세요 (나/관계)",
        ]
        let model = FakeModel(
            gate: .success("예"), draft: .success((loop + others).joined(separator: "\n")))
        let found = drafts(await run(model))
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(Set(found.map(\.text)).count, 3)
    }

    func testAnswerWithoutBulletsIsNoUsableAnswer() async {
        for answer in ["없음", "", "기도할 내용이 여러 가지 있습니다."] {
            let model = FakeModel(gate: .success("예"), draft: .success(answer))
            let outcome = await run(model)
            XCTAssertEqual(outcome, .noUsableAnswer, "answer: \(answer)")
        }
    }

    func testTruncatedLastLineIsDropped() async {
        let model = FakeModel(
            gate: .success("Yes"),
            draft: .success(
                "- Pray that the surgery goes well (mother/health)\n- Pray that I find a"))
        let found = drafts(await run(model, title: "Monday", body: "Surgery on Friday."))
        XCTAssertEqual(found.map(\.text), ["Pray that the surgery goes well"])
    }

    func testUnknownTopicLeavesTopicNil() async {
        let model = FakeModel(
            gate: .success("예"), draft: .success("- 가게가 잘 되도록 기도해 주세요 (나/가게)"))
        let found = drafts(await run(model))
        XCTAssertNil(found.first?.topic)
        XCTAssertEqual(found.first?.who, "나")
        XCTAssertEqual(found.first?.text, "가게가 잘 되도록")
    }

    func testDraftCallFailureIsNoUsableAnswer() async {
        let model = FakeModel(gate: .success("예"), draft: .failure(.init()))
        let outcome = await run(model)
        XCTAssertEqual(outcome, .noUsableAnswer)
    }
}
