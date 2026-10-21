import Foundation

/// One model call, timed. `outcome` is "ok", "guardrail" (treated as "skip the
/// recommendation", as the app will) or "error: …".
struct CallRecord: Codable, Sendable {
    let step: String
    let seconds: Double
    let outcome: String
}

struct ExtractedPrayerItem: Codable, Sendable {
    let entryDate: DayDate
    let summary: String
    let datePhrase: String
    /// The model's own YYYY-MM-DD (computed with the calendar hints).
    let modelDate: DayDate?
    /// `DatePhraseResolver` applied to `datePhrase`.
    let codeDate: DayDate?

    /// What the app would show: the code's reading of the phrase, else the model's date — and
    /// only if it is after the entry date, since a deadline lies ahead. (v1 showed the model
    /// tagging items with the entry date or "지난주".)
    var finalDate: DayDate? {
        (codeDate ?? modelDate).flatMap { $0 > entryDate ? $0 : nil }
    }
}

struct ExtractedBook: Codable, Sendable {
    let title: String
    let author: String
    let quote: String
}

/// Everything the pipeline produced for one entry. A nil classification means the step was
/// skipped (guardrail or error); scoring treats that as "no", like the app would.
struct Prediction: Codable, Sendable {
    var hasPrayer: Bool?
    var isTestimony: Bool?
    var mentionsThirdParty: Bool?
    var prayerItems: [ExtractedPrayerItem] = []
    var book: ExtractedBook?
    var prose: [String: String] = [:]
    /// Raw yes/no classifier answers by step.
    var answers: [String: String] = [:]
    var unparsedAnswers: [String] = []
}

struct Check: Codable, Sendable {
    let name: String
    let passed: Bool
    let detail: String
    /// Diagnostic checks are reported but left out of the score.
    let scored: Bool
}

struct EntryResult: Codable, Sendable {
    let id: String
    let prediction: Prediction
    let checks: [Check]
    let nameLeaks: [String]
    let calls: [CallRecord]

    var seconds: Double { calls.reduce(0) { $0 + $1.seconds } }
    var passed: Bool { checks.allSatisfy { !$0.scored || $0.passed } }
}

enum CheckName {
    static let prayer = "기도제목 여부"
    static let testimony = "간증 여부"
    static let thirdParty = "제3자 사정"
    static let deadlines = "데드라인"
    static let modelOnlyDeadlines = "데드라인(모델 날짜만)"
    static let items = "기도제목 개수"
    static let bookTitle = "책 제목"
    static let bookAuthor = "저자"
    static let bookQuote = "인용문"

    static let reportOrder = [
        prayer, testimony, thirdParty, deadlines, items, bookTitle, bookAuthor, bookQuote,
        modelOnlyDeadlines,
    ]
}

enum EvalScorer {
    static func parseYesNo(_ answer: String) -> Bool? {
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("답") { text = String(text.dropFirst()) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if text.hasPrefix("아니") || text.hasPrefix("no") { return false }
        if text.hasPrefix("예") || text.hasPrefix("네") || text.hasPrefix("yes") { return true }
        return nil
    }

    static func checks(for entry: EvalEntry, _ prediction: Prediction) -> [Check] {
        let expected = entry.expected
        if let book = expected.book {
            let got = prediction.book
            return [
                textCheck(CheckName.bookTitle, expected: book.title, got: got?.title),
                textCheck(CheckName.bookAuthor, expected: book.author, got: got?.author),
                textCheck(CheckName.bookQuote, expected: book.quote, got: got?.quote),
            ]
        }

        var checks = [
            boolCheck(CheckName.prayer, expected.hasPrayer, prediction.hasPrayer),
            boolCheck(CheckName.testimony, expected.isTestimony, prediction.isTestimony),
            boolCheck(
                CheckName.thirdParty, expected.mentionsThirdParty, prediction.mentionsThirdParty),
        ]
        guard expected.hasPrayer else { return checks }

        let wanted = Set(expected.deadlines.map(\.date))
        checks.append(
            dateCheck(
                CheckName.deadlines, wanted, Set(prediction.prayerItems.compactMap(\.finalDate)),
                scored: true))
        checks.append(
            dateCheck(
                CheckName.modelOnlyDeadlines, wanted,
                Set(prediction.prayerItems.compactMap(\.modelDate)), scored: false))
        if let minimum = expected.minPrayerItems {
            let count = prediction.prayerItems.count
            checks.append(
                Check(
                    name: CheckName.items, passed: count >= minimum,
                    detail: "기대 ≥\(minimum) / 결과 \(count)", scored: true))
        }
        return checks
    }

    /// Third-party names that survived into a share card. ASCII names match whole words only,
    /// so "J" does not match inside an English word.
    static func nameLeaks(_ names: [String], in prose: [String: String]) -> [String] {
        let text = prose.values.joined(separator: "\n")
        return names.filter { name in
            if name.allSatisfy({ $0.isASCII && $0.isLetter }) {
                let pattern =
                    "(?<![A-Za-z])\(NSRegularExpression.escapedPattern(for: name))(?![A-Za-z])"
                return text.range(of: pattern, options: .regularExpression) != nil
            }
            return text.contains(name)
        }
    }

    private static func boolCheck(_ name: String, _ expected: Bool, _ got: Bool?) -> Check {
        let value = got ?? false
        return Check(
            name: name, passed: value == expected,
            detail: "기대 \(yesNo(expected)) / 결과 \(got.map(yesNo) ?? "건너뜀")", scored: true)
    }

    private static func dateCheck(
        _ name: String, _ expected: Set<DayDate>, _ got: Set<DayDate>, scored: Bool
    ) -> Check {
        Check(
            name: name, passed: expected == got,
            detail: "기대 \(list(expected)) / 결과 \(list(got))", scored: scored)
    }

    private static func textCheck(_ name: String, expected: String, got: String?) -> Check {
        let passed = got.map { normalized($0).contains(normalized(expected)) } ?? false
        return Check(
            name: name, passed: passed, detail: "기대 \(expected) / 결과 \(got ?? "건너뜀")",
            scored: true)
    }

    /// Lowercased with spaces, quotes and punctuation removed, so 『광야의 식탁』 matches 광야의 식탁.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func yesNo(_ value: Bool) -> String { value ? "예" : "아니오" }

    private static func list(_ dates: Set<DayDate>) -> String {
        "[" + dates.sorted().map(\.description).joined(separator: ", ") + "]"
    }
}

struct RunReport: Codable, Sendable {
    let promptVersion: String
    let startedAt: Date
    let machine: String
    let osVersion: String
    let entries: [EntryResult]
}

enum ReportPrinter {
    static func line(for result: EntryResult) -> String {
        let marks = result.checks.filter(\.scored).map { "\($0.passed ? "✓" : "✗")\($0.name)" }
        let leaks =
            result.nameLeaks.isEmpty ? "" : "  이름 노출: \(result.nameLeaks.joined(separator: ","))"
        return "[\(result.passed ? "PASS" : "FAIL")] \(result.id.padding(30)) "
            + "\(seconds(result.seconds).leftPadding(6)) (\(result.calls.count)회)  "
            + marks.joined(separator: " ") + leaks
    }

    static func failures(for result: EntryResult) -> [String] {
        result.checks.filter { !$0.passed }.map {
            "    \($0.scored ? "✗" : "·") \($0.name): \($0.detail)"
        }
    }

    static func summary(_ report: RunReport) -> String {
        let results = report.entries
        let checks = results.flatMap(\.checks)
        let scored = checks.filter(\.scored)
        let passed = scored.filter(\.passed).count
        var lines = [
            "",
            "== 요약 (프롬프트 \(report.promptVersion), \(report.machine), macOS \(report.osVersion)) ==",
            "점수: \(passed)/\(scored.count) 검사 통과 (\(percent(passed, scored.count)))",
            "기록 전체 통과: \(results.filter(\.passed).count)/\(results.count)",
        ]
        for name in CheckName.reportOrder {
            let group = checks.filter { $0.name == name }
            guard !group.isEmpty else { continue }
            let ok = group.filter(\.passed).count
            let note = group.first!.scored ? "" : "  (참고용, 점수 제외)"
            lines.append("  \(name.padding(18)) \(ok)/\(group.count)\(note)")
        }

        let calls = results.flatMap(\.calls)
        let latencies = calls.map(\.seconds).sorted()
        if let first = calls.first, !latencies.isEmpty {
            lines.append(
                "지연: 호출 \(calls.count)회, 중앙값 \(seconds(quantile(latencies, 0.5))), "
                    + "p90 \(seconds(quantile(latencies, 0.9))), 최대 \(seconds(latencies.last!)), "
                    + "첫 호출 \(seconds(first.seconds)), 합계 \(seconds(latencies.reduce(0, +)))")
        }
        let guardrails = calls.filter { $0.outcome == "guardrail" }.count
        let errors = calls.filter { $0.outcome.hasPrefix("error") }.count
        let unparsed = results.flatMap(\.prediction.unparsedAnswers).count
        lines.append("guardrail 건너뜀 \(guardrails)회, 오류 \(errors)회, 예/아니오 해석 실패 \(unparsed)회")
        let leaks = results.filter { !$0.nameLeaks.isEmpty }.map(\.id)
        lines.append("카드에 남은 제3자 이름 (참고용): \(leaks.isEmpty ? "없음" : leaks.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }

    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.1fs", value) }

    private static func percent(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "-" : String(format: "%.1f%%", Double(part) / Double(whole) * 100)
    }
}

extension String {
    fileprivate func padding(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }

    fileprivate func leftPadding(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
