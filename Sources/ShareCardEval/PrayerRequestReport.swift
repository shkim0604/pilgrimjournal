import Foundation

/// One prompt's answer for one diary in the `--prayer-requests` review.
struct PrayerDraft: Codable, Sendable {
    /// The model's raw answer; nil when the call was skipped (guardrail) or failed.
    let text: String?
    /// The request lines parsed from a list answer (only the new prompt answers as a list).
    let lines: [String]
    let seconds: Double
    let outcome: String
    /// Third-party names from the diary that survived into the answer.
    let leakedNames: [String]
}

struct PrayerDiaryResult: Codable, Sendable {
    let id: String
    let date: String
    let title: String
    let body: String
    let points: [String]
    let names: [String]
    /// The 2026-10-15.2 `prayerCard` prompt, for comparison.
    let previous: PrayerDraft
    /// The `prayerRequests` prompt.
    let current: PrayerDraft
}

/// What `--prayer-requests --json` writes; the review page embeds it as-is.
struct PrayerRequestRun: Codable, Sendable {
    let promptVersion: String
    let previousPromptVersion: String
    let model: String
    let machine: String
    let osVersion: String
    let generatedAt: Date
    let diaries: [PrayerDiaryResult]
}

enum PrayerRequestPrinter {
    static func lines(for result: PrayerDiaryResult) -> [String] {
        var lines = ["", "== \(result.id) · \(result.title) (\(result.date))"]
        lines.append(
            "  기대: " + (result.points.isEmpty ? "없음" : result.points.joined(separator: " / ")))
        lines.append("  [이전 \(String(format: "%.1fs", result.previous.seconds))]")
        lines.append(indented(result.previous.text ?? "(\(result.previous.outcome))"))
        lines.append("  [새 \(String(format: "%.1fs", result.current.seconds))]")
        lines.append(indented(result.current.text ?? "(\(result.current.outcome))"))
        return lines
    }

    private static func indented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
            .joined(separator: "\n")
    }
}
