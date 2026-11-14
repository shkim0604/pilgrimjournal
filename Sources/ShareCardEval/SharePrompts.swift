import Foundation

/// Every prompt the eval sends. Bump `version` whenever any of them changes so scored runs
/// can be compared (it is printed in the summary and saved in `--json` output).
enum SharePrompts {
    // 2026-10-15.1: 63/85 (deadlines 3/15; prayer classifier said yes to every entry).
    // 2026-10-15.2: question repeated after the entry, concrete prayer-sentence cue, more
    // "no" examples; optional date fields; deadlines must be after the entry date.
    static let version = "2026-10-15.2"

    // MARK: - 1. Few-shot yes/no classification

    struct Classifier {
        /// Definition and examples, shown before the entry.
        let guide: String
        /// Asked again right after the entry, so the small model answers this, not the entry.
        let question: String
    }

    static let classifierInstructions = """
        너는 개인 신앙 기록을 분류한다. 질문에 '예' 또는 '아니오' 한 단어로만 답한다.
        """

    // Examples are deliberately different from the fixtures so they do not leak answers.

    static let prayer = Classifier(
        guide: """
            기도 문장은 하나님께 무언가를 구하는 문장이다. 예: '~하기를 기도한다', '~하게 \
            해주세요', '~하도록'.
            - 기도 문장이 없으면 아니오. 하루 일과, 업무 기록, 할 일 목록, 혼잣말 바람(예: 주말엔 \
            푹 자고 싶다)은 기도 문장이 아니다.
            - 지난 일에 대한 감사만 있으면 아니오.

            기록: 내일 면접이 있다. 떨리지만 차분하게 말할 수 있기를 기도한다.
            답: 예
            기록: 오늘 야근했다. 저녁은 편의점 도시락. 주말엔 푹 자고 싶다.
            답: 아니오
            기록: 장보기: 사과, 휴지. 은행 들르기. 저녁에 운동.
            답: 아니오
            기록: 아이가 새 학교에 잘 적응하도록, 이사가 순탄하도록.
            답: 예
            기록: 작년에 기도했던 일이 이뤄졌다. 정말 감사하다.
            답: 아니오
            """,
        question: "이 기록에 하나님께 구하는 기도 문장이 있나?"
    )

    static let testimony = Classifier(
        guide: """
            간증은 하나님이 이미 하신 일(응답된 기도, 도우심, 회복, 변화)을 돌아보며 고백하는 \
            글이다.
            - 앞으로의 부탁만 있으면 아니오.
            - 평범한 하루 기록, 업무 기록, 할 일 목록은 아니오.
            - 간증 뒤에 새 기도제목이 붙어 있어도 간증이면 예.

            기록: 석 달 기도했던 아버지의 수술이 잘 끝났다. 끝까지 지켜주신 하나님께 감사드린다.
            답: 예
            기록: 다음 주 시험을 잘 보게 해주세요.
            답: 아니오
            기록: 친구와 카페에서 수다를 떨었다. 즐거운 하루였다.
            답: 아니오
            기록: 빚 때문에 잠 못 자던 때가 있었는데 하나님이 길을 열어주셔서 올해 다 갚았다. \
            앞으로도 정직하게 일하도록 기도한다.
            답: 예
            """,
        question: "이 기록이 간증인가?"
    )

    static let thirdParty = Classifier(
        guide: """
            다른 사람의 개인 사정은 글쓴이가 아닌 사람(가족, 친구, 동료)의 건강, 가정 문제, 돈, \
            마음의 어려움이다.
            - 글쓴이 자신의 일만 있으면 아니오.
            - 다른 사람이 등장만 하면(같이 밥을 먹음, 함께 일함) 아니오.

            기록: 친구가 이혼 소송 중이라 많이 힘들어한다. 그를 위해 기도한다.
            답: 예
            기록: 동생과 영화를 봤다. 재밌었다.
            답: 아니오
            기록: 내 허리 통증이 낫기를 기도한다. 병원비도 걱정이다.
            답: 아니오
            기록: 팀원들과 회의를 잘 마치고 싶다.
            답: 아니오
            기록: 팀장님 아버님이 암 진단을 받으셨다고 한다.
            답: 예
            """,
        question: "이 기록에 다른 사람의 개인 사정이 들어 있나?"
    )

    static func classification(_ classifier: Classifier, _ entry: EvalEntry) -> String {
        """
        \(classifier.guide)

        기록:
        \(entry.promptText)

        질문: \(classifier.question) '예' 또는 '아니오'로만 답하라.
        답:
        """
    }

    // MARK: - 2. Structured output for short fields

    static let extractionInstructions = """
        너는 신앙 기록에서 정보를 뽑는다. 본문에 있는 내용만 뽑고, 없는 내용은 만들지 않는다.
        """

    static func prayerItems(_ entry: EvalEntry, hints: String) -> String {
        """
        달력:
        \(hints)

        \(entry.promptText)

        위 기록에 있는 기도제목을 빠짐없이 모두 뽑아라. 서로 다른 일은 따로 적는다. 기도제목에 \
        앞으로 다가올 마감 날짜가 있으면 본문의 날짜 표현을 그대로 적고, 위 달력으로 계산한 날짜를 \
        YYYY-MM-DD로 적어라. 작성일과 '오늘'은 마감 날짜가 아니다. 마감 날짜가 없으면 비워 둔다.
        """
    }

    static func bookFields(_ entry: EvalEntry) -> String {
        """
        \(entry.promptText)

        위 독서노트에서 책 제목, 저자, 인용문(본문에 따옴표로 적힌 문장 그대로)을 뽑아라.
        """
    }

    // MARK: - 3. Free-text prose

    static let cardInstructions = """
        너는 신앙 그룹에 나눌 짧은 카드를 쓴다. 기록에 있는 사실만 쓰고, 다른 사람의 이름은 쓰지 말고 \
        '가족', '친구', '동료'처럼 바꾼다.
        """

    static func prayerCard(_ entry: EvalEntry) -> String {
        "\(entry.promptText)\n\n위 기록의 기도제목만 골라 그룹에 부탁하는 기도 카드를 2~3문장으로 써라."
    }

    static func testimonyCard(_ entry: EvalEntry) -> String {
        "\(entry.promptText)\n\n위 기록을 1인칭 간증 카드로 3~5문장으로 다듬어라."
    }

    static func bookCard(_ entry: EvalEntry) -> String {
        """
        \(entry.promptText)

        위 독서노트로 독후감 카드를 써라. 형식:
        깨달음: (2~3문장)
        토론 질문: (1문장)
        """
    }

    // MARK: - 4. Diary → prayer requests (`--prayer-requests`)

    // Replaces `prayerCard` for diaries that hold worries rather than explicit prayers: the
    // .2 card copied whole entries and wrote the "가족, 친구, 동료" instruction into its text.
    // 2026-10-16.1 had the examples in the prompt next to the diary; on a diary with nothing
    // to pray for it answered with the examples' own requests. .2 moves them into the
    // instructions and leaves only the diary in the prompt.
    // 2026-11-11.1 comes out of an 11-prompt comparison on the 21 diaries (docs/roadmap.md):
    // a label written BEFORE the sentence made the model write one line per label, inventing
    // content to fill them, so the label goes AFTER the sentence as (누구/주제); long rule
    // lists were ignored, so there are six; and no extraction prompt ever answered "없음",
    // so that decision is `prayerRequestGate`'s, asked first.
    //
    // Names: the owner decided (2026-11-12) that a name in a request is fine, since groups are
    // private, as long as the person confirms before sharing. The "사람 이름은 어디에도 쓰지
    // 않는다" line stays only because the prompt without it scored no better (names came out
    // in 4 of 5 named diaries either way, and fewer labels were valid); it is not a
    // requirement, and the lab shows names as something to check, not as a failure.
    static let prayerRequestVersion = "2026-11-11.1"

    static let prayerRequestTopics = ["건강", "가정", "직장", "학업", "재정", "관계", "신앙", "진로"]

    static let prayerRequestInstructions = """
        일기를 읽고 소그룹에 부탁할 기도제목을 쓴다.
        - 글쓴이가 걱정하는 일, 바라는 일, 앞둔 일만 쓴다. 서로 다른 일은 따로 쓴다. 1~3줄.
        - 형식: '- ~하도록 기도해 주세요 (누구/주제)'
        - 누구: 기도 받을 사람. 글쓴이 자신이면 '나', 아니면 '어머니', '친구', '아들'처럼 관계로 쓴다.
        - 주제는 하나만: 건강, 가정, 직장, 학업, 재정, 관계, 신앙, 진로
        - 같은 내용을 다시 쓰지 않는다. 쓸 일이 하나면 한 줄만 쓴다.
        - 사람 이름은 어디에도 쓰지 않는다.

        예시
        일기: 다음 주 수요일에 이사를 간다. 짐은 반도 못 쌌다. 유진이네가 도와준다고 했는데 유진이 허리가 안 좋아 걱정이다.
        답:
        - 다음 주 수요일 이사가 사고 없이 마무리되도록 기도해 주세요 (나/가정)
        - 이사를 도와줄 친구의 허리가 낫도록 기도해 주세요 (친구/건강)
        """

    /// Yes/no question to ask before `prayerRequestInstructions`: 27/27 on the 21 diaries
    /// plus six more with nothing to pray for. The prompt lab asks it first when its
    /// "먼저 묻기" box is ticked and skips the extraction on "아니오".
    static let prayerRequestGateInstructions = "너는 개인 일기를 분류한다. 질문에 '예' 또는 '아니오' 한 단어로만 답한다."

    static let prayerRequestGate = """
        기도제목이 될 만한 일은 글쓴이나 가까운 사람의 걱정, 아픔, 갈등, 중요한 결정, 시험·수술·이사처럼 앞둔 큰일, 간절한 바람이다.
        쉬고, 놀고, 먹고, 청소하고, 여행하고, 친구를 만난 평범하고 즐거운 하루는 '아니오'다. '다음에 또 가고 싶다' 같은 가벼운 바람도 '아니오'다.

        예: "엄마 수술이 다음 주라 잠이 안 온다." → 예
        예: "동네 도서관에서 잡지를 읽고 붕어빵을 사 먹었다." → 아니오
        예: "회사에서 또 혼났다. 그만둬야 하나 고민이다." → 예
        예: "친구들과 바다에 다녀왔다. 회가 맛있었다. 또 가고 싶다." → 아니오

        일기:
        {제목}
        {본문}

        질문: 이 일기에 기도를 부탁할 만한 걱정이나 간절한 바람이 있나? '예' 또는 '아니오'로만 답하라.
        답:
        """

    /// The prompt around the diary. `{날짜}`, `{제목}` and `{본문}` are filled per diary, so the
    /// prompt lab (`--serve`) can let people edit it as plain text.
    static let prayerRequestTemplate = """
        일기 ({날짜}):
        {제목}
        {본문}

        이 일기의 기도제목을 규칙대로 써라.
        답:
        """

    static func prayerRequests(_ entry: EvalEntry) -> String {
        fill(prayerRequestTemplate, with: entry)
    }

    static func fill(_ template: String, with entry: EvalEntry) -> String {
        template
            .replacingOccurrences(of: "{날짜}", with: entry.date.description)
            .replacingOccurrences(of: "{제목}", with: entry.title)
            .replacingOccurrences(of: "{본문}", with: entry.body)
    }

    /// The request lines of a `prayerRequests` answer; empty for "없음".
    static func requestLines(_ answer: String) -> [String] {
        answer.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let first = text.first, "-•*·".contains(first) else { return nil }
            let request = text.dropFirst().trimmingCharacters(in: .whitespaces)
            return request.isEmpty ? nil : request
        }
    }

    /// True only for a clear "아니오": anything else (a guardrail skip, a stray word) lets the
    /// extraction run, so a broken gate never hides a diary that has something to pray for.
    static func gateSaysNo(_ answer: String?) -> Bool {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return false }
        return answer.hasPrefix("아니") || answer == "no" || answer.hasPrefix("no.")
    }

    /// What code does after the model: drop a line that repeats an earlier one (the model
    /// loops on some diaries, sometimes changing only the trailing `(누구/주제)` label), keep
    /// at most `limit`, and cut the "기도해 주세요" tail. The model does none of these
    /// reliably when told to.
    static func tidyRequestLines(_ lines: [String], limit: Int = 3) -> [String] {
        withoutRepeats(lines, limit: limit).map(sharedEnding)
    }

    /// The repeat-and-limit half of `tidyRequestLines`, for lines that are about to be
    /// translated or are English ("Pray that …" is how an English request reads; nothing to cut).
    static func withoutRepeats(_ lines: [String], limit: Int = 3) -> [String] {
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
    static func sharedEnding(_ line: String) -> String {
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
}
