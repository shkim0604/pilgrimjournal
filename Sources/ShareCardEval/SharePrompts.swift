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
}
