import Foundation

/// The plain text that goes to the group for the requests the person kept selected.
public enum PrayerRequestShareText {
    /// Sentences only: no labels, title, date or app name, so the message reads as written by hand.
    public static func text(for drafts: [PrayerRequestDraft]) -> String {
        let sentences = drafts.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if sentences.count == 1 { return sentences[0] }
        return sentences.map { "• " + $0 }.joined(separator: "\n")
    }
}
