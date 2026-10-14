import Foundation
import JournalDomain
import zlib

public struct ZipSafetyLimits: Sendable {
    public var maximumFileCount: Int
    public var maximumEntrySize: UInt64
    public var maximumTotalSize: UInt64
    public var maximumCompressionRatio: Double

    public init(
        maximumFileCount: Int = 50_000,
        maximumEntrySize: UInt64 = 2 * 1_024 * 1_024 * 1_024,
        maximumTotalSize: UInt64 = 20 * 1_024 * 1_024 * 1_024,
        maximumCompressionRatio: Double = 1_000
    ) {
        self.maximumFileCount = maximumFileCount
        self.maximumEntrySize = maximumEntrySize
        self.maximumTotalSize = maximumTotalSize
        self.maximumCompressionRatio = maximumCompressionRatio
    }
}

public struct ZipEntry: Equatable, Sendable {
    public var rawName: String
    public var displayName: String
    public var compressionMethod: UInt16
    public var compressedSize: UInt64
    public var uncompressedSize: UInt64
    public var crc32: UInt32
    public var localHeaderOffset: UInt64
    public var isDirectory: Bool

    public var isJSONCandidate: Bool {
        !isDirectory && displayName.lowercased().hasSuffix(".json")
    }
}

public final class SafeZipArchive: @unchecked Sendable {
    private let url: URL
    private let limits: ZipSafetyLimits
    private let entriesStorage: [ZipEntry]

    public var entries: [ZipEntry] { entriesStorage }

    public init(url: URL, limits: ZipSafetyLimits = ZipSafetyLimits()) throws {
        self.url = url
        self.limits = limits
        entriesStorage = try Self.readDirectory(url: url, limits: limits)
    }

    public func data(for entry: ZipEntry) throws -> Data {
        guard entry.uncompressedSize <= limits.maximumEntrySize else {
            throw JournalError.unsafeArchive("개별 파일 크기 제한을 초과했습니다.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let header = try handle.readExactly(at: entry.localHeaderOffset, count: 30)
        guard header.uint32LE(at: 0) == 0x04034B50 else {
            throw JournalError.unsupportedArchive("로컬 ZIP header가 올바르지 않습니다.")
        }
        let flags = header.uint16LE(at: 6)
        guard flags & 0x0001 == 0 else {
            throw JournalError.unsupportedArchive("암호화 ZIP은 지원하지 않습니다.")
        }
        let nameLength = Int(header.uint16LE(at: 26))
        let extraLength = Int(header.uint16LE(at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength + extraLength)
        guard entry.compressedSize <= UInt64(Int.max) else {
            throw JournalError.unsafeArchive("압축 데이터가 너무 큽니다.")
        }
        let compressed = try handle.readExactly(
            at: dataOffset,
            count: Int(entry.compressedSize)
        )

        let result: Data
        switch entry.compressionMethod {
        case 0:
            result = compressed
        case 8:
            result = try inflateRaw(
                compressed,
                expectedSize: entry.uncompressedSize,
                maximumSize: limits.maximumEntrySize
            )
        default:
            throw JournalError.unsupportedArchive(
                "ZIP 압축 방식 \(entry.compressionMethod)은 지원하지 않습니다."
            )
        }

        guard UInt64(result.count) == entry.uncompressedSize else {
            throw JournalError.unsupportedArchive("압축 해제 크기가 ZIP metadata와 다릅니다.")
        }
        guard crc(of: result) == entry.crc32 else {
            throw JournalError.unsupportedArchive("파일 checksum이 일치하지 않습니다.")
        }
        return result
    }

    private static func readDirectory(
        url: URL,
        limits: ZipSafetyLimits
    ) throws -> [ZipEntry] {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSizeValue = values.fileSize else {
            throw JournalError.unsupportedArchive("일반 ZIP 파일이 아닙니다.")
        }
        let fileSize = UInt64(fileSizeValue)
        guard fileSize >= 22 else {
            throw JournalError.unsupportedArchive("ZIP 파일이 너무 작습니다.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let tailCount = Int(min(fileSize, 65_557))
        let tailOffset = fileSize - UInt64(tailCount)
        let tail = try handle.readExactly(at: tailOffset, count: tailCount)
        guard let eocdIndex = tail.lastIndex(ofSignature: 0x06054B50) else {
            throw JournalError.unsupportedArchive("ZIP 중앙 디렉터리를 찾을 수 없습니다.")
        }
        let eocdOffset = tailOffset + UInt64(eocdIndex)
        let eocd = tail.subdata(in: eocdIndex..<min(tail.count, eocdIndex + 22))
        guard eocd.count >= 22 else {
            throw JournalError.unsupportedArchive("ZIP 종료 record가 손상되었습니다.")
        }

        var totalEntries = UInt64(eocd.uint16LE(at: 10))
        var centralSize = UInt64(eocd.uint32LE(at: 12))
        var centralOffset = UInt64(eocd.uint32LE(at: 16))
        if totalEntries == UInt64(UInt16.max)
            || centralSize == UInt64(UInt32.max)
            || centralOffset == UInt64(UInt32.max)
        {
            guard eocdOffset >= 20 else {
                throw JournalError.unsupportedArchive("ZIP64 locator가 없습니다.")
            }
            let locator = try handle.readExactly(at: eocdOffset - 20, count: 20)
            guard locator.uint32LE(at: 0) == 0x07064B50 else {
                throw JournalError.unsupportedArchive("ZIP64 locator가 손상되었습니다.")
            }
            let zip64Offset = locator.uint64LE(at: 8)
            let zip64 = try handle.readExactly(at: zip64Offset, count: 56)
            guard zip64.uint32LE(at: 0) == 0x06064B50 else {
                throw JournalError.unsupportedArchive("ZIP64 종료 record가 손상되었습니다.")
            }
            totalEntries = zip64.uint64LE(at: 32)
            centralSize = zip64.uint64LE(at: 40)
            centralOffset = zip64.uint64LE(at: 48)
        }

        guard totalEntries <= UInt64(limits.maximumFileCount) else {
            throw JournalError.unsafeArchive("ZIP 파일 수 제한을 초과했습니다.")
        }
        guard centralOffset + centralSize <= fileSize else {
            throw JournalError.unsupportedArchive("ZIP 중앙 디렉터리 범위가 잘못되었습니다.")
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(Int(totalEntries))
        var offset = centralOffset
        var totalUncompressed: UInt64 = 0

        for _ in 0..<totalEntries {
            let fixed = try handle.readExactly(at: offset, count: 46)
            guard fixed.uint32LE(at: 0) == 0x02014B50 else {
                throw JournalError.unsupportedArchive("ZIP entry header가 손상되었습니다.")
            }
            let flags = fixed.uint16LE(at: 8)
            guard flags & 0x0001 == 0 else {
                throw JournalError.unsupportedArchive("암호화 ZIP은 지원하지 않습니다.")
            }
            let method = fixed.uint16LE(at: 10)
            let checksum = fixed.uint32LE(at: 16)
            let compressed32 = fixed.uint32LE(at: 20)
            let uncompressed32 = fixed.uint32LE(at: 24)
            let nameLength = Int(fixed.uint16LE(at: 28))
            let extraLength = Int(fixed.uint16LE(at: 30))
            let commentLength = Int(fixed.uint16LE(at: 32))
            let localOffset32 = fixed.uint32LE(at: 42)
            let variable = try handle.readExactly(
                at: offset + 46,
                count: nameLength + extraLength + commentLength
            )
            let nameData = variable.prefix(nameLength)
            let extraData = variable.subdata(
                in: nameLength..<(nameLength + extraLength)
            )

            var compressed = UInt64(compressed32)
            var uncompressed = UInt64(uncompressed32)
            var localOffset = UInt64(localOffset32)
            if compressed32 == UInt32.max
                || uncompressed32 == UInt32.max
                || localOffset32 == UInt32.max
            {
                let values = try zip64Values(
                    extraData,
                    needsUncompressed: uncompressed32 == UInt32.max,
                    needsCompressed: compressed32 == UInt32.max,
                    needsOffset: localOffset32 == UInt32.max
                )
                if let value = values.uncompressed { uncompressed = value }
                if let value = values.compressed { compressed = value }
                if let value = values.offset { localOffset = value }
            }

            let rawName = String(decoding: nameData, as: UTF8.self)
            let displayName = rawName.removingPercentEncoding ?? rawName
            try validatePath(displayName)
            guard uncompressed <= limits.maximumEntrySize else {
                throw JournalError.unsafeArchive("개별 파일 크기 제한을 초과했습니다.")
            }
            let addition = totalUncompressed.addingReportingOverflow(uncompressed)
            guard !addition.overflow else {
                throw JournalError.unsafeArchive("ZIP 전체 크기가 범위를 벗어났습니다.")
            }
            totalUncompressed = addition.partialValue
            guard totalUncompressed <= limits.maximumTotalSize else {
                throw JournalError.unsafeArchive("ZIP 전체 압축 해제 크기 제한을 초과했습니다.")
            }
            if uncompressed > 0 {
                guard compressed > 0 else {
                    throw JournalError.unsafeArchive("비정상적인 압축률입니다.")
                }
                let ratio = Double(uncompressed) / Double(compressed)
                guard ratio <= limits.maximumCompressionRatio else {
                    throw JournalError.unsafeArchive("압축률 안전 제한을 초과했습니다.")
                }
            }

            entries.append(
                ZipEntry(
                    rawName: rawName,
                    displayName: displayName,
                    compressionMethod: method,
                    compressedSize: compressed,
                    uncompressedSize: uncompressed,
                    crc32: checksum,
                    localHeaderOffset: localOffset,
                    isDirectory: displayName.hasSuffix("/")
                ))
            offset += UInt64(46 + nameLength + extraLength + commentLength)
        }
        return entries
    }

    private static func zip64Values(
        _ extra: Data,
        needsUncompressed: Bool,
        needsCompressed: Bool,
        needsOffset: Bool
    ) throws -> (uncompressed: UInt64?, compressed: UInt64?, offset: UInt64?) {
        var cursor = 0
        while cursor + 4 <= extra.count {
            let identifier = extra.uint16LE(at: cursor)
            let size = Int(extra.uint16LE(at: cursor + 2))
            let start = cursor + 4
            let end = start + size
            guard end <= extra.count else { break }
            if identifier == 0x0001 {
                var valueCursor = start
                func next() throws -> UInt64 {
                    guard valueCursor + 8 <= end else {
                        throw JournalError.unsupportedArchive("ZIP64 extra field가 짧습니다.")
                    }
                    defer { valueCursor += 8 }
                    return extra.uint64LE(at: valueCursor)
                }
                let uncompressed = try needsUncompressed ? next() : nil
                let compressed = try needsCompressed ? next() : nil
                let offset = try needsOffset ? next() : nil
                return (uncompressed, compressed, offset)
            }
            cursor = end
        }
        throw JournalError.unsupportedArchive("필요한 ZIP64 extra field가 없습니다.")
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasPrefix("\\"),
            !path.contains("\0")
        else {
            throw JournalError.unsafeArchive("절대 경로나 빈 경로가 포함되어 있습니다.")
        }
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw JournalError.unsafeArchive("상위 디렉터리 경로가 포함되어 있습니다.")
        }
        if normalized.count >= 2 {
            let second = normalized.index(after: normalized.startIndex)
            guard normalized[second] != ":" else {
                throw JournalError.unsafeArchive("drive 경로가 포함되어 있습니다.")
            }
        }
    }
}

private func inflateRaw(
    _ compressed: Data,
    expectedSize: UInt64,
    maximumSize: UInt64
) throws -> Data {
    guard expectedSize <= maximumSize, expectedSize <= UInt64(Int.max) else {
        throw JournalError.unsafeArchive("압축 해제 결과가 너무 큽니다.")
    }
    var stream = z_stream()
    let initialized = inflateInit2_(
        &stream,
        -MAX_WBITS,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initialized == Z_OK else {
        throw JournalError.unsupportedArchive("deflate 초기화에 실패했습니다.")
    }
    defer { inflateEnd(&stream) }

    var output = Data(count: Int(expectedSize))
    let result = compressed.withUnsafeBytes { inputBytes in
        output.withUnsafeMutableBytes { outputBytes in
            stream.next_in = UnsafeMutablePointer(
                mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress
            )
            stream.avail_in = uInt(inputBytes.count)
            stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
            stream.avail_out = uInt(outputBytes.count)
            return inflate(&stream, Z_FINISH)
        }
    }
    guard result == Z_STREAM_END, stream.total_out == expectedSize else {
        throw JournalError.unsupportedArchive("deflate 데이터가 손상되었습니다.")
    }
    return output
}

private func crc(of data: Data) -> UInt32 {
    data.withUnsafeBytes { bytes in
        UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
    }
}

private extension FileHandle {
    func readExactly(at offset: UInt64, count: Int) throws -> Data {
        if count == 0 { return Data() }
        try seek(toOffset: offset)
        guard let data = try read(upToCount: count), data.count == count else {
            throw JournalError.unsupportedArchive(
                "ZIP 파일이 예상보다 짧습니다(offset=\(offset), count=\(count))."
            )
        }
        return data
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func uint64LE(at offset: Int) -> UInt64 {
        UInt64(uint32LE(at: offset)) | (UInt64(uint32LE(at: offset + 4)) << 32)
    }

    func lastIndex(ofSignature signature: UInt32) -> Int? {
        guard count >= 4 else { return nil }
        for index in stride(from: count - 4, through: 0, by: -1) {
            if uint32LE(at: index) == signature { return index }
        }
        return nil
    }
}
