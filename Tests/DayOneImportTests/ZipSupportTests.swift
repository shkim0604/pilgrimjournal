#if canImport(XCTest)
import DayOneImport
import Foundation
import JournalDomain
import XCTest

final class ZipSupportTests: XCTestCase {
    func testCRC32MatchesTheStandardCheckValue() {
        // The CRC-32/ISO-HDLC check value for the ASCII digits "123456789".
        XCTAssertEqual(ZipChecksum.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testCRC32OfEmptyDataIsZero() {
        XCTAssertEqual(ZipChecksum.crc32(Data()), 0)
    }

    func testAppendLEWritesLeastSignificantByteFirst() {
        var data = Data()
        data.appendLE(UInt32(0x0403_4B50))
        data.appendLE(UInt16(0x0800))
        XCTAssertEqual([UInt8](data), [0x50, 0x4B, 0x03, 0x04, 0x00, 0x08])
    }

    func testStoredZipWriterOutputIsReadableBySafeZipArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "stored.zip")

        let writer = try StoredZipWriter(url: url)
        try writer.add(name: "a.json", data: Data("{}".utf8))
        try writer.add(name: "폴더/b.txt", data: Data("본문".utf8))
        try writer.finish()

        let archive = try SafeZipArchive(url: url)
        XCTAssertEqual(archive.entries.map(\.rawName), ["a.json", "폴더/b.txt"])
        let second = try XCTUnwrap(archive.entries.last)
        XCTAssertEqual(try archive.data(for: second), Data("본문".utf8))
    }
}
#endif
