import Foundation
import JournalDomain
import zlib

final class StoredZipWriter {
    private struct CentralRecord {
        var name: Data
        var checksum: UInt32
        var size: UInt32
        var localOffset: UInt32
    }

    private let handle: FileHandle
    private var centralRecords: [CentralRecord] = []
    private var offset: UInt64 = 0
    private var isFinished = false

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    func add(name: String, data: Data) throws {
        guard !isFinished else {
            throw JournalError.invalidBackup("이미 완료된 ZIP입니다.")
        }
        guard let nameData = name.data(using: .utf8), !nameData.isEmpty,
              data.count <= Int(UInt32.max),
              offset <= UInt64(UInt32.max) else {
            throw JournalError.invalidBackup("ZIP64가 필요한 백업 크기입니다.")
        }
        let checksum = dataCRC(data)
        var header = Data()
        header.appendLE(UInt32(0x04034B50))
        header.appendLE(UInt16(20))
        header.appendLE(UInt16(0x0800))
        header.appendLE(UInt16(0))
        header.appendLE(UInt16(0))
        header.appendLE(UInt16(0))
        header.appendLE(checksum)
        header.appendLE(UInt32(data.count))
        header.appendLE(UInt32(data.count))
        header.appendLE(UInt16(nameData.count))
        header.appendLE(UInt16(0))
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: nameData)
        try handle.write(contentsOf: data)
        centralRecords.append(CentralRecord(
            name: nameData,
            checksum: checksum,
            size: UInt32(data.count),
            localOffset: UInt32(offset)
        ))
        offset += UInt64(header.count + nameData.count + data.count)
    }

    func finish() throws {
        guard !isFinished else { return }
        guard centralRecords.count <= Int(UInt16.max),
              offset <= UInt64(UInt32.max) else {
            throw JournalError.invalidBackup("ZIP64가 필요한 백업입니다.")
        }
        let centralOffset = UInt32(offset)
        var centralSize: UInt64 = 0
        for record in centralRecords {
            var header = Data()
            header.appendLE(UInt32(0x02014B50))
            header.appendLE(UInt16(0x031E))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(record.checksum)
            header.appendLE(record.size)
            header.appendLE(record.size)
            header.appendLE(UInt16(record.name.count))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt16(0))
            header.appendLE(UInt32(0))
            header.appendLE(record.localOffset)
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: record.name)
            centralSize += UInt64(header.count + record.name.count)
        }
        guard centralSize <= UInt64(UInt32.max) else {
            throw JournalError.invalidBackup("ZIP 중앙 디렉터리가 너무 큽니다.")
        }
        var end = Data()
        end.appendLE(UInt32(0x06054B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(centralRecords.count))
        end.appendLE(UInt16(centralRecords.count))
        end.appendLE(UInt32(centralSize))
        end.appendLE(centralOffset)
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.synchronize()
        try handle.close()
        isFinished = true
    }
}

private func dataCRC(_ data: Data) -> UInt32 {
    data.withUnsafeBytes { bytes in
        UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
