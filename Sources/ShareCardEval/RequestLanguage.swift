import Foundation

/// The language a diary is written in, and the language its prayer requests are shared in.
/// A diary is processed in its own language (Korean diary → Korean prompt, English diary →
/// English prompt): sending Korean diaries through English read better line by line but lost
/// names and 동생/형 on the way back (docs/roadmap.md). The share language is a separate,
/// later choice, made by translating the finished lines.
enum RequestLanguage: String, Codable, Sendable, CaseIterable {
    case korean = "ko"
    case english = "en"

    /// Korean when at least a third of the letters are Hangul, so a Korean diary full of
    /// English work terms ("Launch week") still counts as Korean.
    static func detect(_ text: String) -> RequestLanguage {
        var hangul = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        return hangul * 3 >= hangul + latin && hangul > 0 ? .korean : .english
    }

    var locale: Locale.Language { Locale.Language(identifier: rawValue) }
}

extension SharePrompts {
    // MARK: - English diaries

    // The English twin of `prayerRequestInstructions`, without the no-names line (names are
    // fine in a private group; the person confirms before sharing).
    static let prayerRequestInstructionsEnglish = """
        Read the diary and write prayer requests the writer could share with a small group.
        - Write only what the writer worries about, hopes for, or is facing. One line per separate matter. 1 to 3 lines.
        - Format: '- Pray that ... (who/topic)'
        - who: the person being prayed for. Use 'me' for the writer; otherwise a relationship such as 'mother', 'friend', 'son'.
        - topic is exactly one of: health, family, work, study, finances, relationships, faith, career
        - Do not repeat the same matter. If there is only one, write one line.

        Example
        Diary: I am moving next Wednesday. I have not even packed half. Yujin's family offered to help, but I am worried because Yujin's back is bad.
        Answer:
        - Pray that the move next Wednesday goes smoothly without accidents (me/family)
        - Pray that my friend who is helping us move recovers from back pain (friend/health)
        """

    static let prayerRequestTemplateEnglish = """
        Diary ({날짜}):
        {제목}
        {본문}

        Write the prayer requests for this diary following the rules.
        Answer:
        """

    static let prayerRequestGateInstructionsEnglish =
        "You classify personal diary entries. Answer the question with one word only: Yes or No."

    static let prayerRequestGateEnglish = """
        Something worth asking prayer for is a worry, pain, conflict, an important decision, a big event ahead such as an exam, surgery or a move, or a deep longing, for the writer or someone close to them.
        An ordinary, pleasant day of resting, eating, cleaning, traveling or seeing friends is 'No'. A light wish such as 'I want to go again' is also 'No'.

        Example: "Mom's surgery is next week and I cannot sleep." -> Yes
        Example: "Read magazines at the library and bought a pastry on the way home." -> No
        Example: "Got yelled at again at work. I wonder if I should quit." -> Yes
        Example: "Went to the beach with friends. The food was great. I want to go again." -> No

        Diary:
        {제목}
        {본문}

        Question: Does this diary contain a worry or a deep longing worth asking prayer for? Answer only Yes or No.
        Answer:
        """

    static func requestInstructions(_ language: RequestLanguage) -> String {
        language == .korean ? prayerRequestInstructions : prayerRequestInstructionsEnglish
    }

    static func requestTemplate(_ language: RequestLanguage) -> String {
        language == .korean ? prayerRequestTemplate : prayerRequestTemplateEnglish
    }

    static func gateInstructions(_ language: RequestLanguage) -> String {
        language == .korean ? prayerRequestGateInstructions : prayerRequestGateInstructionsEnglish
    }

    static func gateTemplate(_ language: RequestLanguage) -> String {
        language == .korean ? prayerRequestGate : prayerRequestGateEnglish
    }

    // MARK: - Lines and labels across languages

    /// "문장 (누구/주제)" → the sentence and the label inside the brackets, if there is one.
    static func splitLabel(_ line: String) -> (body: String, label: String?) {
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
    static func translatedLabel(_ label: String, to language: RequestLanguage) -> String {
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
    static func polishTranslation(
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
