#if canImport(XCTest)
import CryptoKit
import Foundation
import JournalDomain
import XCTest

final class ContentHashTests: XCTestCase {
    // FIPS 180-2 test vector for "abc".
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    func testSHA256HexOfDataIsLowercaseHex() {
        XCTAssertEqual(ContentHash.sha256Hex(Data("abc".utf8)), abcDigest)
    }

    func testSHA256HexOfStringHashesItsUTF8Bytes() {
        XCTAssertEqual(ContentHash.sha256Hex("abc"), abcDigest)
    }

    func testHexFormatsAStreamedDigest() {
        var hasher = SHA256()
        hasher.update(data: Data("a".utf8))
        hasher.update(data: Data("bc".utf8))
        XCTAssertEqual(ContentHash.hex(hasher.finalize()), abcDigest)
    }
}
#endif
