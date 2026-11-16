#if canImport(XCTest)
import Foundation
import JournalDomain
import XCTest

final class ScrapComposerTests: XCTestCase {
    private let groupID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!
    private let postID = UUID(uuidString: "A1B2C3D4-0000-4000-8000-0000000000AA")!
    private let photo1 = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
    private let photo2 = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
    private let commentPhoto = UUID(uuidString: "B0000000-0000-4000-8000-000000000003")!

    /// 2026-11-14 10:00 in Seoul.
    private let postedAt = Date(timeIntervalSince1970: 1_794_618_000)

    /// Attachment IDs 00000000-…-000000000001, …-000000000002, … in call order.
    private func sequentialIDs() -> () -> UUID {
        var next = 0
        return {
            next += 1
            return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", next))!
        }
    }

    private func prayerPost(photos: [UUID] = []) -> ScrapPost {
        ScrapPost(
            id: postID, groupID: groupID, groupName: "수요 기도모임", kind: .prayer,
            authorName: "민지",
            items: [
                .init(text: "어머니 검사 결과가 좋게 나오도록 기도해 주세요", topic: "health", who: "엄마"),
                .init(text: "이번 주 면접을 차분히 볼 수 있도록 기도해 주세요"),
            ],
            deadline: .init(year: 2026, month: 11, day: 20),
            createdAt: postedAt, timeZoneIdentifier: "Asia/Seoul", photoIDs: photos)
    }

    private var marker: String {
        "pilgrim-scrap: group=a1b2c3d4-0000-4000-8000-000000000001 "
            + "post=a1b2c3d4-0000-4000-8000-0000000000aa"
    }

    func testPrayerRequestWithPhotosAndComments() {
        let comments = [
            ScrapComment(
                authorName: "준호", body: "함께 기도할게요 🙏",
                createdAt: postedAt.addingTimeInterval(2 * 3600)),
            ScrapComment(
                authorName: "수아", body: "", createdAt: postedAt.addingTimeInterval(86_400),
                hasSticker: true),
            ScrapComment(
                authorName: "민수", body: "사진 보냈어요",
                createdAt: postedAt.addingTimeInterval(90_000), photoIDs: [commentPhoto]),
        ]

        let scrap = ScrapComposer.compose(
            post: prayerPost(photos: [photo1, photo2]), comments: comments,
            makeAttachmentID: sequentialIDs())

        XCTAssertEqual(
            scrap.draft.body,
            """
            > 스크랩 · 수요 기도모임
            > 민지 · 기도제목 · 2026년 11월 14일에 올림 · 데드라인 2026년 11월 20일
            > \(marker)

            - 어머니 검사 결과가 좋게 나오도록 기도해 주세요 (엄마/건강)
            - 이번 주 면접을 차분히 볼 수 있도록 기도해 주세요

            ![](attachment:00000000-0000-0000-0000-000000000001)

            ![](attachment:00000000-0000-0000-0000-000000000002)

            ---

            **댓글**

            > 준호 · 11월 14일: 함께 기도할게요 🙏
            > 수아 · 11월 15일: (스티커)
            > 민수 · 11월 15일: 사진 보냈어요

            ![](attachment:00000000-0000-0000-0000-000000000003)
            """)
        XCTAssertEqual(scrap.attachments.map(\.mediaID), [photo1, photo2, commentPhoto])
        XCTAssertEqual(
            scrap.attachments.map(\.originalName), ["scrap-1.jpg", "scrap-2.jpg", "scrap-3.jpg"])
        XCTAssertEqual(Set(scrap.attachments.map(\.mimeType)), ["image/jpeg"])
        for attachment in scrap.attachments {
            XCTAssertTrue(scrap.draft.body.contains("![](attachment:\(attachment.id.uuidString))"))
        }
    }

    func testDraftFields() throws {
        let scrap = ScrapComposer.compose(post: prayerPost(), comments: [])
        XCTAssertEqual(scrap.draft.kind, .scrap)
        XCTAssertNil(scrap.draft.id)
        XCTAssertEqual(scrap.draft.title, "민지의 기도제목")
        XCTAssertEqual(scrap.draft.occurredAt, postedAt)
        XCTAssertEqual(scrap.draft.originalTimeZone, "Asia/Seoul")
        XCTAssertEqual(scrap.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(scrap.draft.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(scrap.draft.visibleTags, [])
        XCTAssertNil(scrap.draft.sourceUUID, "sourceUUID is Day One's duplicate key")
        XCTAssertNil(scrap.draft.sourceMetadata)
        XCTAssertEqual(scrap.draft.details, EntryDetails())
        XCTAssertTrue(scrap.attachments.isEmpty)
        XCTAssertFalse(scrap.draft.body.contains("---"), "no comments, no comment section")
        XCTAssertFalse(scrap.draft.body.contains("attachment:"))
        // It saves like any other entry.
        let validated = try scrap.draft.validated(manual: true)
        XCTAssertEqual(validated.kind, .scrap)
    }

    func testBookReport() {
        let post = ScrapPost(
            id: postID, groupID: groupID, groupName: "청년부 독서모임", kind: .bookReport,
            authorName: "준호", body: "  두 번째 읽으니 다르게 보였어요.\n\n특히 3장.  ",
            book: .init(title: "고백록", author: "아우구스티누스"),
            createdAt: postedAt, timeZoneIdentifier: "Asia/Seoul")
        let scrap = ScrapComposer.compose(post: post, comments: [])
        XCTAssertEqual(scrap.draft.title, "고백록")
        XCTAssertEqual(
            scrap.draft.body,
            """
            > 스크랩 · 청년부 독서모임
            > 준호 · 독후감 · 2026년 11월 14일에 올림
            > \(ScrapMarker.line(groupID: groupID, postID: postID))

            **고백록** · 아우구스티누스

            두 번째 읽으니 다르게 보였어요.

            특히 3장.
            """)
    }

    func testTitleRules() {
        var post = prayerPost()
        post.title = "  이번 주 기도  "
        XCTAssertEqual(ScrapComposer.title(post), "이번 주 기도")
        post.title = "   "
        XCTAssertEqual(ScrapComposer.title(post), "민지의 기도제목")
        post.kind = .testimony
        XCTAssertEqual(ScrapComposer.title(post), "민지의 간증")
        post.kind = .bookReport
        post.book = .init(title: "고백록")
        XCTAssertEqual(ScrapComposer.title(post), "고백록")
        post.book = nil
        XCTAssertEqual(ScrapComposer.title(post), "독후감")
    }

    func testTestimonyWithMultilineCommentsAndStickerText() {
        let post = ScrapPost(
            id: postID, groupID: groupID, groupName: "수요 기도모임", kind: .testimony,
            authorName: "수아", body: "응답받았어요", createdAt: postedAt,
            timeZoneIdentifier: "Asia/Seoul")
        let comments = [
            ScrapComment(authorName: "민지", body: "아멘\n\n축하해요", createdAt: postedAt),
            ScrapComment(authorName: "준호", body: "최고", createdAt: postedAt, hasSticker: true),
        ]
        let body = ScrapComposer.compose(post: post, comments: comments).draft.body
        XCTAssertTrue(
            body.hasSuffix(
                """
                **댓글**

                > 민지 · 11월 14일: 아멘
                >
                > 축하해요
                > 준호 · 11월 14일: 최고 (스티커)
                """), body)
        XCTAssertTrue(body.contains("> 수아 · 간증 · 2026년 11월 14일에 올림\n"))
    }

    func testNamesCannotBreakTheHeader() {
        var post = prayerPost()
        post.groupName = "수요\n기도모임"
        post.authorName = " 민지\n"
        post.items = [.init(text: "건강", topic: "unknown-topic", who: "  ")]
        let scrap = ScrapComposer.compose(post: post, comments: [])
        let lines = scrap.draft.body.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "> 스크랩 · 수요 기도모임")
        XCTAssertTrue(lines[1].hasPrefix("> 민지 · 기도제목"))
        XCTAssertEqual(lines[2], "> \(marker)")
        XCTAssertTrue(scrap.draft.body.contains("\n- 건강\n") || scrap.draft.body.hasSuffix("- 건강"))
        XCTAssertEqual(scrap.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(ScrapComposer.notebookName(groupName: "  "), "스크랩")
    }

    func testPostDateUsesThePostersTimeZone() {
        var post = prayerPost()
        // 2026-11-14 23:30 UTC is already the 15th in Seoul.
        post.createdAt = Date(timeIntervalSince1970: 1_794_699_000)
        XCTAssertTrue(
            ScrapComposer.compose(post: post, comments: []).draft.body.contains("2026년 11월 15일에 올림")
        )
        post.timeZoneIdentifier = "UTC"
        XCTAssertTrue(
            ScrapComposer.compose(post: post, comments: []).draft.body.contains("2026년 11월 14일에 올림")
        )
    }

    private func englishPost() -> ScrapPost {
        var post = prayerPost()
        post.items = [
            .init(
                text: "Pray that Mom's test results come back clear", topic: "health", who: "Mom"),
            .init(text: "Calm for my interview this week"),
        ]
        return post
    }

    func testEnglishPostIsWrittenInEnglishButKeepsTheKoreanNotebook() {
        let scrap = ScrapComposer.compose(
            post: englishPost(),
            comments: [
                ScrapComment(authorName: "Junho", body: "Praying", createdAt: postedAt),
                ScrapComment(
                    authorName: "수아", body: "", createdAt: postedAt.addingTimeInterval(86_400),
                    hasSticker: true),
            ])
        XCTAssertEqual(scrap.draft.title, "민지's prayer requests")
        XCTAssertEqual(scrap.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(scrap.draft.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(
            scrap.draft.body,
            """
            > Scraps · 수요 기도모임
            > 민지 · Prayer requests · Posted on November 14, 2026 · Deadline November 20, 2026
            > \(marker)

            - Pray that Mom's test results come back clear (Mom/health)
            - Calm for my interview this week

            ---

            **Comments**

            > Junho · November 14: Praying
            > 수아 · November 15: (sticker)
            """)
    }

    func testEnglishUntitledTestimonyAndBookReport() {
        var testimony = englishPost()
        testimony.kind = .testimony
        testimony.items = []
        testimony.deadline = nil
        testimony.body = "God provided a way."
        XCTAssertEqual(ScrapComposer.title(testimony), "민지's testimony")
        let body = ScrapComposer.compose(post: testimony, comments: []).draft.body
        XCTAssertTrue(body.contains("> 민지 · Testimony · Posted on November 14, 2026\n"), body)

        var report = testimony
        report.kind = .bookReport
        report.book = .init(title: "Mere Christianity", author: "C. S. Lewis")
        XCTAssertEqual(ScrapComposer.title(report), "Mere Christianity")
        XCTAssertTrue(
            ScrapComposer.compose(post: report, comments: []).draft.body.contains(
                " · Book report · "))
    }

    func testOneGroupsKoreanAndEnglishPostsShareTheNotebook() {
        let korean = ScrapComposer.compose(post: prayerPost(), comments: [])
        let english = ScrapComposer.compose(post: englishPost(), comments: [])
        XCTAssertEqual(korean.notebookName, english.notebookName)
        XCTAssertEqual(
            ScrapComposer.notebookName(groupName: "Wednesday prayer"), "스크랩 · Wednesday prayer")
        XCTAssertEqual(ScrapComposer.notebookPrefix, "스크랩")
    }

    func testFixedWordSetsNeverComeFromTheDevice() {
        XCTAssertEqual(ScrapLabels.korean.scrap, "스크랩")
        XCTAssertEqual(ScrapLabels.english.scrap, "Scraps")
        XCTAssertEqual(ScrapLabels.korean.locale.identifier, "ko_KR")
        XCTAssertEqual(ScrapLabels.english.locale.identifier, "en_US")
        XCTAssertEqual(ScrapLabels.english.posted("x"), "Posted on x")
        XCTAssertEqual(ScrapLabels.english.deadline("x"), "Deadline x")
        XCTAssertEqual(ScrapLabels.english.prayerTitle("Minji"), "Minji's prayer requests")
        XCTAssertEqual(ScrapLabels.english.testimonyTitle("Minji"), "Minji's testimony")
        XCTAssertEqual(ScrapLabels.english.comments, "Comments")
        XCTAssertEqual(ScrapLabels.english.sticker, "(sticker)")
        XCTAssertEqual(ScrapLabels.english.topicName("finances"), "finances")
        XCTAssertNil(ScrapLabels.english.topicName("unknown-topic"))
        XCTAssertEqual(ScrapLabels.korean.topicName("finances"), "재정")
        XCTAssertEqual(
            Set(ScrapLabels.englishTopicNames.keys), Set(ScrapLabels.koreanTopicNames.keys))
        XCTAssertEqual(ScrapLabels.labels(for: .english).scrap, "Scraps")
        XCTAssertEqual(ScrapLabels.labels(for: prayerPost()).scrap, "스크랩")
    }

    func testMarkerParsing() {
        let body = ScrapComposer.compose(post: prayerPost(), comments: []).draft.body
        XCTAssertEqual(ScrapMarker.postIDs(in: body), [postID])
        XCTAssertTrue(ScrapMarker.contains(postID: postID, in: body))
        XCTAssertFalse(ScrapMarker.contains(postID: UUID(), in: body))
        XCTAssertTrue(
            ScrapMarker.contains(
                postID: postID, in: ScrapMarker.line(groupID: groupID, postID: postID)))
        XCTAssertFalse(
            ScrapMarker.contains(postID: postID, in: "post=\(postID.uuidString.lowercased())"),
            "only a marker line counts")
        XCTAssertTrue(ScrapMarker.postIDs(in: "pilgrim-scrap: group=x post=not-a-uuid").isEmpty)
    }

    func testDeterministic() {
        let first = ScrapComposer.compose(
            post: prayerPost(photos: [photo1]), comments: [], makeAttachmentID: sequentialIDs())
        let second = ScrapComposer.compose(
            post: prayerPost(photos: [photo1]), comments: [], makeAttachmentID: sequentialIDs())
        XCTAssertEqual(first, second)
    }
}

final class ScrapLanguageTests: XCTestCase {
    private func post(
        title: String? = nil, body: String? = nil, items: [ScrapPost.PrayerLine] = [],
        author: String = "민지", groupName: String = "수요 기도모임", book: ScrapPost.Book? = nil
    ) -> ScrapPost {
        ScrapPost(
            id: UUID(), groupID: UUID(), groupName: groupName, kind: .prayer, authorName: author,
            title: title, body: body, items: items, book: book, createdAt: Date(),
            timeZoneIdentifier: "Asia/Seoul")
    }

    func testAnyHangulInTitleBodyOrItemsMakesItKorean() {
        XCTAssertEqual(ScrapLanguage.of(post(title: "기도 부탁")), .korean)
        XCTAssertEqual(ScrapLanguage.of(post(body: "Please pray 감사합니다")), .korean)
        XCTAssertEqual(ScrapLanguage.of(post(items: [.init(text: "건강")])), .korean)
        XCTAssertEqual(ScrapLanguage.of(post(items: [.init(text: "health", who: "엄마")])), .korean)
        XCTAssertEqual(
            ScrapLanguage.of(post(title: "Prayer", body: "Mostly English, one word 은혜.")), .korean)
    }

    func testNoHangulIsEnglish() {
        XCTAssertEqual(ScrapLanguage.of(post(body: "Please pray for my exams")), .english)
        XCTAssertEqual(ScrapLanguage.of(post(items: [.init(text: "Job", who: "Dad")])), .english)
        XCTAssertEqual(ScrapLanguage.of(post()), .english, "nothing to read")
        XCTAssertEqual(ScrapLanguage.of(post(body: "   \n")), .english)
        XCTAssertEqual(ScrapLanguage.of(post(body: "🙏 2026-11-20 !!")), .english)
        XCTAssertEqual(ScrapLanguage.of(post(body: "お祈りください 祈祷")), .english, "Japanese, Chinese")
    }

    func testNamesDoNotDecide() {
        XCTAssertEqual(
            ScrapLanguage.of(
                post(
                    body: "Thank you all", author: "김민지", groupName: "수요 기도모임",
                    book: .init(title: "순전한 기독교", author: "루이스"))),
            .english)
    }

    func testEveryHangulBlockCounts() {
        for text in [
            "가", "힣", // syllables
            "\u{1100}", "\u{11FF}", // conjoining jamo
            "ㄱ", "ㅋㅋ", "ㅏ", // compatibility jamo
            "\u{A960}", "\u{D7B0}", "\u{D7FB}", // extended A and B
            "\u{FFA1}", "\u{FFDC}", // halfwidth
            "가\u{0301}", // with a combining mark
        ] {
            XCTAssertTrue(ScrapLanguage.containsHangul(text), text)
        }
        for text in ["", "abc", "\u{10FF}", "\u{3190}", "\u{D7A4}", "\u{FFDD}", "é", "ü"] {
            XCTAssertFalse(ScrapLanguage.containsHangul(text), text)
        }
    }
}
#endif
