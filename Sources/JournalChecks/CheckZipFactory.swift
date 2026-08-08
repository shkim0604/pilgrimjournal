import Foundation
import zlib

enum CheckZipFactory {
    static func makeStored(name: String, data: Data, at url: URL) throws {
        let nameData = Data(name.utf8)
        let checksum = data.withUnsafeBytes { bytes in
            UInt32(crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
        var output = Data()
        output.appendLE(UInt32(0x04034B50))
        output.appendLE(UInt16(20))
        output.appendLE(UInt16(0x0800))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(checksum)
        output.appendLE(UInt32(data.count))
        output.appendLE(UInt32(data.count))
        output.appendLE(UInt16(nameData.count))
        output.appendLE(UInt16(0))
        output.append(nameData)
        output.append(data)

        let centralOffset = UInt32(output.count)
        output.appendLE(UInt32(0x02014B50))
        output.appendLE(UInt16(0x031E))
        output.appendLE(UInt16(20))
        output.appendLE(UInt16(0x0800))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(checksum)
        output.appendLE(UInt32(data.count))
        output.appendLE(UInt32(data.count))
        output.appendLE(UInt16(nameData.count))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt32(0))
        output.appendLE(UInt32(0))
        output.append(nameData)

        let centralSize = UInt32(output.count) - centralOffset
        output.appendLE(UInt32(0x06054B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(1))
        output.appendLE(UInt16(1))
        output.appendLE(centralSize)
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        try output.write(to: url)
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
