#if canImport(XCTest)
import Foundation
import JournalGroups
import PilgrimAPI
import XCTest

final class InviteLinkAndNonceTests: XCTestCase {
    private let code = "PREV1EW0C0DE"

    func testParsesLinksCodesAndLookAlikes() {
        let inputs = [
            "https://pilgrim.delight-house.org/i/PREV1EW0C0DE",
            "https://PILGRIM.delight-house.org/i/prev1ew0c0de/",
            "https://pilgrim.delight-house.org/i/PREV-1EW0-C0DE?utm=qr",
            "  pilgrim.delight-house.org/i/PREV1EW0C0DE \n",
            "PREV-1EW0-C0DE",
            "prev lew0 cOde",
        ]
        for input in inputs {
            XCTAssertEqual(InviteLink.code(from: input)?.rawValue, code, input)
        }
    }

    func testRejectsOtherHostsAndPaths() {
        let inputs = [
            "https://example.com/i/PREV1EW0C0DE",
            "https://pilgrim.delight-house.org/x/PREV1EW0C0DE",
            "https://pilgrim.delight-house.org/i/PREV1EW0C0DE/extra",
            "mailto:PREV1EW0C0DE",
            "PREV1EW0C0D",
            "",
        ]
        for input in inputs {
            XCTAssertNil(InviteLink.code(from: input), input)
        }
    }

    func testDevelopmentHostsAreOptIn() throws {
        let local = GroupServerConfiguration.localDevelopment(client: Fixture.client)
        let link = "http://localhost:3100/i/\(code)"
        XCTAssertNil(InviteLink.code(from: link))
        XCTAssertEqual(
            InviteLink.code(from: link, allowedHosts: InviteLink.allowedHosts(for: local))?
                .rawValue, code)
    }

    func testFormatsTheLink() throws {
        let invite = try XCTUnwrap(InviteCode(normalizing: code))
        XCTAssertEqual(
            InviteLink.url(for: invite).absoluteString,
            "https://pilgrim.delight-house.org/i/PREV1EW0C0DE")
        XCTAssertEqual(InviteLink.code(from: InviteLink.url(for: invite)), invite)
    }

    func testNonceIsRandomBase64URLAndHashesToLowercaseHex() {
        let first = AppleSignInNonce.generate()
        let second = AppleSignInNonce.generate()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.raw.count, 43, "32 bytes in unpadded base64url")
        XCTAssertTrue(
            first.raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_".contains($0)) }
        )
        XCTAssertEqual(
            AppleSignInNonce(raw: "abc").hashed,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(first.hashed.count, 64)
        XCTAssertEqual(first.hashed, first.hashed.lowercased())
    }
}
#endif
