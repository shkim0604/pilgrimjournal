import Foundation

/// The prompts that turn one diary into prayer requests, in Korean and English. Bump `version`
/// whenever any wording changes so scored runs can be compared.
public enum PrayerRequestPrompts {
    // Replaces `prayerCard` for diaries that hold worries rather than explicit prayers: the
    // .2 card copied whole entries and wrote the "가족, 친구, 동료" instruction into its text.
    // 2026-10-16.1 had the examples in the prompt next to the diary; on a diary with nothing
    // to pray for it answered with the examples' own requests. .2 moves them into the
    // instructions and leaves only the diary in the prompt.
    // 2026-11-11.1 comes out of an 11-prompt comparison on the 21 diaries (docs/roadmap.md):
    // a label written BEFORE the sentence made the model write one line per label, inventing
    // content to fill them, so the label goes AFTER the sentence as (누구/주제); long rule
    // lists were ignored, so there are six; and no extraction prompt ever answered "없음",
    // so that decision is the gate's, asked first.
    //
    // Names: the owner decided (2026-11-12) that a name in a request is fine, since groups are
    // private, as long as the person confirms before sharing. The "사람 이름은 어디에도 쓰지
    // 않는다" line stays only because the prompt without it scored no better (names came out
    // in 4 of 5 named diaries either way, and fewer labels were valid); it is not a
    // requirement, and the lab shows names as something to check, not as a failure.
    public static let version = "2026-11-11.1"

    public static func instructions(_ language: RequestLanguage) -> String {
        language == .korean ? koreanInstructions : englishInstructions
    }

    public static func template(_ language: RequestLanguage) -> String {
        language == .korean ? koreanTemplate : englishTemplate
    }

    public static func gateInstructions(_ language: RequestLanguage) -> String {
        language == .korean ? koreanGateInstructions : englishGateInstructions
    }

    public static func gateTemplate(_ language: RequestLanguage) -> String {
        language == .korean ? koreanGateTemplate : englishGateTemplate
    }

    /// Fills `{날짜}`, `{제목}` and `{본문}`, so the prompt lab can let people edit a template
    /// as plain text.
    public static func fill(_ template: String, title: String, date: String, body: String)
        -> String
    {
        template
            .replacingOccurrences(of: "{날짜}", with: date)
            .replacingOccurrences(of: "{제목}", with: title)
            .replacingOccurrences(of: "{본문}", with: body)
    }

    // MARK: - Korean diaries

    private static let koreanInstructions = """
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

    /// Yes/no question to ask before the instructions: 27/27 on the 21 diaries plus six more
    /// with nothing to pray for. The prompt lab asks it first when its "먼저 묻기" box is
    /// ticked and skips the extraction on "아니오".
    private static let koreanGateInstructions =
        "너는 개인 일기를 분류한다. 질문에 '예' 또는 '아니오' 한 단어로만 답한다."

    private static let koreanGateTemplate = """
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

    /// The prompt around the diary. `{날짜}`, `{제목}` and `{본문}` are filled per diary.
    private static let koreanTemplate = """
        일기 ({날짜}):
        {제목}
        {본문}

        이 일기의 기도제목을 규칙대로 써라.
        답:
        """

    // MARK: - English diaries

    // The English twin of `koreanInstructions`, without the no-names line (names are fine in
    // a private group; the person confirms before sharing).
    private static let englishInstructions = """
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

    private static let englishTemplate = """
        Diary ({날짜}):
        {제목}
        {본문}

        Write the prayer requests for this diary following the rules.
        Answer:
        """

    private static let englishGateInstructions =
        "You classify personal diary entries. Answer the question with one word only: Yes or No."

    private static let englishGateTemplate = """
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
}
