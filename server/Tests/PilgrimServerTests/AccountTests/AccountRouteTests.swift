import Fluent
import Foundation
import PilgrimAPI
import Vapor
import XCTVapor
import XCTest

@testable import PilgrimServerCore

/// `GET/PATCH /me`, devices and the account gate against Postgres.
final class AccountRouteTests: DatabaseTestCase {
    override func setUp() async throws {
        try await super.setUp()
        app.pilgrimRoutes.signedUp.get("test", "gated") { req in
            try await req.currentUser().displayName ?? ""
        }
    }

    private func patchMe(_ body: UpdateMeRequest, as user: User) async throws -> (
        HTTPStatus, MeResponse?, APIError?
    ) {
        var result: (HTTPStatus, MeResponse?, APIError?) = (.internalServerError, nil, nil)
        try await app.test(
            .PATCH, "api/v1/me", headers: try headers(as: user),
            beforeRequest: { req in try req.content.encode(body, as: .json) }
        ) { res async throws in
            if res.status == .ok {
                result = (res.status, try decode(MeResponse.self, from: res), nil)
            } else {
                result = (res.status, nil, try errorBody(res))
            }
        }
        return result
    }

    private func suspend(_ user: User, until: Date? = nil) async throws {
        user.suspendedAt = Date()
        user.suspendedUntil = until
        try await user.save(on: db)
    }

    // MARK: - Gate

    func testGateRequiresSignupAndRefusesSuspended() async throws {
        let fresh = try await fixtures.user(nil)
        try await app.test(.GET, "api/v1/test/gated", headers: try headers(as: fresh)) {
            res async throws in
            XCTAssertEqual(res.status, .forbidden)
            XCTAssertEqual(try errorBody(res).code, .signupRequired)
        }

        let member = try await fixtures.user("멤버")
        try await app.test(.GET, "api/v1/test/gated", headers: try headers(as: member)) {
            res async throws in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "멤버")
        }

        try await suspend(member)
        try await app.test(.GET, "api/v1/test/gated", headers: try headers(as: member)) {
            res async throws in
            XCTAssertEqual(res.status, .forbidden)
            XCTAssertEqual(try errorBody(res).code, .accountSuspended)
        }

        // An expired suspension no longer blocks.
        try await suspend(member, until: Date().addingTimeInterval(-60))
        try await app.test(.GET, "api/v1/test/gated", headers: try headers(as: member)) {
            res async throws in
            XCTAssertEqual(res.status, .ok)
        }
    }

    func testDeletedAccountIs401() async throws {
        let ghost = User(appleSub: "dev:ghost", displayName: "유령")
        ghost.id = UUID()
        try await app.test(.GET, "api/v1/me", headers: try headers(as: ghost)) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
        try await app.test(.GET, "api/v1/test/gated", headers: try headers(as: ghost)) {
            res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    // MARK: - GET /me

    func testGetMeBeforeSignupAndWhileSuspended() async throws {
        let user = try await fixtures.user(nil)
        try await app.test(.GET, "api/v1/me", headers: try headers(as: user)) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let me = try decode(MeResponse.self, from: res)
            XCTAssertFalse(me.profileComplete)
            XCTAssertEqual(me.timeZone, "Asia/Seoul")
            XCTAssertEqual(me.dailyReportTime, .defaultDailyReport)
            XCTAssertNil(me.suspendedUntil)
        }
        let until = Date().addingTimeInterval(86_400)
        try await suspend(user, until: until)
        try await app.test(.GET, "api/v1/me", headers: try headers(as: user)) { res async throws in
            XCTAssertEqual(res.status, .ok)
            let me = try decode(MeResponse.self, from: res)
            XCTAssertEqual(
                try XCTUnwrap(me.suspendedUntil).timeIntervalSince1970,
                until.timeIntervalSince1970, accuracy: 1)
        }
    }

    // MARK: - PATCH /me

    func testSignupStoresTrimmedNameAndSettings() async throws {
        let user = try await fixtures.user(nil)
        let (status, me, _) = try await patchMe(
            UpdateMeRequest(
                displayName: "  김순례  ", timeZone: "America/New_York", dailyReportEnabled: false,
                dailyReportTime: LocalTime(hour: 7, minute: 30)),
            as: user)
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(me?.displayName, "김순례")
        XCTAssertEqual(me?.profileComplete, true)
        XCTAssertEqual(me?.timeZone, "America/New_York")
        XCTAssertEqual(me?.dailyReportEnabled, false)
        let stored = try await unwrapAsync(try await User.find(user.id, on: db))
        XCTAssertEqual(stored.dailyReportMinute, 7 * 60 + 30)
    }

    func testDisplayNameRules() async throws {
        let user = try await fixtures.user(nil)
        let tooLong = try await patchMe(
            UpdateMeRequest(displayName: String(repeating: "가", count: 31)), as: user)
        XCTAssertEqual(tooLong.2?.code, .limitExceeded)
        XCTAssertEqual(tooLong.2?.limit, 30)
        for bad in ["", "   ", "첫줄\n둘째줄"] {
            let result = try await patchMe(UpdateMeRequest(displayName: bad), as: user)
            XCTAssertEqual(result.2?.code, .validationFailed, bad)
        }
        let thirty = try await patchMe(
            UpdateMeRequest(displayName: String(repeating: "가", count: 30)), as: user)
        XCTAssertEqual(thirty.0, .ok)
    }

    func testUnknownTimeZoneIs422() async throws {
        let user = try await fixtures.user()
        let result = try await patchMe(UpdateMeRequest(timeZone: "Mars/Olympus"), as: user)
        XCTAssertEqual(result.2?.code, .validationFailed)
        XCTAssertEqual(result.2?.field, "timeZone")
        let utc = try await patchMe(UpdateMeRequest(timeZone: "UTC"), as: user)
        XCTAssertEqual(utc.0, .ok)
    }

    func testSuspendedUserCannotEditProfile() async throws {
        let user = try await fixtures.user()
        try await suspend(user)
        let result = try await patchMe(UpdateMeRequest(displayName: "새 이름"), as: user)
        XCTAssertEqual(result.0, .forbidden)
        XCTAssertEqual(result.2?.code, .accountSuspended)
    }

    func testProfilePhotoAttachReplaceAndRemove() async throws {
        let user = try await fixtures.user()
        let first = try await fixtures.media(uploadedBy: user, in: nil, purpose: .profile)
        let attached = try await patchMe(UpdateMeRequest(profilePhotoId: first.id), as: user)
        XCTAssertEqual(attached.0, .ok)
        XCTAssertEqual(attached.1?.profilePhoto?.id, first.id)
        XCTAssertEqual(attached.1?.profilePhoto?.width, 800)
        let firstRow = try await unwrapAsync(try await Media.find(first.id, on: db))
        XCTAssertNotNil(firstRow.attachedAt)

        let second = try await fixtures.media(uploadedBy: user, in: nil, purpose: .profile)
        let replaced = try await patchMe(UpdateMeRequest(profilePhotoId: second.id), as: user)
        XCTAssertEqual(replaced.1?.profilePhoto?.id, second.id)
        let firstGone = try await Media.find(first.id, on: db)
        XCTAssertNil(firstGone)

        let removed = try await patchMe(UpdateMeRequest(removeProfilePhoto: true), as: user)
        XCTAssertEqual(removed.0, .ok)
        XCTAssertNil(removed.1?.profilePhoto)
        let secondGone = try await Media.find(second.id, on: db)
        XCTAssertNil(secondGone)
    }

    func testProfilePhotoMustBeOwnUnattachedProfileUpload() async throws {
        let user = try await fixtures.user()
        let other = try await fixtures.user("남")
        let group = try await fixtures.group(admin: user)
        let othersPhoto = try await fixtures.media(uploadedBy: other, in: nil, purpose: .profile)
        let postPhoto = try await fixtures.media(uploadedBy: user, in: group, purpose: .post)

        let notMine = try await patchMe(UpdateMeRequest(profilePhotoId: othersPhoto.id), as: user)
        XCTAssertEqual(notMine.2?.code, .notFound)
        let missing = try await patchMe(UpdateMeRequest(profilePhotoId: UUID()), as: user)
        XCTAssertEqual(missing.2?.code, .notFound)
        let wrongPurpose = try await patchMe(
            UpdateMeRequest(profilePhotoId: postPhoto.id), as: user)
        XCTAssertEqual(wrongPurpose.2?.code, .mediaNotAttachable)
        let both = try await patchMe(
            UpdateMeRequest(profilePhotoId: othersPhoto.id, removeProfilePhoto: true), as: user)
        XCTAssertEqual(both.2?.code, .validationFailed)
    }

    // MARK: - Devices

    private func putDevice(
        _ installation: UUID, token: String?, as user: User
    ) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.test(
            .PUT, "api/v1/me/devices/\(installation.uuidString)", headers: try headers(as: user),
            beforeRequest: { req in
                try req.content.encode(
                    DeviceRegistrationRequest(
                        apnsToken: token, apnsEnvironment: .sandbox, bundleId: BundleIDs.debug,
                        platform: .ios, locale: "ko-KR", timeZone: "Asia/Seoul",
                        appVersion: "1.3.0"),
                    as: .json)
            }
        ) { res async throws in status = res.status }
        return status
    }

    func testDeviceRegistrationUpsertsAndMovesTokens() async throws {
        let alice = try await fixtures.user("앨리스")
        let bob = try await fixtures.user("밥")
        let phone = UUID()
        let tablet = UUID()

        let first = try await putDevice(phone, token: "ABCDEF01", as: alice)
        XCTAssertEqual(first, .noContent)
        let updated = try await putDevice(phone, token: "abcdef02", as: alice)
        XCTAssertEqual(updated, .noContent)
        var rows = try await Device.query(on: db).all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.apnsToken, "abcdef02")
        XCTAssertEqual(rows.first?.bundleID, BundleIDs.debug)

        // The same APNs token on a new installation clears it from the old row.
        _ = try await putDevice(tablet, token: "abcdef02", as: alice)
        let phoneRow = try await Device.query(on: db).filter(\.$installationID == phone).first()
        XCTAssertNil(phoneRow?.apnsToken)

        // Bob signs in on Alice's old phone: the row moves to him.
        _ = try await putDevice(phone, token: "abcdef03", as: bob)
        rows = try await Device.query(on: db).filter(\.$installationID == phone).all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.$user.id, bob.id)
    }

    func testDeviceValidationAndDelete() async throws {
        let user = try await fixtures.user()
        let installation = UUID()
        let badToken = try await putDevice(installation, token: "not-hex!", as: user)
        XCTAssertEqual(badToken, .unprocessableEntity)
        let noToken = try await putDevice(installation, token: nil, as: user)
        XCTAssertEqual(noToken, .noContent)

        let other = try await fixtures.user("남")
        try await app.test(
            .DELETE, "api/v1/me/devices/\(installation.uuidString)", headers: try headers(as: other)
        ) { res async throws in XCTAssertEqual(res.status, .noContent) }
        var count = try await Device.query(on: db).count()
        XCTAssertEqual(count, 1, "another user cannot delete the row")

        try await app.test(
            .DELETE, "api/v1/me/devices/\(installation.uuidString)", headers: try headers(as: user)
        ) { res async throws in XCTAssertEqual(res.status, .noContent) }
        count = try await Device.query(on: db).count()
        XCTAssertEqual(count, 0)
    }
}

/// `UpdateMeRequest` validation without a database.
final class UpdateMeValidationTests: XCTestCase {
    func testValidation() throws {
        XCTAssertThrowsError(
            try AccountRoutes.validate(
                UpdateMeRequest(profilePhotoId: UUID(), removeProfilePhoto: true)))
        XCTAssertEqual(
            try AccountRoutes.validate(UpdateMeRequest(displayName: " 이름 ")).displayName, "이름")
        XCTAssertThrowsError(try AccountRoutes.validate(UpdateMeRequest(displayName: "a\nb"))) {
            XCTAssertEqual(($0 as? APIError)?.code, .validationFailed)
        }
        XCTAssertThrowsError(
            try AccountRoutes.validate(
                UpdateMeRequest(displayName: String(repeating: "x", count: 31)))
        ) { XCTAssertEqual(($0 as? APIError)?.code, .limitExceeded) }
        XCTAssertNoThrow(try AccountRoutes.validate(UpdateMeRequest(timeZone: "Asia/Seoul")))
        XCTAssertThrowsError(try AccountRoutes.validate(UpdateMeRequest(timeZone: "Nowhere/City")))
    }

    func testAPNsTokenNormalization() throws {
        XCTAssertEqual(try AccountRoutes.normalizedAPNsToken("ABCDEF0123"), "abcdef0123")
        XCTAssertNil(try AccountRoutes.normalizedAPNsToken(nil))
        for bad in ["xyz12345", "abc", "abcdef0", "ab cd ef 01"] {
            XCTAssertThrowsError(try AccountRoutes.normalizedAPNsToken(bad), bad)
        }
    }
}
