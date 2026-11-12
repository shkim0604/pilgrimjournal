import Foundation

/// What code does with the model's answer: parse the lines, drop repeats, shorten the ending,
/// and move a line's `(누구/주제)` label between languages.
public enum PrayerRequestLines {
    /// The request lines of an extraction answer; empty for "없음".
    public static func parse(_ answer: String) -> [String] {
        answer.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let first = text.first, "-•*·".contains(first) else { return nil }
            let request = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return request.isEmpty ? nil : request
        }
    }

    /// True only for a clear "아니오": anything else (a guardrail skip, a stray word) lets the
    /// extraction run, so a broken gate never hides a diary that has something to pray for.
    public static func gateSaysNo(_ answer: String?) -> Bool {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return answer.hasPrefix("아니") || answer == "no" || answer.hasPrefix("no.")
    }

    /// Drops a line that repeats an earlier one (the model loops on some diaries, sometimes
    /// changing only the trailing `(누구/주제)` label) and keeps at most `limit`. The model does
    /// neither reliably when told to. Korean lines then go through `sharedEnding`; English
    /// ("Pray that …" is how an English request reads) has nothing to cut.
    public static func withoutRepeats(_ lines: [String], limit: Int = 3) -> [String] {
        var seen: Set<String> = []
        var kept: [String] = []
        for line in lines {
            guard seen.insert(repeatKey(line)).inserted else { continue }
            kept.append(line)
            if kept.count == limit { break }
        }
        return kept
    }

    /// "~하도록 기도해 주세요 (나/가정)" → "~하도록 (나/가정)". People sharing requests end at
    /// "~하도록" or "~주시길" and write 10~20자 (docs/roadmap.md), but asking the model for
    /// that ending made it stop mid-sentence ("팀장님께"), so it writes the long form and
    /// code shortens it.
    public static func sharedEnding(_ line: String) -> String {
        var body = line.trimmingCharacters(in: .whitespaces)
        var label = ""
        if body.hasSuffix(")"), let open = body.lastIndex(of: "(") {
            label = " " + body[open...]
            body = body[..<open].trimmingCharacters(in: .whitespaces)
        }
        while let last = body.last, ".!".contains(last) { body.removeLast() }
        let tails = ["기도해 주세요", "기도해주세요", "기도 부탁드립니다", "기도합니다", "기도해 주십시오"]
        for tail in tails where body.hasSuffix(tail) {
            let cut = body.dropLast(tail.count).trimmingCharacters(in: .whitespaces)
            // "건강을 위해 기도해 주세요" keeps reading as a request once cut; a bare
            // "기도해 주세요" would leave nothing.
            if cut.count >= 4 { body = cut }
            break
        }
        return body + label
    }

    private static func repeatKey(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            text = String(text[..<open])
        }
        return text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    // MARK: - Lines and labels across languages

    /// "문장 (누구/주제)" → the sentence and the label inside the brackets, if there is one.
    public static func splitLabel(_ line: String) -> (body: String, label: String?) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return (text, nil) }
        let label = text[text.index(after: open)..<text.index(before: text.endIndex)]
        return (text[..<open].trimmingCharacters(in: .whitespaces), String(label))
    }

    private static let topicPairs: [(ko: String, en: String)] = [
        ("건강", "health"), ("가정", "family"), ("직장", "work"), ("학업", "study"),
        ("재정", "finances"), ("관계", "relationships"), ("신앙", "faith"), ("진로", "career"),
    ]

    // The first pair for a word wins, so each side lists its most usual spelling first.
    private static let whoPairs: [(ko: String, en: String)] = [
        ("나", "me"), ("어머니", "mother"), ("엄마", "mom"), ("아버지", "father"),
        ("아빠", "dad"), ("남편", "husband"), ("아내", "wife"), ("아들", "son"), ("딸", "daughter"),
        ("친구", "friend"), ("동생", "younger sibling"), ("형제", "siblings"),
        ("부모님", "parents"), ("가족", "family"), ("상사", "boss"), ("팀장님", "manager"),
        ("동료", "coworker"), ("팀", "team"), ("직원", "employee"), ("교수님", "professor"),
        ("어머니", "mom"), ("아버지", "dad"), ("형제", "brother"), ("자매", "sister"),
    ]

    /// Moves a `누구/주제` label into the share language. A word code does not know (a name,
    /// a topic the model made up) is left as written.
    public static func translatedLabel(_ label: String, to language: RequestLanguage) -> String {
        let parts = label.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func swap(_ word: String, _ pairs: [(ko: String, en: String)]) -> String {
            let key = word.lowercased()
            switch language {
            case .korean: return pairs.first { $0.en == key }?.ko ?? word
            case .english: return pairs.first { $0.ko == key }?.en ?? word
            }
        }
        guard parts.count == 2 else {
            return parts.map { swap($0, whoPairs) }.joined(separator: "/")
        }
        return swap(parts[0], whoPairs) + "/" + swap(parts[1], topicPairs)
    }

    /// Cleans what a translator returns for one request so it reads like the others in that
    /// language: "Please pray that …" → "Pray that …"; a Korean sentence loses "제가" and its
    /// "기도해 주세요"-style tail when `cutEnding` is on.
    public static func polishTranslation(
        _ text: String, in language: RequestLanguage, cutEnding: Bool
    ) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch language {
        case .english:
            for lead in ["Please pray that ", "Please pray for "] where line.hasPrefix(lead) {
                line = "Pray" + line.dropFirst("Please pray".count)
            }
            while let last = line.last, ".".contains(last) { line.removeLast() }
        case .korean:
            for lead in ["제가 ", "저는 ", "내가 ", "나는 "] where line.hasPrefix(lead) {
                line = String(line.dropFirst(lead.count))
            }
            if cutEnding { line = sharedEnding(line) }
        }
        return line
    }
}
