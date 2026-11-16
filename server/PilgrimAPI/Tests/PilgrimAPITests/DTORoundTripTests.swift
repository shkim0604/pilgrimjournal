#if canImport(XCTest)
import Foundation
import PilgrimAPI
import XCTest

typealias F = Fixture

final class CommonDTOTests: XCTestCase {
    func testErrorBody() {
        let body = APIErrorBody(
            error: APIError(
                code: .limitExceeded, message: "too many items", field: "items", limit: 10))
        assertRoundTrip(
            body,
            json: """
                {"error":{"code":"LIMIT_EXCEEDED","field":"items","limit":10,\
                "message":"too many items"}}
                """)
    }

    func testErrorBodyAcceptsExplicitNullsAndUnknownCodes() throws {
        let json = """
            { "error": { "code": "SOMETHING_NEW", "message": "x",
                         "field": null, "limit": null, "retryAfter": null } }
            """
        let body = try PilgrimJSON.decode(APIErrorBody.self, from: Data(json.utf8))
        XCTAssertEqual(body.error.code, .unknown)
        XCTAssertNil(body.error.field)
    }

    func testEveryErrorCodeRoundTripsAndHasAStatus() throws {
        for code in APIErrorCode.allCases where code != .unknown {
            let data = try PilgrimJSON.encode(code)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(code.rawValue)\"")
            XCTAssertEqual(try PilgrimJSON.decode(APIErrorCode.self, from: data), code)
            XCTAssertTrue((400...599).contains(code.httpStatus), "\(code)")
        }
        XCTAssertEqual(APIErrorCode.inviteFull.httpStatus, 409)
        XCTAssertEqual(APIErrorCode.inviteExpired.httpStatus, 410)
        XCTAssertEqual(APIErrorCode.clientUpgradeRequired.httpStatus, 426)
        XCTAssertEqual(APIErrorCode.subscriptionRequired.httpStatus, 402)
        XCTAssertEqual(APIErrorCode.mediaTooLarge.httpStatus, 413)
        XCTAssertEqual(APIErrorCode.appleCodeExchangeFailed.httpStatus, 502)
    }

    func testPageAndEmptyBody() {
        let page = Page(
            items: [MemberResponse(user: F.otherUser, isAdmin: false, joinedAt: F.date)],
            nextCursor: "abc")
        assertRoundTrip(
            page,
            json: """
                {"items":[{"isAdmin":false,"joinedAt":"\(F.dateString)","user":\(F.otherUserJSON)}],\
                "nextCursor":"abc"}
                """)
        assertRoundTrip(EmptyBody(), json: "{}")
    }

    func testMediaAndUser() {
        assertRoundTrip(F.media, json: F.mediaJSON)
        assertRoundTrip(F.user, json: F.userJSON)
        assertRoundTrip(UploadResponse(media: F.media), json: "{\"media\":\(F.mediaJSON)}")
        assertRoundTrip(
            MediaURLResponse(url: F.mediaURL, expiresAt: F.date),
            json: """
                {"expiresAt":"\(F.dateString)",\
                "url":"https://pilgrim.delight-house.org/api/media-files/x?exp=1&sig=s"}
                """)
    }

    func testHealth() {
        assertRoundTrip(
            HealthResponse(
                status: .degraded, database: true,
                worker: WorkerHealth(lastBeatAt: F.date, healthy: false), version: "0.1.0"),
            json: """
                {"database":true,"status":"degraded","version":"0.1.0",\
                "worker":{"healthy":false,"lastBeatAt":"\(F.dateString)"}}
                """)
    }

    func testIDsAreWrittenLowercaseAndReadInEitherCase() throws {
        let request = TransferAdminRequest(userId: F.id(7))
        let json = String(decoding: try PilgrimJSON.encode(request), as: UTF8.self)
        XCTAssertEqual(json, "{\"userId\":\"\(F.idString(7))\"}")
        let upper = "{\"userId\":\"\(F.id(7).uuidString.uppercased())\"}"
        XCTAssertEqual(
            try PilgrimJSON.decode(TransferAdminRequest.self, from: Data(upper.utf8)), request)
    }

    func testDatesAreReadWithOrWithoutFractionalSeconds() throws {
        let json = "{\"id\":\"\(F.idString(1))\",\"createdAt\":\"2026-11-14T13:05:00Z\"}"
        let receipt = try PilgrimJSON.decode(ReportReceipt.self, from: Data(json.utf8))
        XCTAssertEqual(
            PilgrimDateFormat.string(from: receipt.createdAt), "2026-11-14T13:05:00.000Z")
        XCTAssertNil(PilgrimDateFormat.date(from: "2026-11-14 13:05:00"))
    }
}

final class AccountDTOTests: XCTestCase {
    func testAuthRequests() {
        assertRoundTrip(
            AppleSignInRequest(
                identityToken: "jwt", authorizationCode: "code", rawNonce: "nonce",
                bundleId: BundleIDs.debug, installationId: F.id(3)),
            json: """
                {"authorizationCode":"code","bundleId":"com.dhouse.PilgrimJournal.debug",\
                "identityToken":"jwt","installationId":"\(F.idString(3))","rawNonce":"nonce"}
                """)
        assertRoundTrip(
            RefreshRequest(refreshToken: "r", installationId: F.id(3)),
            json: "{\"installationId\":\"\(F.idString(3))\",\"refreshToken\":\"r\"}")
        assertRoundTrip(
            LogoutRequest(refreshToken: "r", installationId: F.id(3)),
            json: "{\"installationId\":\"\(F.idString(3))\",\"refreshToken\":\"r\"}")
        assertRoundTrip(
            DevSignInRequest(
                devUser: "alice", bundleId: BundleIDs.release, installationId: F.id(3)),
            json: """
                {"bundleId":"com.dhouse.PilgrimJournal","devUser":"alice",\
                "installationId":"\(F.idString(3))"}
                """)
    }

    func testSessionAndMe() {
        assertRoundTrip(F.me, json: F.meJSON)
        assertRoundTrip(
            AuthSessionResponse(
                accessToken: "a", accessTokenExpiresAt: F.date, refreshToken: "r",
                refreshTokenExpiresAt: F.laterDate, user: F.me),
            json: """
                {"accessToken":"a","accessTokenExpiresAt":"\(F.dateString)","refreshToken":"r",\
                "refreshTokenExpiresAt":"\(F.laterDateString)","user":\(F.meJSON)}
                """)
    }

    func testUpdateMeOmitsUnchangedFields() {
        assertRoundTrip(
            UpdateMeRequest(displayName: "민지", dailyReportTime: LocalTime(hour: 7, minute: 30)),
            json: "{\"dailyReportTime\":\"07:30\",\"displayName\":\"민지\"}")
        assertRoundTrip(
            UpdateMeRequest(
                profilePhotoId: F.id(90), removeProfilePhoto: false, timeZone: "Europe/Berlin",
                dailyReportEnabled: false),
            json: """
                {"dailyReportEnabled":false,"profilePhotoId":"\(F.idString(90))",\
                "removeProfilePhoto":false,"timeZone":"Europe/Berlin"}
                """)
    }

    func testAccountDeletion() {
        assertRoundTrip(
            AccountDeletionResponse(
                deletedAt: F.date, alreadyDeleted: false, groupsHandedToVote: [F.id(10)],
                groupsDeleted: [F.id(11)]),
            json: """
                {"alreadyDeleted":false,"deletedAt":"\(F.dateString)",\
                "groupsDeleted":["\(F.idString(11))"],"groupsHandedToVote":["\(F.idString(10))"]}
                """)
        assertRoundTrip(
            AccountDeletionResponse(deletedAt: nil, alreadyDeleted: true),
            json: "{\"alreadyDeleted\":true,\"groupsDeleted\":[],\"groupsHandedToVote\":[]}")
    }

    func testDeviceRegistration() {
        assertRoundTrip(
            DeviceRegistrationRequest(
                apnsToken: "abcdef", apnsEnvironment: .sandbox, bundleId: BundleIDs.debug,
                platform: .ios, locale: "ko_KR", timeZone: "Asia/Seoul", appVersion: "1.3.0"),
            json: """
                {"apnsEnvironment":"sandbox","apnsToken":"abcdef","appVersion":"1.3.0",\
                "bundleId":"com.dhouse.PilgrimJournal.debug","locale":"ko_KR","platform":"ios",\
                "timeZone":"Asia/Seoul"}
                """)
    }

    func testHides() {
        assertRoundTrip(
            HidesResponse(
                posts: [
                    HiddenPost(
                        postId: F.id(50), groupId: F.id(10), groupName: "수요 기도모임", title: nil,
                        hiddenAt: F.date)
                ],
                users: [HiddenUser(user: F.otherUser, hiddenAt: F.date)]),
            json: """
                {"posts":[{"groupId":"\(F.idString(10))","groupName":"수요 기도모임",\
                "hiddenAt":"\(F.dateString)","postId":"\(F.idString(50))"}],\
                "users":[{"hiddenAt":"\(F.dateString)","user":\(F.otherUserJSON)}]}
                """)
    }

    func testSubscriptions() {
        assertRoundTrip(F.entitlement, json: F.entitlementJSON)
        assertRoundTrip(
            EntitlementResponse(
                subscriptionRequired: true, active: true, status: .gracePeriod,
                productId: SubscriptionProduct.groupsMonthly, expiresAt: F.laterDate),
            json: """
                {"active":true,"expiresAt":"\(F.laterDateString)",\
                "productId":"com.dhouse.PilgrimJournal.groups.monthly","status":"gracePeriod",\
                "subscriptionRequired":true}
                """)
        assertRoundTrip(
            VerifySubscriptionRequest(signedTransaction: "jws", bundleId: BundleIDs.release),
            json: "{\"bundleId\":\"com.dhouse.PilgrimJournal\",\"signedTransaction\":\"jws\"}")
        assertRoundTrip(
            AppStoreNotificationRequest(signedPayload: "p"), json: "{\"signedPayload\":\"p\"}")
    }

    func testEntitlementPolicy() {
        XCTAssertTrue(
            EntitlementPolicy.isActive(status: .active, expiresAt: F.laterDate, now: F.date))
        XCTAssertTrue(
            EntitlementPolicy.isActive(status: .gracePeriod, expiresAt: F.laterDate, now: F.date))
        XCTAssertFalse(
            EntitlementPolicy.isActive(status: .billingRetry, expiresAt: F.laterDate, now: F.date))
        XCTAssertFalse(
            EntitlementPolicy.isActive(status: .active, expiresAt: F.date, now: F.laterDate))
        XCTAssertFalse(EntitlementPolicy.isActive(status: .active, expiresAt: nil, now: F.date))
    }

    func testDailyReport() {
        let post = DailyReportPost(
            postId: F.id(50), kind: .bookReport, title: "고백록", author: F.otherUser, count: 2,
            expiresAt: F.laterDate)
        let postJSON = """
            {"author":\(F.otherUserJSON),"count":2,"expiresAt":"\(F.laterDateString)",\
            "kind":"bookReport","postId":"\(F.idString(50))","title":"고백록"}
            """
        assertRoundTrip(
            DailyReportResponse(
                date: LocalDate("2026-11-14")!, windowStart: F.date, windowEnd: F.laterDate,
                totalCount: 2,
                groups: [
                    DailyReportGroup(
                        groupId: F.id(10), groupName: "수요 기도모임", newPosts: [post],
                        expiringSoon: [post])
                ]),
            json: """
                {"date":"2026-11-14","groups":[{"commentsOnMyPosts":[],"expiringSoon":[\(postJSON)],\
                "extendedPosts":[],"groupId":"\(F.idString(10))","groupName":"수요 기도모임",\
                "newPosts":[\(postJSON)],"reactionsOnMyPosts":[]}],"totalCount":2,\
                "windowEnd":"\(F.laterDateString)","windowStart":"\(F.dateString)"}
                """)
    }

    func testDailyReportTitleFallsBackAndTruncates() {
        XCTAssertEqual(
            DailyReportPost.title(title: " 제목 ", book: nil, items: nil, body: nil), "제목")
        XCTAssertEqual(
            DailyReportPost.title(
                title: nil, book: BookInfo(title: "고백록"), items: nil, body: "본문"), "고백록")
        let long = String(repeating: "가", count: 50)
        XCTAssertEqual(
            DailyReportPost.title(
                title: "", book: nil, items: [PrayerItem(text: long)], body: nil
            ).count, 40)
    }
}

final class GroupDTOTests: XCTestCase {
    func testGroupSummaryAndDetail() {
        assertRoundTrip(F.summary, json: "{\(F.summaryFieldsJSON)}")
        let detail = GroupDetail(
            summary: F.summary, createdAt: F.date, createdBy: F.user, deletionReason: nil,
            stickerCount: 3, activeInviteCount: 1)
        assertRoundTrip(
            detail,
            json: """
                {\(F.summaryFieldsJSON),"activeInviteCount":1,"createdAt":"\(F.dateString)",\
                "createdBy":\(F.userJSON),"stickerCount":3}
                """)
        XCTAssertEqual(detail.summary, F.summary)

        var pending = F.summary
        pending.status = .pendingDeletion
        pending.admin = nil
        pending.isAdmin = false
        pending.deleteAt = F.laterDate
        let pendingDetail = GroupDetail(
            summary: pending, createdAt: F.date, createdBy: nil, deletionReason: .noVotes,
            stickerCount: 0)
        assertRoundTrip(
            pendingDetail,
            json: """
                {"createdAt":"\(F.dateString)","deleteAt":"\(F.laterDateString)",\
                "deletionReason":"noVotes","id":"\(F.idString(10))","isAdmin":false,\
                "latestPostAt":"\(F.dateString)","memberCount":5,"name":"수요 기도모임",\
                "notifications":{"dailyReportEnabled":false,"newPostPushEnabled":true},\
                "status":"pendingDeletion","stickerCount":0,"unreadCount":2}
                """)
    }

    func testGroupRequests() {
        assertRoundTrip(
            CreateGroupRequest(clientId: F.id(4), name: "수요 기도모임"),
            json: "{\"clientId\":\"\(F.idString(4))\",\"name\":\"수요 기도모임\"}")
        assertRoundTrip(UpdateGroupRequest(name: "목요 모임"), json: "{\"name\":\"목요 모임\"}")
        assertRoundTrip(
            TransferAdminRequest(userId: F.id(2)), json: "{\"userId\":\"\(F.idString(2))\"}")
        assertRoundTrip(
            GroupNotificationSettings(newPostPushEnabled: false, dailyReportEnabled: true),
            json: "{\"dailyReportEnabled\":true,\"newPostPushEnabled\":false}")
        assertRoundTrip(
            BanResponse(user: F.otherUser, bannedAt: F.date),
            json: "{\"bannedAt\":\"\(F.dateString)\",\"user\":\(F.otherUserJSON)}")
    }

    func testVotes() {
        assertRoundTrip(
            VoteResponse(
                round: 2, startedAt: F.date, endsAt: F.laterDate,
                candidates: [F.user, F.otherUser], myBallot: F.id(2), ballotCount: 3,
                eligibleCount: 4),
            json: """
                {"ballotCount":3,"candidates":[\(F.userJSON),\(F.otherUserJSON)],\
                "eligibleCount":4,"endsAt":"\(F.laterDateString)","myBallot":"\(F.idString(2))",\
                "round":2,"startedAt":"\(F.dateString)"}
                """)
        assertRoundTrip(
            CastBallotRequest(candidateUserId: F.id(2)),
            json: "{\"candidateUserId\":\"\(F.idString(2))\"}")
    }

    func testInvites() {
        assertRoundTrip(
            CreateInviteRequest(clientId: F.id(5), maxUses: 10),
            json: "{\"clientId\":\"\(F.idString(5))\",\"maxUses\":10}")
        assertRoundTrip(
            InviteResponse(
                code: "7K3M9QX2P4HD",
                url: URL(string: "https://pilgrim.delight-house.org/i/7K3M9QX2P4HD")!,
                maxUses: 10, useCount: 2, expiresAt: F.laterDate, createdAt: F.date,
                createdBy: F.user),
            json: """
                {"code":"7K3M9QX2P4HD","createdAt":"\(F.dateString)","createdBy":\(F.userJSON),\
                "expiresAt":"\(F.laterDateString)","maxUses":10,\
                "url":"https://pilgrim.delight-house.org/i/7K3M9QX2P4HD","useCount":2}
                """)
        assertRoundTrip(
            InvitePreviewResponse(
                code: "7K3M9QX2P4HD", groupId: F.id(10), groupName: "수요 기도모임", memberCount: 5,
                invitedBy: nil, expiresAt: F.laterDate, alreadyMember: false,
                requiresSubscription: false),
            json: """
                {"alreadyMember":false,"code":"7K3M9QX2P4HD","expiresAt":"\(F.laterDateString)",\
                "groupId":"\(F.idString(10))","groupName":"수요 기도모임","memberCount":5,\
                "requiresSubscription":false}
                """)
    }
}

final class ContentDTOTests: XCTestCase {
    func testCreatePost() {
        assertRoundTrip(
            CreatePostRequest(
                clientId: F.id(6), kind: .prayer, items: [PrayerItem(text: "면접", topic: "work")],
                deadline: LocalDate("2026-11-20"), timeZone: "Asia/Seoul", language: "ko"),
            json: """
                {"clientId":"\(F.idString(6))","deadline":"2026-11-20",\
                "items":[{"text":"면접","topic":"work"}],"kind":"prayer","language":"ko",\
                "mediaIds":[],"timeZone":"Asia/Seoul"}
                """)
        assertRoundTrip(
            CreatePostRequest(
                clientId: F.id(6), kind: .bookReport, title: "읽고 나서", body: "좋았다",
                book: BookInfo(title: "고백록", author: "아우구스티누스"), timeZone: "Asia/Seoul",
                mediaIds: [F.id(90)]),
            json: """
                {"body":"좋았다","book":{"author":"아우구스티누스","title":"고백록"},\
                "clientId":"\(F.idString(6))","kind":"bookReport","mediaIds":["\(F.idString(90))"],\
                "timeZone":"Asia/Seoul","title":"읽고 나서"}
                """)
    }

    func testPostResponse() {
        assertRoundTrip(F.post, json: F.postJSON)
        assertRoundTrip(
            ExtendPostRequest(clientId: F.id(8)), json: "{\"clientId\":\"\(F.idString(8))\"}")
    }

    func testComments() {
        assertRoundTrip(F.comment, json: F.commentJSON)
        assertRoundTrip(
            CreateCommentRequest(clientId: F.id(9), body: "", mediaIds: [], stickerId: F.id(70)),
            json: """
                {"body":"","clientId":"\(F.idString(9))","mediaIds":[],\
                "stickerId":"\(F.idString(70))"}
                """)
        let removed = CommentResponse(
            id: F.id(61), postId: F.id(50), author: F.otherUser, isMine: false, body: "",
            stickerRemoved: true, createdAt: F.date)
        assertRoundTrip(
            removed,
            json: """
                {"author":\(F.otherUserJSON),"body":"","createdAt":"\(F.dateString)",\
                "id":"\(F.idString(61))","isMine":false,"media":[],"postId":"\(F.idString(50))",\
                "stickerRemoved":true}
                """)
    }

    func testReactions() {
        assertRoundTrip(F.reactions, json: F.reactionsJSON)
        assertRoundTrip(
            ReactionRequest(key: .emoji("❤️")),
            json: "{\"key\":{\"emoji\":\"❤️\",\"type\":\"emoji\"}}")
        assertRoundTrip(
            ReactionRequest(key: .sticker(F.id(70))),
            json: "{\"key\":{\"stickerId\":\"\(F.idString(70))\",\"type\":\"sticker\"}}")
        XCTAssertEqual(ReactionKey.sticker(F.id(70)).queryItem.value, F.idString(70))
        XCTAssertEqual(ReactionKey.emoji("🙏").queryItem.name, "emoji")
        XCTAssertThrowsError(
            try PilgrimJSON.decode(ReactionKey.self, from: Data("{\"type\":\"gif\"}".utf8)))
    }

    func testStickers() {
        assertRoundTrip(F.sticker, json: F.stickerJSON)
        assertRoundTrip(
            CreateStickerRequest(clientId: F.id(9), mediaId: F.id(91), name: nil),
            json: "{\"clientId\":\"\(F.idString(9))\",\"mediaId\":\"\(F.idString(91))\"}")
    }

    func testReports() {
        assertRoundTrip(
            CreateReportRequest(
                clientId: F.id(9), targetType: .comment, targetId: F.id(60), groupId: F.id(10),
                reason: .selfHarm, note: "걱정돼요"),
            json: """
                {"clientId":"\(F.idString(9))","groupId":"\(F.idString(10))","note":"걱정돼요",\
                "reason":"selfHarm","targetId":"\(F.idString(60))","targetType":"comment"}
                """)
        assertRoundTrip(
            ReportReceipt(id: F.id(80), createdAt: F.date),
            json: "{\"createdAt\":\"\(F.dateString)\",\"id\":\"\(F.idString(80))\"}")
    }
}

final class PushAndAdminDTOTests: XCTestCase {
    func testNewPostPushMatchesTheDesignPayload() {
        let payload = PushPayload.newPost(
            groupID: F.id(10), postID: F.id(50), kind: .prayer, groupName: "수요 기도모임",
            authorName: "민지")
        assertRoundTrip(
            payload,
            json: """
                { "aps": { "alert": { "title-loc-key": "GROUP_PUSH_TITLE",
                                      "title-loc-args": ["수요 기도모임"],
                                      "loc-key": "GROUP_NEW_POST_PRAYER", "loc-args": ["민지"] },
                           "sound": "default", "thread-id": "group-\(F.idString(10))" },
                  "pilgrim": { "v": 1, "kind": "newPost", "groupId": "\(F.idString(10))",
                               "postId": "\(F.idString(50))" } }
                """)
    }

    func testOtherPushPayloads() {
        let report = PushPayload.dailyReport(itemCount: 5)
        XCTAssertEqual(report.aps.alert.locKey, PushLocKey.dailyReportBody)
        XCTAssertEqual(report.aps.alert.locArgs, ["5"])
        XCTAssertEqual(report.pilgrim, PushPayload.Info(kind: .dailyReport))

        let decided = PushPayload.group(
            .voteDecided(newAdminName: "준호"), groupID: F.id(10), groupName: "수요 기도모임")
        XCTAssertEqual(decided.aps.alert.locKey, "ADMIN_VOTE_DECIDED")
        XCTAssertEqual(decided.aps.alert.locArgs, ["준호"])
        XCTAssertEqual(decided.pilgrim.kind, .voteDecided)

        let deletion = PushPayload.group(
            .deletionScheduled, groupID: F.id(10), groupName: "수요 기도모임")
        XCTAssertEqual(deletion.aps.alert.locKey, "GROUP_DELETION_SCHEDULED")
        XCTAssertEqual(deletion.aps.alert.locArgs, [])
        XCTAssertEqual(PushLocKey.newPost(.testimony), "GROUP_NEW_POST_TESTIMONY")
        XCTAssertEqual(Set(PushLocKey.all).count, 10)
    }

    func testAdminReports() {
        assertRoundTrip(F.adminReport, json: F.adminReportJSON)
        assertRoundTrip(F.snapshot, json: F.snapshotJSON)
        assertRoundTrip(
            AdminReportDetail(
                report: F.adminReport, liveTarget: AdminTarget(exists: true, post: F.post)),
            json: """
                {"liveTarget":{"exists":true,"post":\(F.postJSON)},"report":\(F.adminReportJSON)}
                """)
        assertRoundTrip(
            AdminTarget(exists: true, comment: F.comment, sticker: F.sticker),
            json: "{\"comment\":\(F.commentJSON),\"exists\":true,\"sticker\":\(F.stickerJSON)}")
        assertRoundTrip(
            ResolveReportRequest(resolution: .actioned, note: "삭제함"),
            json: "{\"note\":\"삭제함\",\"resolution\":\"actioned\"}")
        assertRoundTrip(
            SuspendUserRequest(reason: "spam", until: F.laterDate),
            json: "{\"reason\":\"spam\",\"until\":\"\(F.laterDateString)\"}")
    }

    func testAdminStatus() {
        assertRoundTrip(
            AdminStatusResponse(
                workers: [AdminWorkerStatus(name: "pushOutbox", lastBeatAt: F.date, healthy: true)],
                counts: AdminCounts(users: 3, groups: 1, posts: 4, openReports: 0, pendingPush: 2)
            ),
            json: """
                {"counts":{"groups":1,"openReports":0,"pendingPush":2,"posts":4,"users":3},\
                "workers":[{"healthy":true,"lastBeatAt":"\(F.dateString)","name":"pushOutbox"}]}
                """)
    }
}
#endif
