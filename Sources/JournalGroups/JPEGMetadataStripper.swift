import Foundation

/// Removes metadata segments from a JPEG without decoding it: APP1–APP15 (EXIF, XMP, IPTC,
/// FlashPix, …) and COM are dropped; APP0 (JFIF) and APP2 `ICC_PROFILE` are kept, the same
/// rule the server applies (design.md 7절). Entropy-coded data after SOS is copied unchanged.
public enum JPEGMetadataStripper {
    /// nil when `data` is not a well-formed JPEG up to its first SOS.
    public static func strip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var output: [UInt8] = [0xFF, 0xD8]
        output.reserveCapacity(bytes.count)
        var index = 2
        while index < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            // Fill bytes: any number of 0xFF before the marker code.
            var markerIndex = index + 1
            while markerIndex < bytes.count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < bytes.count else { return nil }
            let marker = bytes[markerIndex]
            let segmentStart = markerIndex + 1
            switch marker {
            case 0xD9: // EOI before any scan
                output += [0xFF, 0xD9]
                return Data(output)
            case 0x01, 0xD0...0xD7: // standalone markers
                output += [0xFF, marker]
                index = segmentStart
                continue
            default:
                break
            }
            guard segmentStart + 1 < bytes.count else { return nil }
            let length = Int(bytes[segmentStart]) << 8 | Int(bytes[segmentStart + 1])
            guard length >= 2, segmentStart + length <= bytes.count else { return nil }
            let segmentEnd = segmentStart + length
            if marker == 0xDA {
                // SOS: the rest is scan data (and later markers we do not touch).
                output += [0xFF, marker]
                output += bytes[segmentStart..<bytes.count]
                return Data(output)
            }
            if !isDropped(marker: marker, payload: bytes[(segmentStart + 2)..<segmentEnd]) {
                output += [0xFF, marker]
                output += bytes[segmentStart..<segmentEnd]
            }
            index = segmentEnd
        }
        return nil
    }

    private static let iccIdentifier = Array("ICC_PROFILE\0".utf8)

    private static func isDropped(marker: UInt8, payload: ArraySlice<UInt8>) -> Bool {
        switch marker {
        case 0xFE: return true // COM
        case 0xE2: return !payload.starts(with: iccIdentifier)
        case 0xE1...0xEF: return true
        default: return false
        }
    }

    /// The marker codes of every segment before SOS (for tests and diagnostics).
    public static func segmentMarkers(_ data: Data) -> [UInt8]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var markers: [UInt8] = []
        var index = 2
        while index + 3 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xDA || marker == 0xD9 {
                markers.append(marker)
                return markers
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { return nil }
            markers.append(marker)
            index += 2 + length
        }
        return markers
    }
}
