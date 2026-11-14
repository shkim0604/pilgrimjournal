#if canImport(XCTest)
import Foundation
import PilgrimAPI
import XCTest

final class InviteCodeTests: XCTestCase {
    func testNormalizationIgnoresCaseDashesAndWhitespaceAndFoldsLookalikes() {
        XCTAssertEqual(InviteCode(normalizing: "7K3M9QX2P4HD")?.rawValue, "7K3M9QX2P4HD")
        XCTAssertEqual(InviteCode(normalizing: "7k3m-9qx2-p4hd")?.rawValue, "7K3M9QX2P4HD")
        XCTAssertEqual(InviteCode(normalizing: " 7K3M 9QX2\tP4HD\n")?.rawValue, "7K3M9QX2P4HD")
        XCTAssertEqual(InviteCode(normalizing: "IL0O-iloo-1234")?.rawValue, "110011001234")
    }

    func testInvalidCodesAreRejected() {
        XCTAssertNil(InviteCode(normalizing: ""))
        XCTAssertNil(InviteCode(normalizing: "7K3M9QX2P4H"), "11 characters")
        XCTAssertNil(InviteCode(normalizing: "7K3M9QX2P4HDA"), "13 characters")
        XCTAssertNil(InviteCode(normalizing: "7K3M9QX2P4HU"), "U is not Crockford base32")
        XCTAssertNil(InviteCode(normalizing: "7K3M9QX2P4H!"))
        XCTAssertNil(InviteCode(normalizing: "7K3M9QX2P4H한"))
    }

    func testGeneratedCodesUseTheAlphabet() {
        var rng = SplitMix64(state: 42)
        var codes = Set<InviteCode>()
        for _ in 0..<200 {
            let code = InviteCode.generate(using: &rng)
            XCTAssertEqual(code.rawValue.count, 12)
            XCTAssertTrue(code.rawValue.allSatisfy(InviteCode.alphabet.contains))
            codes.insert(code)
        }
        XCTAssertEqual(codes.count, 200)
        XCTAssertEqual(InviteCode.alphabet.count, 32)
    }

    func testGroupedFormAndLinksRoundTrip() throws {
        let code = try XCTUnwrap(InviteCode(normalizing: "7K3M9QX2P4HD"))
        XCTAssertEqual(code.grouped, "7K3M-9QX2-P4HD")
        XCTAssertEqual(InviteCode(normalizing: code.grouped), code)
        XCTAssertEqual(
            code.url().absoluteString, "https://pilgrim.delight-house.org/i/7K3M9QX2P4HD")
        XCTAssertEqual(InviteCode(url: code.url()), code)
        XCTAssertEqual(
            InviteCode(url: URL(string: "https://pilgrim.delight-house.org/i/7k3m-9qx2-p4hd")!),
            code)
        XCTAssertNil(InviteCode(url: URL(string: "https://pilgrim.delight-house.org/admin")!))
        XCTAssertNil(InviteCode(url: URL(string: "https://pilgrim.delight-house.org/i/x/y")!))
        let data = try PilgrimJSON.encode([code])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"7K3M9QX2P4HD\"]")
        XCTAssertEqual(
            try PilgrimJSON.decode([InviteCode].self, from: Data("[\"7k3m-9qx2-p4hd\"]".utf8)),
            [code])
    }
}

final class PhotoLimitsTests: XCTestCase {
    private func check(_ purpose: MediaPurpose, _ width: Int, _ height: Int, _ bytes: Int)
        -> PhotoLimitViolation?
    {
        do {
            try PhotoLimits.validate(
                purpose: purpose, width: width, height: height, byteCount: bytes)
            return nil
        } catch {
            return error
        }
    }

    func testPhotosUpTo1600PixelsAnd500KB() {
        for purpose in [MediaPurpose.post, .comment, .profile] {
            XCTAssertNil(check(purpose, 1600, 1200, 500 * 1024))
            XCTAssertNil(check(purpose, 900, 1600, 1))
            XCTAssertEqual(check(purpose, 1601, 1200, 1000), .invalidDimensions)
            XCTAssertEqual(check(purpose, 1200, 1601, 1000), .invalidDimensions)
            XCTAssertEqual(check(purpose, 1600, 1200, 500 * 1024 + 1), .tooLarge(limit: 512_000))
        }
        XCTAssertEqual(check(.post, 0, 100, 1), .invalidDimensions)
    }

    func testStickersAreExactly256SquareAndAtMost100KB() {
        XCTAssertNil(check(.sticker, 256, 256, 100 * 1024))
        XCTAssertEqual(check(.sticker, 255, 256, 1000), .invalidDimensions)
        XCTAssertEqual(check(.sticker, 512, 512, 1000), .invalidDimensions)
        XCTAssertEqual(check(.sticker, 256, 256, 100 * 1024 + 1), .tooLarge(limit: 102_400))
    }

    func testViolationCodesAndSignature() {
        XCTAssertEqual(PhotoLimitViolation.tooLarge(limit: 1).code, .mediaTooLarge)
        XCTAssertEqual(PhotoLimitViolation.invalidDimensions.code, .mediaInvalid)
        XCTAssertTrue(PhotoLimits.hasJPEGSignature([0xFF, 0xD8, 0xFF, 0xE0, 0x00]))
        XCTAssertFalse(PhotoLimits.hasJPEGSignature([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertFalse(PhotoLimits.hasJPEGSignature([0xFF, 0xD8]))
        XCTAssertEqual(PhotoLimits.maxPerPost, 4)
        XCTAssertEqual(PhotoLimits.maxPerComment, 4)
    }
}

final class ClientHeaderTests: XCTestCase {
    func testParsesTheDesignExample() throws {
        let header = try XCTUnwrap(ClientHeader("ios/1.3.0 (31) com.dhouse.PilgrimJournal"))
        XCTAssertEqual(header.platform, .ios)
        XCTAssertEqual(header.version, ClientVersion("1.3.0"))
        XCTAssertEqual(header.build, "31")
        XCTAssertEqual(header.bundleID, BundleIDs.release)
        XCTAssertTrue(header.isKnownBundle)
        XCTAssertEqual(header.description, "ios/1.3.0 (31) com.dhouse.PilgrimJournal")
        XCTAssertEqual(ClientHeader.name, "X-Pilgrim-Client")
        XCTAssertEqual(PilgrimHeader.client, "X-Pilgrim-Client")
    }

    func testMalformedHeadersAreRejected() {
        for value in [
            "", "ios/1.3.0 com.dhouse.PilgrimJournal",
            "android/1.3.0 (31) com.dhouse.PilgrimJournal",
            "ios/1.x (31) com.dhouse.PilgrimJournal", "ios/1.3.0 (31)", "ios/1.3.0 () b",
            "ios/1.3.0  (31) com.dhouse.PilgrimJournal", "ios 1.3.0 (31) com.dhouse.PilgrimJournal",
        ] {
            XCTAssertNil(ClientHeader(value), value)
        }
    }

    func testUnknownBundleParsesButIsNotKnown() throws {
        let header = try XCTUnwrap(ClientHeader("macos/1.3.0 (31) com.example.Other"))
        XCTAssertEqual(header.platform, .macos)
        XCTAssertFalse(header.isKnownBundle)
    }

    func testVersionsCompareNumerically() {
        // specs/group-server: MIN_CLIENT_VERSION=1.3.0 blocks 1.2.9.
        XCTAssertLessThan(ClientVersion("1.2.9")!, ClientVersion("1.3.0")!)
        XCTAssertLessThan(ClientVersion("1.9")!, ClientVersion("1.10")!)
        XCTAssertEqual(ClientVersion("1.3")!, ClientVersion("1.3.0")!)
        XCTAssertEqual(Set([ClientVersion("1.3")!, ClientVersion("1.3.0")!]).count, 1)
        XCTAssertFalse(ClientVersion("1.3.0")! < ClientVersion("1.3")!)
        XCTAssertNil(ClientVersion("1..3"))
        XCTAssertNil(ClientVersion("v1.3"))
    }
}

final class LocalDateTests: XCTestCase {
    func testParsingAndFormatting() throws {
        let date = try XCTUnwrap(LocalDate("2026-11-20"))
        XCTAssertEqual([date.year, date.month, date.day], [2026, 11, 20])
        XCTAssertEqual(date.description, "2026-11-20")
        XCTAssertEqual(LocalDate("2028-02-29")?.description, "2028-02-29")
        for bad in [
            "2026-02-29", "2026-13-01", "2026-11-31", "26-11-20", "2026-1-20", "2026/11/20",
        ] {
            XCTAssertNil(LocalDate(bad), bad)
        }
        XCTAssertThrowsError(
            try PilgrimJSON.decode(LocalDate.self, from: Data("\"2026-1-2\"".utf8)))
    }

    func testCalendarArithmetic() {
        let date = LocalDate("2026-12-30")!
        XCTAssertEqual(date.adding(days: 4).description, "2027-01-03")
        XCTAssertEqual(LocalDate("2028-02-28")!.adding(days: 1).description, "2028-02-29")
        XCTAssertEqual(LocalDate("2026-03-01")!.adding(days: -1).description, "2026-02-28")
        XCTAssertEqual(LocalDate("2026-11-14")!.days(until: LocalDate("2027-11-14")!), 365)
        XCTAssertLessThan(LocalDate("2026-11-14")!, LocalDate("2026-11-15")!)
    }

    func testTheSameInstantIsADifferentDateInDifferentZones() {
        let instant = PilgrimDateFormat.date(from: "2026-11-14T16:00:00Z")!
        XCTAssertEqual(
            LocalDate(instant, in: TimeZone(identifier: "Asia/Seoul")!).description, "2026-11-15")
        XCTAssertEqual(
            LocalDate(instant, in: TimeZone(identifier: "America/New_York")!).description,
            "2026-11-14")
    }

    func testLocalTime() throws {
        XCTAssertEqual(LocalTime("22:00"), LocalTime.defaultDailyReport)
        XCTAssertEqual(LocalTime.defaultDailyReport.minutesSinceMidnight, 1320)
        XCTAssertEqual(LocalTime(minutesSinceMidnight: 450)?.description, "07:30")
        XCTAssertNil(LocalTime("24:00"))
        XCTAssertNil(LocalTime("7:30"))
        XCTAssertNil(LocalTime(minutesSinceMidnight: 1440))
        let data = try PilgrimJSON.encode([LocalTime(hour: 9, minute: 5)!])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "[\"09:05\"]")
    }
}

final class APILimitsTests: XCTestCase {
    func testReactionEmoji() {
        for emoji in ["🙏", "❤️", "👍🏽", "👨‍👩‍👧", "🇰🇷"] {
            XCTAssertTrue(APILimits.isReactionEmoji(emoji), emoji)
        }
        for text in ["a", "1", "#", "🙏🙏", "", "아멘", "♥"] {
            XCTAssertFalse(APILimits.isReactionEmoji(text), text)
        }
    }

    func testNames() {
        XCTAssertTrue(APILimits.isValidGroupName("수요 기도모임"))
        XCTAssertTrue(APILimits.isValidGroupName(String(repeating: "가", count: 40)))
        XCTAssertFalse(APILimits.isValidGroupName(String(repeating: "가", count: 41)))
        XCTAssertFalse(APILimits.isValidGroupName("두 줄\n이름"))
        XCTAssertFalse(APILimits.isValidGroupName("   "))
        XCTAssertTrue(APILimits.isValidDisplayName("민지"))
        XCTAssertFalse(APILimits.isValidDisplayName(""))
        XCTAssertFalse(APILimits.isValidDisplayName(String(repeating: "a", count: 31)))
    }
}
#endif
