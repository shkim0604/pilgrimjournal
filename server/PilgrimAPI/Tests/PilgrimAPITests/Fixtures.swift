#if canImport(XCTest)
import Foundation
import PilgrimAPI
import XCTest

/// Shared fixed values and JSON fragments for the DTO round-trip tests.
enum Fixture {
    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func idString(_ n: Int) -> String { id(n).uuidString.lowercased() }

    static let date = PilgrimDateFormat.date(from: "2026-11-14T13:05:00.123Z")!
    static let dateString = "2026-11-14T13:05:00.123Z"
    static let laterDate = PilgrimDateFormat.date(from: "2026-11-21T13:05:00.123Z")!
    static let laterDateString = "2026-11-21T13:05:00.123Z"

    static let mediaURL = URL(
        string: "https://pilgrim.delight-house.org/api/media-files/x?exp=1&sig=s")!
    static let media = MediaRef(
        id: id(90), width: 1600, height: 1200, byteCount: 400_000, url: mediaURL,
        urlExpiresAt: date)
    static let mediaJSON = """
        {"byteCount":400000,"height":1200,"id":"\(idString(90))",\
        "url":"https://pilgrim.delight-house.org/api/media-files/x?exp=1&sig=s",\
        "urlExpiresAt":"\(dateString)","width":1600}
        """

    static let user = UserSummary(id: id(1), displayName: "민지", profilePhoto: media)
    static let userJSON = """
        {"displayName":"민지","id":"\(idString(1))","profilePhoto":\(mediaJSON)}
        """
    static let otherUser = UserSummary(id: id(2), displayName: "준호")
    static let otherUserJSON = """
        {"displayName":"준호","id":"\(idString(2))"}
        """

    static let entitlement = EntitlementResponse(
        subscriptionRequired: false, active: true, status: .none)
    static let entitlementJSON = """
        {"active":true,"status":"none","subscriptionRequired":false}
        """

    static let me = MeResponse(
        id: id(1), displayName: "민지", profilePhoto: nil, profileComplete: true,
        timeZone: "Asia/Seoul", dailyReportEnabled: true,
        dailyReportTime: LocalTime(hour: 22, minute: 0)!, suspendedUntil: nil, createdAt: date,
        entitlement: entitlement)
    static let meJSON = """
        {"createdAt":"\(dateString)","dailyReportEnabled":true,"dailyReportTime":"22:00",\
        "displayName":"민지","entitlement":\(entitlementJSON),"id":"\(idString(1))",\
        "profileComplete":true,"timeZone":"Asia/Seoul"}
        """

    static let sticker = StickerResponse(
        id: id(70), groupId: id(10), name: "아멘", media: media, createdBy: otherUser,
        createdAt: date, isMine: false)
    static let stickerJSON = """
        {"createdAt":"\(dateString)","createdBy":\(otherUserJSON),"groupId":"\(idString(10))",\
        "id":"\(idString(70))","isMine":false,"media":\(mediaJSON),"name":"아멘"}
        """

    static let reactions = [
        ReactionSummary(key: .emoji("🙏"), count: 3, reactedByMe: true),
        ReactionSummary(key: .sticker(id(70)), count: 1, reactedByMe: false),
    ]
    static let reactionsJSON = """
        [{"count":3,"key":{"emoji":"🙏","type":"emoji"},"reactedByMe":true},\
        {"count":1,"key":{"stickerId":"\(idString(70))","type":"sticker"},"reactedByMe":false}]
        """

    static let post = PostResponse(
        id: id(50), groupId: id(10), kind: .prayer, author: user, isMine: true, title: nil,
        body: "함께 기도해 주세요",
        items: [
            PrayerItem(text: "어머니 검사 결과", topic: "health", who: "엄마"),
            PrayerItem(text: "면접"),
        ],
        book: nil, deadline: LocalDate("2026-11-20"), visibleDays: nil, timeZone: "Asia/Seoul",
        language: "ko", createdAt: date, expiresAt: laterDate, extensionCount: 0,
        media: [media], commentCount: 2, reactions: reactions, isUnread: false)
    static let postJSON = """
        {"author":\(userJSON),"body":"함께 기도해 주세요","commentCount":2,\
        "createdAt":"\(dateString)","deadline":"2026-11-20","expiresAt":"\(laterDateString)",\
        "extensionCount":0,"groupId":"\(idString(10))","id":"\(idString(50))","isMine":true,\
        "isUnread":false,"items":[{"text":"어머니 검사 결과","topic":"health","who":"엄마"},\
        {"text":"면접"}],"kind":"prayer","language":"ko","media":[\(mediaJSON)],\
        "reactions":\(reactionsJSON),"timeZone":"Asia/Seoul"}
        """

    static let comment = CommentResponse(
        id: id(60), postId: id(50), author: otherUser, isMine: false, body: "함께 기도할게요",
        media: [], sticker: sticker, stickerRemoved: false, createdAt: date)
    static let commentJSON = """
        {"author":\(otherUserJSON),"body":"함께 기도할게요","createdAt":"\(dateString)",\
        "id":"\(idString(60))","isMine":false,"media":[],"postId":"\(idString(50))",\
        "sticker":\(stickerJSON),"stickerRemoved":false}
        """

    static let summary = GroupSummary(
        id: id(10), name: "수요 기도모임", status: .active, memberCount: 5, isAdmin: true,
        admin: user, unreadCount: 2, latestPostAt: date,
        notifications: GroupNotificationSettings(
            newPostPushEnabled: true, dailyReportEnabled: false
        ))
    static let summaryFieldsJSON = """
        "admin":\(userJSON),"id":"\(idString(10))","isAdmin":true,"latestPostAt":"\(dateString)",\
        "memberCount":5,"name":"수요 기도모임",\
        "notifications":{"dailyReportEnabled":false,"newPostPushEnabled":true},\
        "status":"active","unreadCount":2
        """

    static let snapshot = ReportSnapshot(
        authorId: id(2), authorName: "준호", title: nil, body: "본문", items: nil,
        book: BookInfo(title: "고백록", author: "아우구스티누스"), mediaIds: [id(90)],
        capturedAt: date)
    static let snapshotJSON = """
        {"authorId":"\(idString(2))","authorName":"준호","body":"본문",\
        "book":{"author":"아우구스티누스","title":"고백록"},"capturedAt":"\(dateString)",\
        "mediaIds":["\(idString(90))"]}
        """

    static let adminReport = AdminReport(
        id: id(80), createdAt: date, status: .open, reason: .spam, note: nil, targetType: .post,
        targetId: id(50), groupId: id(10), groupName: "수요 기도모임",
        reporter: AdminUserRef(id: id(1), displayName: "민지"),
        targetUser: AdminUserRef(id: id(2), displayName: "준호", suspendedUntil: laterDate),
        snapshot: snapshot)
    static let adminReportJSON = """
        {"createdAt":"\(dateString)","groupId":"\(idString(10))","groupName":"수요 기도모임",\
        "id":"\(idString(80))","reason":"spam","reporter":{"displayName":"민지",\
        "id":"\(idString(1))"},"snapshot":\(snapshotJSON),"status":"open",\
        "targetId":"\(idString(50))","targetType":"post","targetUser":{"displayName":"준호",\
        "id":"\(idString(2))","suspendedUntil":"\(laterDateString)"}}
        """
}

/// Decodes `json` and compares it with `value`, then encodes `value` and compares the JSON with
/// `json` structurally (key order and whitespace do not matter, keys and values do).
func assertRoundTrip<T: Codable & Equatable>(
    _ value: T, json: String, file: StaticString = #filePath, line: UInt = #line
) {
    do {
        let decoded = try PilgrimJSON.decoder.decode(T.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, value, "decoding the fixture", file: file, line: line)
        let encoded = try PilgrimJSON.encoder.encode(value)
        XCTAssertEqual(
            try canonical(encoded), try canonical(Data(json.utf8)), "encoding the value",
            file: file, line: line)
    } catch {
        XCTFail("\(T.self): \(error)", file: file, line: line)
    }
}

func canonical(_ data: Data) throws -> String {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    let normalized = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    return String(decoding: normalized, as: UTF8.self)
}
#endif
