#!/usr/bin/env swift
// Builds an anonymized, structurally-realistic Day One export ZIP for manual
// device testing (docs/device-verification.md session C-1). No real personal
// data — every entry, tag, and photo here is synthetic. Mirrors the same ZIP
// writer used by Tests/DayOneImportTests/TestZipFactory.swift so the output
// parses through the real DayOneArchiveAnalyzer/DayOneImportExecutor path.
//
// Usage: swift scripts/make_anonymous_dayone_export.swift [output-path]
// Default output: ./anonymous-dayone-export.zip

import Foundation
import zlib

// MARK: - Synthetic content

// A minimal valid 1x1 white JPEG so the attachment actually previews instead
// of showing a broken-image placeholder.
let onePixelJPEGBase64 = """
/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0a\
HBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIy\
MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIA\
AhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEB\
AQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIRAxEAPwCdABmX\
/9k=
"""

struct SyntheticEntry {
    var uuid: String
    var text: String
    var creationDate: String
    var timeZone: String
    var tags: [String]
    var photoFilename: String?
}

// Fresh UUIDs on every run — Day One import tracks sourceUUID permanently
// (even through trash, since there's no "empty trash" feature yet), so
// reusing fixed UUIDs across test runs makes every re-import look like a
// duplicate of already-trashed entries.
func makeUUID(_ label: String) -> String { UUID().uuidString }

let entries: [SyntheticEntry] = [
    SyntheticEntry(
        uuid: makeUUID("0001"),
        text: "오늘 하루를 돌아보며 감사한 일들을 적어본다. 익명 합성 기록입니다.",
        creationDate: "2026-01-05T09:00:00+09:00",
        timeZone: "Asia/Seoul",
        tags: ["일기"],
        photoFilename: nil
    ),
    SyntheticEntry(
        uuid: makeUUID("0002"),
        text: "가족과 이웃을 위해 기도합니다. 익명 합성 기록입니다.",
        creationDate: "2026-01-06T21:30:00+09:00",
        timeZone: "Asia/Seoul",
        tags: ["기도"],
        photoFilename: nil
    ),
    SyntheticEntry(
        uuid: makeUUID("0003"),
        text: "오늘 읽은 본문에서 깨달은 점을 정리한다. 익명 합성 기록입니다.",
        creationDate: "2026-01-07T07:15:00+09:00",
        timeZone: "Asia/Seoul",
        tags: ["성경공부"],
        photoFilename: nil
    ),
    SyntheticEntry(
        uuid: makeUUID("0004"),
        text: "최근 읽은 책에서 인상 깊었던 구절을 옮겨 적는다. 익명 합성 기록입니다.",
        creationDate: "2026-01-08T20:00:00+09:00",
        timeZone: "Asia/Seoul",
        tags: ["독서"],
        photoFilename: nil
    ),
    SyntheticEntry(
        uuid: makeUUID("0005"),
        text: "여행 중 찍은 사진과 함께 남기는 기록. 다른 시간대에서 작성됨. 익명 합성 기록입니다.",
        creationDate: "2026-01-10T14:45:00-08:00",
        timeZone: "America/Los_Angeles",
        tags: ["여행", "사진", "일기"],
        photoFilename: "photo.jpg"
    ),
    SyntheticEntry(
        uuid: makeUUID("0006"),
        text: "선택 필드가 거의 없는 최소 기록.",
        creationDate: "2026-01-11T12:00:00+09:00",
        timeZone: "Asia/Seoul",
        tags: [],
        photoFilename: nil
    ),
]

// MARK: - JSON assembly

var jsonEntries: [[String: Any]] = []
for entry in entries {
    var dict: [String: Any] = [
        "uuid": entry.uuid,
        "text": entry.text,
        "creationDate": entry.creationDate,
        "timeZone": entry.timeZone,
    ]
    if !entry.tags.isEmpty { dict["tags"] = entry.tags }
    if let photoFilename = entry.photoFilename {
        dict["photos"] = [["filename": photoFilename, "type": "jpeg"]]
    }
    jsonEntries.append(dict)
}

let root: [String: Any] = [
    "metadata": ["version": "1.0"],
    "entries": jsonEntries,
]

let jsonData = try! JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
let photoData = Data(base64Encoded: onePixelJPEGBase64.replacingOccurrences(of: "\n", with: ""))!

// MARK: - Minimal ZIP writer (mirrors Tests/DayOneImportTests/TestZipFactory.swift)

struct ZipItem {
    var name: String
    var data: Data
    var deflated: Bool
}

func deflateRaw(_ input: Data) throws -> Data {
    var stream = z_stream()
    guard deflateInit2_(
        &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8,
        Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
    ) == Z_OK else {
        throw NSError(domain: "MakeAnonymousDayOneExport", code: 1)
    }
    defer { deflateEnd(&stream) }
    var output = Data(count: max(128, input.count * 2))
    let status = input.withUnsafeBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
            stream.next_in = UnsafeMutablePointer(
                mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(inputBytes.count)
            stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(outputBytes.count)
            return deflate(&stream, Z_FINISH)
        }
    }
    guard status == Z_STREAM_END else {
        throw NSError(domain: "MakeAnonymousDayOneExport", code: 2)
    }
    output.count = Int(stream.total_out)
    return output
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

func makeZip(items: [ZipItem], at url: URL) throws {
    var output = Data()
    var central: [(name: Data, crc: UInt32, method: UInt16, compressed: Data, offset: UInt32, originalSize: Int)] = []

    for item in items {
        let name = Data(item.name.utf8)
        let compressed = item.deflated ? try deflateRaw(item.data) : item.data
        let checksum = item.data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
        let offset = UInt32(output.count)
        output.appendLE(UInt32(0x0403_4B50))
        output.appendLE(UInt16(20))
        output.appendLE(UInt16(0x0800))
        output.appendLE(item.deflated ? UInt16(8) : UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(checksum)
        output.appendLE(UInt32(compressed.count))
        output.appendLE(UInt32(item.data.count))
        output.appendLE(UInt16(name.count))
        output.appendLE(UInt16(0))
        output.append(name)
        output.append(compressed)
        central.append((name, checksum, item.deflated ? 8 : 0, compressed, offset, item.data.count))
    }

    let centralOffset = UInt32(output.count)
    for record in central {
        output.appendLE(UInt32(0x0201_4B50))
        output.appendLE(UInt16(0x031E))
        output.appendLE(UInt16(20))
        output.appendLE(UInt16(0x0800))
        output.appendLE(record.method)
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(record.crc)
        output.appendLE(UInt32(record.compressed.count))
        output.appendLE(UInt32(record.originalSize))
        output.appendLE(UInt16(record.name.count))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt32(0))
        output.appendLE(record.offset)
        output.append(record.name)
    }
    let centralSize = UInt32(output.count) - centralOffset
    output.appendLE(UInt32(0x0605_4B50))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(0))
    output.appendLE(UInt16(central.count))
    output.appendLE(UInt16(central.count))
    output.appendLE(centralSize)
    output.appendLE(centralOffset)
    output.appendLE(UInt16(0))
    try output.write(to: url)
}

// MARK: - Entry point

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "anonymous-dayone-export.zip"
let outputURL = URL(fileURLWithPath: outputPath)

try makeZip(
    items: [
        ZipItem(name: "anonymous.json", data: jsonData, deflated: true),
        ZipItem(name: "photos/photo.jpg", data: photoData, deflated: false),
    ],
    at: outputURL
)

print("Wrote \(entries.count)-entry anonymized Day One export to \(outputURL.path)")
