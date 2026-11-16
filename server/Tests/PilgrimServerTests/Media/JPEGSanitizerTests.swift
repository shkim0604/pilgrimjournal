import Foundation
import XCTest

@testable import PilgrimServerCore

/// `JPEGSanitizer`: structure checks, SOF size and metadata removal (design.md 7절).
final class JPEGSanitizerTests: XCTestCase {
    private func sanitize(_ bytes: [UInt8]) throws -> SanitizedJPEG {
        try JPEGSanitizer.sanitize(Data(bytes))
    }

    private func expectFailure(
        _ bytes: [UInt8], _ expected: JPEGStructureError, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let result = try JPEGSanitizer.sanitize(Data(bytes))
            XCTFail("accepted \(result.width)x\(result.height)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }

    // MARK: - Metadata removal

    func testDropsMetadataAndKeepsImageSegments() throws {
        let result = try JPEGSanitizer.sanitize(TestJPEG.make(metadata: true))
        XCTAssertEqual(result.data, TestJPEG.stripped())
        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(result.height, 600)
    }

    func testNoMetadataTextSurvives() throws {
        let result = try JPEGSanitizer.sanitize(TestJPEG.make(metadata: true))
        let text = String(decoding: result.data, as: UTF8.self)
        for needle in ["GPS", "Exif", "xmpmeta", "MPF", "8BIM", "Shot on", "TRAILER", "vendor"] {
            XCTAssertFalse(text.contains(needle), needle)
        }
        XCTAssertTrue(text.contains("JFIF"))
        XCTAssertTrue(text.contains("ICC_PROFILE"))
    }

    func testCleanFileIsUnchangedAndSanitizingIsIdempotent() throws {
        let clean = TestJPEG.make(width: 256, height: 256)
        XCTAssertEqual(try JPEGSanitizer.sanitize(clean).data, clean)
        let once = try JPEGSanitizer.sanitize(TestJPEG.make(metadata: true)).data
        XCTAssertEqual(try JPEGSanitizer.sanitize(once).data, once)
    }

    func testEntropyCodedDataIsCopiedByteForByte() throws {
        // Stuffed FF 00, RSTn and bytes that look like markers only when unstuffed.
        let scan: [UInt8] = [0xFF, 0x00, 0xFF, 0xD7, 0xE1, 0xFE, 0x00, 0xFF, 0x00, 0xFF, 0xD3]
        let bytes =
            TestJPEG.soi + TestJPEG.dqt + TestJPEG.sof(width: 10, height: 20) + TestJPEG.dht
            + TestJPEG.sos + scan + TestJPEG.eoi
        XCTAssertEqual(try sanitize(bytes).data, Data(bytes))
    }

    func testMetadataBetweenProgressiveScansIsDropped() throws {
        let head =
            TestJPEG.soi + TestJPEG.jfif + TestJPEG.dqt
            + TestJPEG.sof(0xC2, width: 1_600, height: 900)
        let scans =
            TestJPEG.dht + TestJPEG.sos + TestJPEG.scanData + TestJPEG.dht + TestJPEG.sos
            + TestJPEG.scanData
        let withMetadata =
            head + TestJPEG.dht + TestJPEG.sos + TestJPEG.scanData + TestJPEG.exifWithGPS
            + TestJPEG.comment + TestJPEG.dht + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi
        let result = try sanitize(withMetadata)
        XCTAssertEqual(result.data, Data(head + scans + TestJPEG.eoi))
        XCTAssertEqual(result.width, 1_600)
        XCTAssertEqual(result.height, 900)
    }

    func testFillBytesBeforeMarkersAreDropped() throws {
        let plain =
            TestJPEG.soi + TestJPEG.dqt + TestJPEG.sof(width: 3, height: 4) + TestJPEG.dht
            + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi
        let fill: [UInt8] = [0xFF, 0xFF]
        let filled: [UInt8] =
            TestJPEG.soi + fill + TestJPEG.dqt + TestJPEG.sof(width: 3, height: 4)
            + TestJPEG.dht + TestJPEG.sos + TestJPEG.scanData + fill + TestJPEG.eoi
        XCTAssertEqual(try sanitize(filled).data, Data(plain))
    }

    func testOnlyTheICCProfileAPP2Stays() throws {
        let bytes =
            TestJPEG.soi + TestJPEG.icc + TestJPEG.mpf + TestJPEG.dqt
            + TestJPEG.sof(width: 1, height: 1) + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi
        let expected =
            TestJPEG.soi + TestJPEG.icc + TestJPEG.dqt + TestJPEG.sof(width: 1, height: 1)
            + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi
        XCTAssertEqual(try sanitize(bytes).data, Data(expected))
    }

    func testMarkerClassification() {
        for marker in UInt8(0xE1)...UInt8(0xEF) where marker != 0xE2 {
            XCTAssertTrue(JPEGSanitizer.isMetadata(marker: marker, payload: []), "\(marker)")
        }
        XCTAssertTrue(JPEGSanitizer.isMetadata(marker: 0xFE, payload: []))
        XCTAssertTrue(JPEGSanitizer.isMetadata(marker: 0xE2, payload: ArraySlice("MPF\0".utf8)))
        XCTAssertFalse(
            JPEGSanitizer.isMetadata(marker: 0xE2, payload: ArraySlice("ICC_PROFILE\0\u{1}".utf8)))
        for kept: UInt8 in [0xE0, 0xDB, 0xC4, 0xC0, 0xDD] {
            XCTAssertFalse(JPEGSanitizer.isMetadata(marker: kept, payload: []), "\(kept)")
        }

        let frames: [UInt8] = [
            0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
        ]
        for marker in frames { XCTAssertTrue(JPEGSanitizer.isFrameHeader(marker), "\(marker)") }
        for marker: UInt8 in [0xC4, 0xC8, 0xCC, 0xDA, 0xDB, 0xE0] {
            XCTAssertFalse(JPEGSanitizer.isFrameHeader(marker), "\(marker)")
        }
    }

    // MARK: - SOF size

    func testReadsTheSizeFromEveryFrameKind() throws {
        for marker: UInt8 in [0xC0, 0xC1, 0xC2, 0xC9] {
            let bytes =
                TestJPEG.soi + TestJPEG.dqt + TestJPEG.sof(marker, width: 1_234, height: 300)
                + TestJPEG.dht + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi
            let result = try sanitize(bytes)
            XCTAssertEqual(result.width, 1_234, "\(marker)")
            XCTAssertEqual(result.height, 300, "\(marker)")
        }
        let large =
            TestJPEG.soi + TestJPEG.sof(width: 65_535, height: 258) + TestJPEG.sos
            + TestJPEG.scanData + TestJPEG.eoi
        XCTAssertEqual(try sanitize(large).width, 65_535)
        XCTAssertEqual(try sanitize(large).height, 258)
    }

    // MARK: - Refused structures

    func testRefusesFilesThatAreNotJPEG() {
        expectFailure([], .notJPEG)
        expectFailure([0xFF, 0xD8], .notJPEG)
        expectFailure([0xFF, 0xD8, 0x00, 0x00], .notJPEG)
        expectFailure([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], .notJPEG)
        expectFailure(Array("GIF89a".utf8), .notJPEG)
    }

    func testRefusesTruncatedFiles() {
        let full = [UInt8](TestJPEG.make())
        // No EOI: ends inside the scan.
        expectFailure(Array(full.dropLast(2)), .truncated)
        // Ends inside a segment, at its length, right after a marker, on a lone FF in the scan.
        expectFailure(TestJPEG.soi + Array(TestJPEG.dqt.prefix(10)), .truncated)
        expectFailure(TestJPEG.soi + [0xFF, 0xDB, 0x00], .truncated)
        expectFailure(TestJPEG.soi + [0xFF, 0xFF], .truncated)
        expectFailure(
            TestJPEG.soi + TestJPEG.sof(width: 1, height: 1) + TestJPEG.sos + [0x12, 0xFF],
            .truncated)
        expectFailure(TestJPEG.soi + TestJPEG.jfif, .truncated)
    }

    func testRefusesMalformedSegments() {
        let tail =
            TestJPEG.sof(width: 1, height: 1) + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi
        // A byte that is not FF where a marker belongs.
        expectFailure(TestJPEG.soi + TestJPEG.jfif + [0x00] + tail, .malformedSegment)
        // A length below 2.
        expectFailure(TestJPEG.soi + [0xFF, 0xE1, 0x00, 0x01] + tail, .malformedSegment)
        // A second SOI and a stuffing marker outside a scan.
        expectFailure(TestJPEG.soi + TestJPEG.soi + tail, .malformedSegment)
        expectFailure(TestJPEG.soi + [0xFF, 0x00] + tail, .malformedSegment)
    }

    func testRefusesMissingOrBrokenFrames() {
        // Scan before any frame header.
        expectFailure(
            TestJPEG.soi + TestJPEG.dqt + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi,
            .invalidFrame)
        // Two frame headers.
        expectFailure(
            TestJPEG.soi + TestJPEG.sof(width: 1, height: 1) + TestJPEG.sof(width: 2, height: 2)
                + TestJPEG.sos + TestJPEG.scanData + TestJPEG.eoi,
            .invalidFrame)
        // A frame header too short to hold the size.
        expectFailure(
            TestJPEG.soi + TestJPEG.segment(0xC0, [8, 0, 1, 0]) + TestJPEG.sos + TestJPEG.scanData
                + TestJPEG.eoi,
            .invalidFrame)
    }

    func testRefusesFilesWithoutImageData() {
        expectFailure(TestJPEG.soi + TestJPEG.jfif + TestJPEG.eoi, .missingScan)
        expectFailure(
            TestJPEG.soi + TestJPEG.sof(width: 8, height: 8) + TestJPEG.dqt + TestJPEG.eoi,
            .missingScan)
    }
}
