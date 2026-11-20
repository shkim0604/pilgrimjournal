import Foundation
import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

/// Field rules of posts, comments and reactions (no database).
final class PostRulesTests: XCTestCase {
    private let seoul = TimeZone(identifier: "Asia/Seoul")!
    private let policy = PostExpiryPolicy()
    /// 2026-11-14 12:00 in Seoul.
    private let now = Date(timeIntervalSince1970: 1_794_625_200)

    private func validate(_ request: CreatePostRequest) throws -> PostRules.ValidatedPost {
        try PostRules.validate(request, now: now, policy: policy)
    }

    private func assertRejected(
        _ request: CreatePostRequest, _ code: APIErrorCode, field: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try validate(request), file: file, line: line) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.code, code, file: file, line: line)
            XCTAssertEqual(apiError?.field, field, file: file, line: line)
        }
    }

    // MARK: - Kinds

    func testPrayerDefaultsToSevenVisibleDaysAndTrimsText() throws {
        let valid = try validate(
            PostRequests.prayer(items: [PrayerItem(text: "  건강  ", topic: " health ", section: " ")]
            )
        )
        XCTAssertEqual(valid.items, [PrayerItem(text: "건강", topic: "health", section: nil)])
        XCTAssertEqual(valid.visibleDays, 7)
        XCTAssertNil(valid.deadline)
        XCTAssertEqual(valid.expiresAt, now + 7 * 86_400)
    }

    func testClientSentAnsweredAtIsDropped() throws {
        let valid = try validate(
            PostRequests.prayer(items: [PrayerItem(text: "건강", answeredAt: now)]))
        XCTAssertEqual(valid.items, [PrayerItem(text: "건강")])
    }

    func testPrayerWithDeadlineHasNoVisibleDays() throws {
        let deadline = LocalDate(now, in: seoul).adding(days: 2)
        let valid = try validate(PostRequests.prayer(deadline: deadline))
        XCTAssertEqual(valid.deadline, deadline)
        XCTAssertNil(valid.visibleDays)
        XCTAssertEqual(valid.expiresAt, deadline.startOfDay(in: seoul) + 4 * 86_400)
    }

    func testPrayerItemsAreRequiredAndBounded() {
        assertRejected(PostRequests.prayer(items: []), .validationFailed, field: "items")
        assertRejected(
            PostRequests.prayer(items: [PrayerItem(text: "   ")]), .validationFailed,
            field: "items")
        assertRejected(
            PostRequests.prayer(items: Array(repeating: PrayerItem(text: "기도"), count: 11)),
            .limitExceeded, field: "items")
        assertRejected(
            PostRequests.prayer(items: [PrayerItem(text: String(repeating: "가", count: 201))]),
            .limitExceeded, field: "items")
        assertRejected(
            PostRequests.prayer(
                items: [PrayerItem(text: "기도", section: String(repeating: "가", count: 31))]),
            .limitExceeded, field: "items")
        var noItems = PostRequests.prayer()
        noItems.items = nil
        assertRejected(noItems, .validationFailed, field: "items")
    }

    func testDeadlineAndVisibleDaysTogetherAreRejected() {
        let deadline = LocalDate(now, in: seoul).adding(days: 1)
        assertRejected(
            PostRequests.prayer(deadline: deadline, visibleDays: 7), .validationFailed,
            field: "visibleDays")
        assertRejected(PostRequests.prayer(visibleDays: 5), .validationFailed, field: "visibleDays")
        assertRejected(
            PostRequests.prayer(deadline: LocalDate(now, in: seoul).adding(days: -1)),
            .validationFailed, field: "deadline")
        assertRejected(
            PostRequests.prayer(deadline: LocalDate(now, in: seoul).adding(days: 366)),
            .validationFailed, field: "deadline")
    }

    func testBookReportNeedsBodyAndBook() throws {
        let valid = try validate(PostRequests.bookReport())
        XCTAssertEqual(valid.book, BookInfo(title: "고백록", author: "아우구스티누스"))
        XCTAssertEqual(valid.expiresAt, now + 7 * 86_400)
        XCTAssertNil(valid.visibleDays)

        var noBook = PostRequests.bookReport()
        noBook.book = nil
        assertRejected(noBook, .validationFailed, field: "book")
        var noBody = PostRequests.bookReport()
        noBody.body = "  "
        assertRejected(noBody, .validationFailed, field: "body")
        var longTitle = PostRequests.bookReport()
        longTitle.book = BookInfo(title: String(repeating: "가", count: 101))
        assertRejected(longTitle, .limitExceeded, field: "book")
    }

    func testOtherKindsRefusePrayerAndBookFields() {
        var items = PostRequests.testimony()
        items.items = [PrayerItem(text: "기도")]
        assertRejected(items, .validationFailed, field: "items")
        var book = PostRequests.testimony()
        book.book = BookInfo(title: "책")
        assertRejected(book, .validationFailed, field: "book")
        var deadline = PostRequests.testimony()
        deadline.deadline = LocalDate(now, in: seoul).adding(days: 1)
        assertRejected(deadline, .validationFailed, field: "deadline")
        var visibleDays = PostRequests.bookReport()
        visibleDays.visibleDays = 7
        assertRejected(visibleDays, .validationFailed, field: "visibleDays")
    }

    func testLengthsTimeZoneLanguageAndPhotos() {
        var title = PostRequests.testimony()
        title.title = String(repeating: "가", count: 81)
        assertRejected(title, .limitExceeded, field: "title")
        assertRejected(
            PostRequests.testimony(String(repeating: "가", count: 2_001)), .limitExceeded,
            field: "body")
        var zone = PostRequests.testimony()
        zone.timeZone = "Mars/Olympus"
        assertRejected(zone, .validationFailed, field: "timeZone")
        var language = PostRequests.testimony()
        language.language = "fr"
        assertRejected(language, .validationFailed, field: "language")
        assertRejected(
            PostRequests.testimony(media: (0..<5).map { _ in UUID() }), .limitExceeded,
            field: "mediaIds")
        let id = UUID()
        assertRejected(
            PostRequests.testimony(media: [id, id]), .validationFailed, field: "mediaIds")
    }

    func testGraphemesCountAsOneCharacter() throws {
        // 2,000 family emoji are many more bytes and scalars than 2,000 but still 2,000 characters.
        let body = String(repeating: "👨‍👩‍👧", count: 2_000)
        XCTAssertEqual(try validate(PostRequests.testimony(body)).body, body)
    }

    // MARK: - Comments

    func testCommentNeedsSomething() throws {
        XCTAssertThrowsError(
            try PostRules.validate(CreateCommentRequest(clientId: UUID(), body: " "))
        ) {
            XCTAssertEqual(($0 as? APIError)?.code, .validationFailed)
        }
        let sticker = UUID()
        let stickerOnly = try PostRules.validate(
            CreateCommentRequest(clientId: UUID(), body: "", stickerId: sticker))
        XCTAssertEqual(stickerOnly, .init(body: "", mediaIDs: [], stickerID: sticker))
        let photo = UUID()
        XCTAssertEqual(
            try PostRules.validate(
                CreateCommentRequest(clientId: UUID(), body: " 아멘 ", mediaIds: [photo])),
            .init(body: "아멘", mediaIDs: [photo], stickerID: nil))
        XCTAssertThrowsError(
            try PostRules.validate(
                CreateCommentRequest(clientId: UUID(), body: String(repeating: "가", count: 501)))
        ) {
            XCTAssertEqual(($0 as? APIError)?.code, .limitExceeded)
            XCTAssertEqual(($0 as? APIError)?.limit, 500)
        }
    }

    // MARK: - Reactions

    func testReactionKeys() throws {
        XCTAssertNoThrow(try PostRules.validate(ReactionKey.emoji("🙏")))
        XCTAssertNoThrow(try PostRules.validate(ReactionKey.sticker(UUID())))
        for bad in ["", "a", "🙏🙏", "아멘"] {
            XCTAssertThrowsError(try PostRules.validate(ReactionKey.emoji(bad)), bad) {
                XCTAssertEqual(($0 as? APIError)?.code, .validationFailed)
            }
        }
    }

    func testReactionRemovalKey() throws {
        XCTAssertEqual(try ReactionRoutes.removalKey(emoji: "🙏", stickerID: nil), .emoji("🙏"))
        let id = UUID()
        XCTAssertEqual(
            try ReactionRoutes.removalKey(emoji: "", stickerID: id.uuidString), .sticker(id))
        XCTAssertThrowsError(try ReactionRoutes.removalKey(emoji: nil, stickerID: nil))
        XCTAssertThrowsError(try ReactionRoutes.removalKey(emoji: "🙏", stickerID: id.uuidString))
        XCTAssertThrowsError(try ReactionRoutes.removalKey(emoji: nil, stickerID: "nope")) {
            XCTAssertEqual(($0 as? APIError)?.code, .invalidRequest)
        }
    }
}
