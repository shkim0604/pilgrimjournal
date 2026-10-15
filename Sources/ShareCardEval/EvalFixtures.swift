// Every entry below is invented for this eval. Never paste real journal text or Day One
// export content here (see CLAUDE.md "Privacy constraints"); names and books are fictional.

enum EntryKind: String, Codable, Sendable {
    case diary = "일기"
    case prayer = "기도노트"
    case reading = "독서노트"
}

struct ExpectedDeadline: Sendable {
    /// The phrase as it appears in the body; `DatePhraseResolverTests` checks it resolves to
    /// `date`, so the labels themselves are verified.
    let phrase: String
    let date: DayDate
}

struct ExpectedBook: Sendable {
    let title: String
    let author: String
    let quote: String
}

struct Expected: Sendable {
    var hasPrayer = false
    var isTestimony = false
    var mentionsThirdParty = false
    var deadlines: [ExpectedDeadline] = []
    var minPrayerItems: Int?
    /// Names that must not appear in a share card (reported, not scored — the roadmap plans a
    /// UI warning instead because the model does not remove them reliably).
    var thirdPartyNames: [String] = []
    var book: ExpectedBook?
}

struct EvalEntry: Sendable {
    let id: String
    let kind: EntryKind
    let date: DayDate
    let title: String
    let body: String
    let expected: Expected

    /// The entry as the prompts see it.
    var promptText: String {
        "종류: \(kind.rawValue)\n작성일: \(date)\n제목: \(title)\n본문:\n\(body)"
    }
}

enum EvalFixtures {
    // 2026-10-15 is a Thursday.
    static let defaultDate = DayDate(2026, 10, 15)

    static let all: [EvalEntry] = [
        EvalEntry(
            id: "deadline-explicit",
            kind: .diary,
            date: defaultDate,
            title: "최종 면접",
            body: """
                오늘 이직 서류 결과 메일을 받았다. 서류는 통과했고 11월 3일 오후 2시에 최종 면접이 \
                잡혔다. 준비할 게 많아서 퇴근하고 카페에서 예상 질문을 정리했다. 긴장되지만 준비한 \
                만큼 차분하게 말할 수 있기를 기도한다. 결과가 어떻든 받아들일 마음도 주시길.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [.init(phrase: "11월 3일", date: DayDate(2026, 11, 3))]
            )
        ),
        EvalEntry(
            id: "next-week-weekday",
            kind: .diary,
            date: defaultDate,
            title: "도로주행",
            body: """
                운전면허 도로주행 시험이 다음 주 화요일로 잡혔다. 지난번에 차선 변경에서 감점을 받아 \
                떨어졌기 때문에 이번엔 정말 붙고 싶다. 퇴근 후 학원에서 한 시간 더 연습했다. 시험 날 \
                손이 떨리지 않고 평소처럼 운전할 수 있게 해달라고 기도했다.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [.init(phrase: "다음 주 화요일", date: DayDate(2026, 10, 20))]
            )
        ),
        EvalEntry(
            id: "next-month-day",
            kind: .diary,
            date: defaultDate,
            title: "이사 날짜",
            body: """
                집주인에게서 연락이 와서 다음 달 12일에 이사하기로 확정됐다. 새 집은 회사에서 조금 \
                멀지만 햇빛이 잘 든다. 짐 정리는 아직 시작도 못 했다. 이사 날까지 필요한 돈이 잘 \
                마련되고, 날씨가 좋아서 사고 없이 옮길 수 있기를 기도한다.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [.init(phrase: "다음 달 12일", date: DayDate(2026, 11, 12))]
            )
        ),
        EvalEntry(
            id: "this-month-end",
            kind: .diary,
            date: defaultDate,
            title: "논문 초안",
            body: """
                지도교수님이 이번 달 말까지 논문 초안을 내라고 하셨다. 실험 데이터는 다 모았는데 결론 \
                부분이 아직 엉성하다. 오늘은 도서관에서 저녁까지 그래프만 다시 그렸다. 마감까지 \
                지치지 않고 집중할 수 있도록, 막힌 부분에서 지혜를 주시도록 기도한다.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [.init(phrase: "이번 달 말", date: DayDate(2026, 10, 31))]
            )
        ),
        EvalEntry(
            id: "prayer-note-list",
            kind: .prayer,
            date: defaultDate,
            title: "10월 셋째 주 기도제목",
            body: """
                1. 다음 주 금요일 팀 발표를 잘 마치도록
                2. 12월 1일 자격증 결과 발표 — 합격하게 해주세요
                3. 아침 큐티 시간을 꾸준히 지키도록
                4. 무릎 통증이 낫도록
                5. 청년부 수련회 준비가 잘 되도록
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [
                    .init(phrase: "다음 주 금요일", date: DayDate(2026, 10, 23)),
                    .init(phrase: "12월 1일", date: DayDate(2026, 12, 1)),
                ],
                minPrayerItems: 5
            )
        ),
        EvalEntry(
            id: "year-rollover",
            kind: .diary,
            date: DayDate(2026, 12, 20),
            title: "복학",
            body: """
                한 해가 거의 끝나간다. 휴학한 지 일 년이 지났고, 다음 달 8일까지 복학 신청을 해야 \
                한다. 다시 학교로 돌아가는 게 두렵기도 하다. 오랜만에 수업을 따라갈 수 있을지, \
                학비는 어떻게 할지 걱정이 많다. 복학 신청까지 마음을 정하고, 필요한 것들을 \
                채워주시길 기도한다.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [.init(phrase: "다음 달 8일", date: DayDate(2027, 1, 8))]
            )
        ),
        EvalEntry(
            id: "this-week-from-monday",
            kind: .prayer,
            date: DayDate(2026, 10, 19),
            title: "이번 주 기도",
            body: """
                이번 주 금요일에 승진 심사 면담이 있다. 그리고 다음 주 월요일부터 새 프로젝트에 \
                투입된다. 면담에서 지난 일 년을 솔직하고 담담하게 이야기할 수 있게 해주세요. 새 \
                프로젝트에도 잘 적응하도록 지혜를 주세요.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [
                    .init(phrase: "이번 주 금요일", date: DayDate(2026, 10, 23)),
                    .init(phrase: "다음 주 월요일", date: DayDate(2026, 10, 26)),
                ]
            )
        ),
        EvalEntry(
            id: "month-boundary-tomorrow",
            kind: .diary,
            date: DayDate(2026, 10, 31),
            title: "오디션 전날",
            body: """
                내일은 합창단 오디션이 있고, 모레는 회사 승진 발표가 난다. 둘 다 긴장된다. 오늘 \
                저녁엔 목을 아끼려고 따뜻한 차를 마시고 일찍 누웠다. 오디션에서 연습한 대로 부를 수 \
                있도록, 발표 결과가 어떻든 감사할 수 있도록 기도한다.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [
                    .init(phrase: "내일", date: DayDate(2026, 11, 1)),
                    .init(phrase: "모레", date: DayDate(2026, 11, 2)),
                ]
            )
        ),
        EvalEntry(
            id: "no-prayer-overtime",
            kind: .diary,
            date: defaultDate,
            title: "야근",
            body: """
                오늘도 야근. 분기 마감이라 엑셀 시트를 세 개나 맞춰야 했다. 저녁은 편의점 김밥이랑 \
                컵라면. 9시 반쯤 겨우 끝나서 지하철을 탔는데 사람이 꽉 차 있었다. 집에 와서 씻고 \
                유튜브 보다가 잤다. 내일은 좀 일찍 끝났으면 좋겠다.
                """,
            expected: Expected()
        ),
        EvalEntry(
            id: "no-prayer-todo",
            kind: .diary,
            date: defaultDate,
            title: "주말 할 일",
            body: """
                주말에 할 일 정리.
                - 세탁소에서 코트 찾기
                - 마트: 우유, 계란, 두부, 대파
                - 자동차 엔진오일 교체 예약 (토요일 10시)
                - 책상 정리, 안 쓰는 케이블 버리기
                - 어머니께 안부 전화
                이번 주는 비교적 여유가 있었다. 저녁에 산책을 30분 했다.
                """,
            expected: Expected()
        ),
        EvalEntry(
            id: "no-prayer-pleasant-day",
            kind: .diary,
            date: defaultDate,
            title: "한강",
            body: """
                퇴근길에 친구 수아랑 한강에서 만나 치킨을 먹었다. 바람이 시원해서 가을이 온 게 \
                느껴졌다. 수아는 요즘 그림 수업을 듣는다고 신나서 이야기했다. 나도 뭔가 새로 \
                배워볼까 싶었다. 돌아오는 길에 노을이 예뻐서 사진을 많이 찍었다.
                """,
            expected: Expected()
        ),
        EvalEntry(
            id: "testimony-job",
            kind: .diary,
            date: defaultDate,
            title: "정규직 제안",
            body: """
                반년 동안 구직하면서 지원서를 마흔 군데 넘게 냈다. 떨어질 때마다 내가 쓸모없는 \
                사람 같았다. 그러다 지난달 작은 출판사에 계약직으로 들어갔고, 오늘 팀장님이 정규직 \
                전환을 제안하셨다. 집에 오는 버스에서 눈물이 났다. 포기하고 싶던 순간마다 붙잡아 \
                주신 하나님을 생각했다. 기다림의 시간이 헛되지 않았다는 걸 알게 하셨다. 감사합니다.
                """,
            expected: Expected(isTestimony: true)
        ),
        EvalEntry(
            id: "testimony-plus-prayer",
            kind: .diary,
            date: defaultDate,
            title: "검진 결과",
            body: """
                작년 이맘때 갑상선에 혹이 있다는 말을 듣고 얼마나 무서웠는지 모른다. 그때 교회 \
                식구들과 함께 기도했고, 수술 후 경과가 좋아서 오늘 의사 선생님이 약을 줄여도 된다고 \
                하셨다. 한 해 동안 지켜주신 은혜가 정말 크다. 다음 주 목요일에 정기검진이 하나 더 \
                남았는데, 그날도 좋은 결과가 나오기를 기도한다.
                """,
            expected: Expected(
                hasPrayer: true,
                isTestimony: true,
                deadlines: [.init(phrase: "다음 주 목요일", date: DayDate(2026, 10, 22))]
            )
        ),
        EvalEntry(
            id: "future-prayer-not-testimony",
            kind: .prayer,
            date: defaultDate,
            title: "시험 기도",
            body: """
                이번 주 토요일에 공인중개사 1차 시험이 있다. 일하면서 공부하느라 진도를 다 못 뺐다. \
                하나님, 공부한 만큼 기억나게 해주시고, 시험장에서 떨지 않게 해주세요. 혹시 \
                떨어지더라도 낙심하지 않고 다시 준비할 힘을 주세요.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [.init(phrase: "이번 주 토요일", date: DayDate(2026, 10, 17))]
            )
        ),
        EvalEntry(
            id: "mixed-ko-en-deadlines",
            kind: .diary,
            date: defaultDate,
            title: "Sprint review",
            body: """
                Today was 정신없는 day. Sprint review에서 PM이 demo를 next Friday로 당겼다. 그리고 \
                client 쪽 contract renewal deadline is Oct 30. 둘 다 내 담당이라 솔직히 overwhelmed. \
                Please Lord, give me focus and wisdom — demo 잘 끝내고 renewal도 잘 마무리되게 \
                해주세요. 팀원들이랑도 부딪히지 않고 잘 협업하고 싶다.
                """,
            expected: Expected(
                hasPrayer: true,
                deadlines: [
                    .init(phrase: "next Friday", date: DayDate(2026, 10, 23)),
                    .init(phrase: "Oct 30", date: DayDate(2026, 10, 30)),
                ]
            )
        ),
        EvalEntry(
            id: "mixed-ko-en-no-prayer",
            kind: .diary,
            date: defaultDate,
            title: "Work log",
            body: """
                Work log. 오전에는 API migration 마무리, 오후에는 code review 세 건. Lunch는 팀이랑 \
                쌀국수. 새로 온 intern이 질문을 많이 해서 설명하느라 시간이 좀 갔지만 나쁘지 않았다. \
                Tomorrow: release note 쓰기, staging 배포 확인. 저녁엔 헬스장 갔다가 일찍 잤다.
                """,
            expected: Expected()
        ),
        EvalEntry(
            id: "third-party-family",
            kind: .diary,
            date: defaultDate,
            title: "엄마 수술",
            body: """
                엄마가 11월 9일에 무릎 인공관절 수술을 받으신다. 의사 말로는 흔한 수술이라지만 엄마 \
                연세가 있어서 마취가 걱정된다. 아빠는 요즘 허리가 안 좋아서 간병을 내가 맡아야 할 것 \
                같다. 회사에 휴가를 어떻게 낼지도 고민이다. 수술이 잘 되고 회복이 빠르기를, 간병하는 \
                동안 내가 지치지 않기를 기도한다.
                """,
            expected: Expected(
                hasPrayer: true,
                mentionsThirdParty: true,
                deadlines: [.init(phrase: "11월 9일", date: DayDate(2026, 11, 9))]
            )
        ),
        EvalEntry(
            id: "third-party-friend-named",
            kind: .diary,
            date: defaultDate,
            title: "민지 전화",
            body: """
                민지에게 오랜만에 전화가 왔다. 남편과 별거 중이라고, 아이 둘을 혼자 돌보느라 대출 \
                이자도 밀렸다고 했다. 통화 내내 울었다. 내가 해줄 수 있는 게 별로 없어서 마음이 \
                무거웠다. 민지가 이 시기를 잘 견디고, 필요한 도움을 만나고, 아이들이 상처받지 않기를 \
                기도한다.
                """,
            expected: Expected(
                hasPrayer: true,
                mentionsThirdParty: true,
                thirdPartyNames: ["민지"]
            )
        ),
        EvalEntry(
            id: "third-party-coworker-initial",
            kind: .prayer,
            date: defaultDate,
            title: "동료를 위한 기도",
            body: """
                회사 동료 J가 공황장애로 휴직했다. 팀에서는 아무도 모르고 나한테만 털어놓았다. 이번 \
                달 말에 복직 여부를 결정해야 한다고 한다. J가 충분히 쉬고 좋은 결정을 내리도록. \
                그리고 내가 비밀을 잘 지키고 좋은 친구가 되어주도록.
                """,
            expected: Expected(
                hasPrayer: true,
                mentionsThirdParty: true,
                deadlines: [.init(phrase: "이번 달 말", date: DayDate(2026, 10, 31))],
                thirdPartyNames: ["J"]
            )
        ),
        EvalEntry(
            id: "long-prayer-at-end",
            kind: .diary,
            date: defaultDate,
            title: "긴 하루",
            body: longPrayerAtEnd,
            expected: Expected(
                hasPrayer: true,
                deadlines: [.init(phrase: "다음 주 수요일", date: DayDate(2026, 10, 21))]
            )
        ),
        EvalEntry(
            id: "long-no-prayer",
            kind: .diary,
            date: DayDate(2026, 10, 11),
            title: "경주 여행",
            body: longNoPrayer,
            expected: Expected()
        ),
        EvalEntry(
            id: "reading-korean-book",
            kind: .reading,
            date: defaultDate,
            title: "광야의 식탁 3장",
            body: """
                『광야의 식탁』 — 한서윤

                3장까지 읽었다. 저자는 광야를 '빼앗긴 곳'이 아니라 '차려진 곳'으로 다시 보라고 \
                한다. 가장 오래 붙잡은 문장: “광야에서 받은 만나는 저장되지 않았기에 매일 감사가 \
                되었다.” 나는 늘 미래를 위해 쌓아두려고만 했다는 생각이 들었다. 오늘 하루치 은혜로 \
                충분하다는 걸 믿지 못해서 불안했던 것 같다. 다음 장은 엘리야 이야기라고 한다.
                """,
            expected: Expected(
                book: ExpectedBook(
                    title: "광야의 식탁",
                    author: "한서윤",
                    quote: "광야에서 받은 만나는 저장되지 않았기에 매일 감사가 되었다"
                )
            )
        ),
        EvalEntry(
            id: "reading-english-book",
            kind: .reading,
            date: defaultDate,
            title: "The Quiet Harvest",
            body: """
                The Quiet Harvest (Miriam Hale) 다 읽음.

                농부였던 저자가 안식년 동안 밭을 묵히며 쓴 에세이. 일을 멈추면 모든 게 무너질 것 \
                같았는데 땅은 오히려 회복됐다는 이야기가 반복된다. 밑줄 친 문장: "Rest is not the \
                absence of work but the presence of trust." 나는 쉬는 날에도 메일을 확인한다. 쉼을 \
                게으름으로 여겨 온 게 결국 신뢰가 부족해서였을까. 소그룹에서 같이 이야기해 보고 싶다.
                """,
            expected: Expected(
                book: ExpectedBook(
                    title: "The Quiet Harvest",
                    author: "Miriam Hale",
                    quote: "Rest is not the absence of work but the presence of trust"
                )
            )
        ),
    ]

    private static let longPrayerAtEnd = """
        아침 6시 반에 알람이 울렸는데 세 번이나 미루고 7시가 넘어서야 일어났다. 요즘 아침마다 몸이 \
        무겁다. 세수를 하고 거울을 보니 눈 밑이 거뭇했다. 커피를 내려 마시면서 오늘 할 일을 수첩에 \
        적었다. 오전 회의 두 개, 오후에는 협력사 미팅, 저녁에는 사진 동호회 모임. 적어 놓고 보니 \
        숨이 막혔다.

        출근길 지하철은 평소보다 붐볐다. 앞 역에서 신호 장애가 있었다고 한다. 서서 가는 동안 \
        이어폰으로 팟캐스트를 들었는데, 오래된 도시의 골목길을 다시 살리는 사람들 이야기였다. 낡은 \
        건물을 허물지 않고 고쳐 쓰는 일이 생각보다 훨씬 손이 많이 간다고 했다. 듣다 보니 내 일도 \
        비슷하다는 생각이 들었다. 새로 만드는 것보다 이미 있는 것을 고치는 게 더 어렵다. 회사에 \
        도착해서는 엘리베이터 앞 줄이 길어서 계단으로 올라갔다. 7층까지 올라가니 숨이 찼다.

        첫 회의는 다음 분기 예산 이야기였다. 숫자가 맞지 않는 부분이 있어서 재무팀과 한참 이야기를 \
        나눴다. 결국 내가 자료를 다시 정리해서 보내기로 했다. 두 번째 회의는 신입 교육 일정이었는데, \
        생각보다 금방 끝났다. 회의실에서 나오는데 창밖으로 은행나무가 노랗게 물들어 있었다. 언제 \
        이렇게 계절이 바뀌었나 싶었다. 자리로 돌아와서 예산 자료를 펼쳤는데, 작년 자료와 형식이 달라 \
        하나하나 맞춰 보느라 점심 직전까지 붙잡고 있었다.

        점심은 회사 근처 국숫집에서 먹었다. 늘 먹던 잔치국수 대신 비빔국수를 시켰는데 생각보다 \
        매웠다. 같이 간 동료들은 주말에 다녀온 캠핑 이야기를 했다. 텐트를 치다가 비가 와서 고생했다는 \
        이야기에 다 같이 웃었다. 나는 요즘 주말에 거의 집에만 있어서 딱히 할 이야기가 없었다. 그래도 \
        듣는 것만으로 기분이 좋아졌다. 돌아오는 길에 카페에서 따뜻한 보리차를 한 잔 샀다.

        오후 미팅 전에 잠깐 회사 뒤 공원을 한 바퀴 걸었다. 벤치마다 점심을 먹고 나온 직장인들이 앉아 \
        햇볕을 쬐고 있었다. 비둘기 몇 마리가 과자 부스러기를 쫓아다녔다. 공원 가장자리 화단에는 \
        국화가 피기 시작했다. 노란색, 보라색, 흰색 국화가 섞여 있어서 한참을 들여다봤다. 걸으면서 \
        미팅에서 할 말을 머릿속으로 정리했다. 일정이 또 밀리면 어떻게 대응할지 두세 가지 방법을 생각해 \
        두었다.

        오후 협력사 미팅은 예상보다 길어졌다. 납품 일정이 또 밀릴 수 있다는 이야기를 들었다. 담당자도 \
        난처해 보였다. 서로 탓하지 않고 방법을 찾자고 이야기했고, 수정된 일정을 다시 받기로 했다. \
        미팅을 마치고 나니 4시 반이었다. 남은 메일을 처리하고 내일 보고 자료를 조금 손봤다. 퇴근 \
        직전에 팀장님이 오늘 고생했다며 귤을 하나 건네주셨다. 별것 아닌데 그게 이상하게 고마웠다.

        퇴근길에 잠깐 서점에 들렀다. 요리책 코너에서 한참을 서성였다. 혼자 사는 사람을 위한 간단한 \
        반찬 책이 눈에 들어왔는데, 사진이 너무 예뻐서 오히려 따라 할 자신이 없어졌다. 결국 아무것도 \
        사지 않고 나왔다. 대신 편의점에서 귤 한 봉지를 샀다. 올해 두 번째 귤이었다.

        동호회 모임 장소까지는 버스로 다섯 정거장이었다. 버스 안에서 오랜만에 종이책을 꺼냈다. 몇 달 \
        전에 사 놓고 앞부분만 읽다 만 소설이다. 바닷가 마을의 작은 우체국을 지키는 사람이 주인공인데, \
        매일 같은 시간에 같은 편지를 기다리는 노인이 등장한다. 몇 페이지 읽지 못했는데 벌써 내릴 \
        정류장이었다. 창밖으로 퇴근하는 사람들이 횡단보도 앞에 길게 서 있었다. 다들 저마다의 하루를 \
        마치고 어딘가로 돌아가는 중이었다. 그 모습을 보고 있으니 이상하게 마음이 차분해졌다. 정류장 앞 \
        붕어빵 가게에서 팥 붕어빵 두 개를 사서 하나는 바로 먹고 하나는 주머니에 넣었다.

        저녁 사진 동호회 모임은 한 달에 한 번 있다. 이번 달 주제는 '창문'이었는데, 나는 사무실 창문에 \
        비친 퇴근길 불빛을 찍어 갔다. 다른 사람들 사진을 보니 다들 시선이 달라서 재밌었다. 어떤 분은 \
        할머니 댁 부엌 창문을 찍어 왔는데, 오래된 꽃무늬 커튼이 인상적이었다. 또 한 분은 버스 창문에 \
        맺힌 빗방울을 아주 가까이에서 찍었는데, 물방울마다 거꾸로 된 거리가 담겨 있었다. 다음 달 \
        주제는 '손'으로 정해졌다. 모임이 끝나고 몇 명은 2차를 갔지만 나는 피곤해서 먼저 나왔다.

        집에 오니 10시가 넘었다. 씻고 나서 귤을 까먹으며 오늘 하루를 돌아봤다. 바쁘기만 하고 남는 게 \
        없는 하루 같았는데, 이렇게 적어 놓고 보니 은행나무도 보고, 동료들 웃음소리도 듣고, 좋은 \
        사진도 봤다. 생각보다 괜찮은 하루였다. 내일은 알람을 한 번에 끄고 일어나 보기로 한다.

        사실 요즘 마음 한쪽이 계속 불안했던 이유가 있다. 지난주에 받은 건강검진에서 간 수치가 높게 \
        나와서 재검사를 받았고, 그 결과가 다음 주 수요일에 나온다. 별일 아닐 거라고 스스로 달래 \
        보지만 밤마다 자꾸 검색을 하게 된다. 결과를 기다리는 동안 너무 앞서 걱정하지 않고 하루하루를 \
        잘 살 수 있기를, 그리고 결과가 괜찮기를 기도한다.
        """

    private static let longNoPrayer = """
        새벽 기차를 타고 경주에 다녀왔다. 서울역에서 6시 40분 KTX를 탔는데, 출발하자마자 잠이 들어서 \
        눈을 뜨니 벌써 신경주역이었다. 역 앞에서 버스를 타고 시내로 들어가는 동안 창밖으로 넓은 \
        논이 지나갔다. 벼를 다 베어낸 논에 볏짚 뭉치가 하얗게 줄지어 있었다. 역 대합실 안내 데스크에서 \
        시내 지도를 한 장 받았는데, 직원분이 처음 오셨으면 대릉원부터 보라고 친절하게 알려주셨다. \
        버스에는 관광객보다 장을 보러 가는 어르신들이 더 많았다. 커다란 보따리를 든 할머니 한 분이 \
        내 옆자리에 앉으셨는데, 버스가 흔들릴 때마다 보따리를 꼭 끌어안으셨다.

        첫 목적지는 대릉원이었다. 이른 시간이라 사람이 많지 않았다. 커다란 능 사이로 난 길을 \
        천천히 걸었다. 능 위에 내려앉은 아침 햇빛이 부드러웠다. 사진으로만 보던 목련나무 앞에는 \
        벌써 몇 명이 줄을 서 있었는데, 꽃이 없는 계절이라 그런지 금방 차례가 왔다. 천마총 안에도 \
        들어가 봤다. 금관 복제품이 생각보다 작아서 놀랐다. 설명문을 하나하나 읽다 보니 한 시간이 \
        훌쩍 지났다.

        점심은 황리단길에서 먹었다. 한옥을 고친 식당이 줄지어 있었는데, 줄이 짧은 곳을 골라 \
        들어갔다. 경주 한우 국밥을 시켰다. 국물이 맑고 깊었다. 옆자리에는 수학여행 온 학생들이 앉아 \
        있었는데, 선생님 몰래 디저트를 하나 더 시키려고 작전을 짜는 모습이 귀여웠다. 식당을 나와서 \
        십원빵을 하나 사 먹었다. 치즈가 길게 늘어나서 한참을 웃었다.

        오후에는 자전거를 빌려 첨성대와 계림, 월정교까지 돌았다. 바람이 조금 차가웠지만 햇볕이 \
        좋아서 땀이 났다. 첨성대 옆 꽃밭에는 핑크뮬리가 한창이었다. 사람들이 저마다 사진을 찍느라 \
        분주했다. 나도 한 장 찍어 달라고 부탁했는데, 찍어 주신 분이 각도를 몇 번이나 바꿔 가며 정성껏 \
        찍어 주셨다. 계림 숲은 생각보다 고요했다. 오래된 느티나무 아래 벤치에 앉아 물을 마시며 \
        한참을 쉬었다. 나뭇잎 사이로 햇빛이 쏟아졌다.

        월정교는 해 질 무렵에 다시 가 보기로 하고, 그 전에 국립경주박물관에 들렀다. 성덕대왕신종 \
        앞에서 녹음된 종소리를 들었는데, 소리가 길게 남아 한동안 귀에 맴돌았다. 박물관 정원에 \
        흩어져 있는 석탑과 불상들을 보다가 다리가 아파서 카페에서 쉬었다. 창가 자리에 앉아 엽서를 \
        세 장 썼다. 받는 사람 주소를 외우지 못해서 결국 집에 가서 부치기로 했다.

        박물관을 나와서 월정교까지는 걸어서 갔다. 길가에 오래된 기와집들이 이어져 있었고, 담장 너머로 \
        감나무 가지가 늘어져 있었다. 주황색 감이 주렁주렁 달려 있어서 사진을 몇 장 찍었다. 골목 안쪽의 \
        작은 공방에 들어가 봤는데, 주인이 직접 빚은 찻잔과 접시가 진열되어 있었다. 유약 색이 은은한 \
        연두색 찻잔 하나를 샀다. 포장해 주시면서 이 흙은 근처 산에서 가져온 것이라고 설명해 주셨다. \
        공방 옆 찻집에서는 대추차를 마셨다. 진하고 달큰한 맛이 몸을 데워 주었다. 찻집 창문으로 보이는 \
        하늘이 조금씩 붉어지기 시작했다.

        해 질 무렵의 월정교는 정말 아름다웠다. 다리 지붕에 불이 들어오고, 그 빛이 강물에 길게 \
        비쳤다. 다리 위를 천천히 걸으며 오늘 하루를 돌아봤다. 혼자 하는 여행은 처음이라 걱정했는데, \
        생각보다 외롭지 않았다. 오히려 내 속도대로 걷고 쉬고 먹을 수 있어서 좋았다. 날씨가 하루 \
        종일 맑아서 감사했다.

        저녁은 동궁과 월지 근처에서 먹었다. 쌈밥 정식이 나왔는데 반찬이 열 가지가 넘었다. 혼자 \
        먹기에는 너무 많아서 절반쯤 남겼다. 식사 후 동궁과 월지 야경을 봤다. 연못에 비친 전각의 \
        불빛이 물결에 흔들렸다. 사람이 많았지만 다들 조용히 걷고 있어서 분위기가 좋았다. 한쪽 \
        구석에서는 누군가 작은 소리로 기타를 치며 노래를 불렀다.

        숙소를 잡지 않고 당일로 다녀오는 일정이라 기차 시간까지 조금 여유가 있었다. 역으로 가는 버스를 \
        기다리며 정류장 옆 편의점에서 따뜻한 두유를 하나 샀다. 정류장에는 나처럼 혼자 여행 온 사람이 두 \
        명 더 있었다. 한 사람은 커다란 카메라를 목에 걸고 있었고, 다른 한 사람은 지도를 펼쳐 놓고 \
        무언가를 열심히 적고 있었다. 버스 창밖으로 보이는 시내의 불빛이 하나둘 멀어졌다. 신경주역은 \
        밤에도 깔끔하고 조용했다. 대합실 의자에 앉아 오늘 산 찻잔을 꺼내 다시 한번 들여다봤다. 집에 \
        가면 이 잔에 보리차를 담아 마셔야겠다고 생각했다.

        밤 9시 기차를 타고 서울로 돌아왔다. 기차 안에서 오늘 찍은 사진을 정리했다. 삼백 장이 넘었다. \
        흔들린 사진과 비슷한 사진을 지우고 나니 육십 장 정도가 남았다. 그중에서 계림 숲에서 찍은 \
        나뭇잎 사진이 제일 마음에 들었다. 집에 도착하니 자정이 넘었다. 발이 퉁퉁 부었지만 오랜만에 \
        마음이 가벼웠다. 다음에는 불국사와 석굴암까지 넉넉하게 일정을 잡아서 다시 오고 싶다.
        """
}
