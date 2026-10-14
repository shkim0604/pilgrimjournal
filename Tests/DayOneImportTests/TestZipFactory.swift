import DayOneImport
import Foundation
import zlib

enum TestZipFactory {
    struct Item {
        var name: String
        var data: Data
        var deflated: Bool
        var encrypted: Bool = false
    }

    static func make(items: [Item], at url: URL) throws {
        var output = Data()
        var central:
            [(
                name: Data,
                crc: UInt32,
                method: UInt16,
                compressed: Data,
                offset: UInt32,
                encrypted: Bool
            )] = []

        for item in items {
            let name = Data(item.name.utf8)
            let compressed = try item.deflated ? deflateRaw(item.data) : item.data
            let checksum = ZipChecksum.crc32(item.data)
            let offset = UInt32(output.count)
            output.appendLE(UInt32(0x04034B50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800 | (item.encrypted ? 0x0001 : 0)))
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
            central.append(
                (
                    name,
                    checksum,
                    item.deflated ? 8 : 0,
                    compressed,
                    offset,
                    item.encrypted
                ))
        }

        let centralOffset = UInt32(output.count)
        for record in central {
            output.appendLE(UInt32(0x02014B50))
            output.appendLE(UInt16(0x031E))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800 | (record.encrypted ? 0x0001 : 0)))
            output.appendLE(record.method)
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))
            output.appendLE(record.crc)
            output.appendLE(UInt32(record.compressed.count))
            let original = try requireValue(
                items.first(where: {
                    Data($0.name.utf8) == record.name
                }))
            output.appendLE(UInt32(original.data.count))
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
        output.appendLE(UInt32(0x06054B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(central.count))
        output.appendLE(UInt16(central.count))
        output.appendLE(centralSize)
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        try output.write(to: url)
    }

    static func makeMediaFixture(at url: URL) throws {
        let root: [String: Any] = [
            "metadata": ["version": "1.0"],
            "entries": [
                [
                    "uuid": "fixture-with-media",
                    "text": "사진과 영상이 있는 익명 기록",
                    "creationDate": "2026-01-01T01:00:00Z",
                    "tags": ["여행", "사진"],
                    "photos": [["filename": "photo.jpg", "type": "jpeg"]],
                    "videos": [["filename": "clip.mov", "type": "quicktime"]],
                    "audios": [["filename": "missing.m4a", "type": "m4a"]],
                ],
                [
                    "uuid": "fixture-minimal",
                    "text": "선택 필드가 없는 기록",
                    "creationDate": "2026-01-02T01:00:00Z",
                ],
                [
                    "uuid": "fixture-malformed-rich-text",
                    "text": "일반 본문은 유효함",
                    "richText": "{not-json",
                    "creationDate": "2026-01-03T01:00:00Z",
                ],
                [
                    "text": "uuid가 없는 형식 오류 항목",
                    "creationDate": "2026-01-04T01:00:00Z",
                ],
            ],
        ]
        try make(
            items: [
                Item(
                    name: "anonymous.json",
                    data: try JSONSerialization.data(withJSONObject: root),
                    deflated: true
                ),
                Item(name: "photos/photo.jpg", data: Data([0xFF, 0xD8, 0xFF]), deflated: false),
                Item(name: "videos/clip.mov", data: Data("video".utf8), deflated: false),
            ],
            at: url
        )
    }

    private static func deflateRaw(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard
            deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                -MAX_WBITS,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            ) == Z_OK
        else {
            throw NSError(domain: "TestZip", code: 1)
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
            throw NSError(domain: "TestZip", code: 2)
        }
        output.count = Int(stream.total_out)
        return output
    }
}

private func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw NSError(domain: "TestZip", code: 3) }
    return value
}
