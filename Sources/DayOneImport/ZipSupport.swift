import Foundation
import zlib

/// The CRC-32 every ZIP local header and central-directory record carries.
public enum ZipChecksum {
    public static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(zlib.crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
    }
}

extension Data {
    /// Appends `value` in little-endian byte order, as every ZIP header field
    /// is stored.
    package mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
