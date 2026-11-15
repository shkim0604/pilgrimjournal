import Foundation

/// A JPEG that passed the structure check, with its metadata segments removed.
public struct SanitizedJPEG: Equatable, Sendable {
    /// The rewritten file: what is stored and served.
    public var data: Data
    /// From the frame header (SOF).
    public var width: Int
    public var height: Int
}

/// Why `JPEGSanitizer` refused a file. Every case is 422 `MEDIA_INVALID` to the client.
public enum JPEGStructureError: Error, Equatable, Sendable {
    /// Does not start with `FF D8 FF`.
    case notJPEG
    /// A segment or the scan runs past the end of the file, or there is no EOI.
    case truncated
    /// A byte that should start a marker is not `FF`, a segment length is impossible, or a marker
    /// appears where it cannot (a second SOI, `FF 00` outside a scan).
    case malformedSegment
    /// No frame header before the first scan, a second frame header, or a frame header too short
    /// to hold its size.
    case invalidFrame
    /// EOI without any scan: no image data.
    case missingScan
}

/// Checks and rewrites an uploaded JPEG without decoding it (design.md 7절 "서버 검사").
///
/// The file is walked marker by marker from SOI to EOI, including the entropy-coded data of every
/// scan (where `FF` only appears as `FF 00` stuffing or an `RSTn` marker), so metadata between
/// progressive scans is found too. The output keeps every segment except
/// - APP1–APP15 (EXIF with GPS, XMP, IPTC, MPF, …) — but APP2 `ICC_PROFILE` stays, and
/// - COM,
///
/// the same rule as the app's `JPEGMetadataStripper`; APP0 (JFIF) stays. Fill bytes before
/// markers and anything after EOI (appended thumbnails, trailers) are dropped. Image data is copied
/// byte for byte, so the result decodes to the same pixels, and sanitizing it again changes
/// nothing.
public enum JPEGSanitizer {
    public static func sanitize(_ data: Data) throws(JPEGStructureError) -> SanitizedJPEG {
        let bytes = [UInt8](data)
        let count = bytes.count
        guard bytes.starts(with: [0xFF, 0xD8, 0xFF]) else { throw .notJPEG }

        var output: [UInt8] = [0xFF, 0xD8]
        output.reserveCapacity(count)
        var frame: (width: Int, height: Int)?
        var sawScan = false
        var index = 2

        while true {
            guard index < count else { throw .truncated }
            guard bytes[index] == 0xFF else { throw .malformedSegment }
            // Any number of fill bytes may precede the marker code.
            var markerIndex = index + 1
            while markerIndex < count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
            guard markerIndex < count else { throw .truncated }
            let marker = bytes[markerIndex]
            let segmentStart = markerIndex + 1

            switch marker {
            case 0x00, 0xD8:
                throw .malformedSegment
            case 0xD9: // EOI: done; whatever follows is dropped.
                guard sawScan else { throw .missingScan }
                output += [0xFF, 0xD9]
                guard let frame else { throw .invalidFrame }
                return SanitizedJPEG(data: Data(output), width: frame.width, height: frame.height)
            case 0x01, 0xD0...0xD7: // TEM, RSTn: no length.
                output += [0xFF, marker]
                index = segmentStart
                continue
            default:
                break
            }

            guard segmentStart + 1 < count else { throw .truncated }
            let length = Int(bytes[segmentStart]) << 8 | Int(bytes[segmentStart + 1])
            guard length >= 2 else { throw .malformedSegment }
            let segmentEnd = segmentStart + length
            guard segmentEnd <= count else { throw .truncated }
            let payload = bytes[(segmentStart + 2)..<segmentEnd]

            if isFrameHeader(marker) {
                // P(1) Y(2) X(2) Nf(1) …
                guard frame == nil, payload.count >= 6 else { throw .invalidFrame }
                let base = payload.startIndex
                let height = Int(payload[base + 1]) << 8 | Int(payload[base + 2])
                let width = Int(payload[base + 3]) << 8 | Int(payload[base + 4])
                frame = (width, height)
            }

            if marker == 0xDA { // SOS: header, then entropy-coded data up to the next marker.
                guard frame != nil else { throw .invalidFrame }
                output += [0xFF, marker]
                output += bytes[segmentStart..<segmentEnd]
                let scanEnd = try endOfEntropyCodedData(bytes, from: segmentEnd)
                output += bytes[segmentEnd..<scanEnd]
                sawScan = true
                index = scanEnd
                continue
            }

            if !isMetadata(marker: marker, payload: payload) {
                output += [0xFF, marker]
                output += bytes[segmentStart..<segmentEnd]
            }
            index = segmentEnd
        }
    }

    /// SOF0–SOF15 except DHT (C4), JPG (C8) and DAC (CC).
    static func isFrameHeader(_ marker: UInt8) -> Bool {
        (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
    }

    private static let iccIdentifier = Array("ICC_PROFILE\0".utf8)

    /// APP1–APP15 and COM, except an APP2 ICC colour profile.
    static func isMetadata(marker: UInt8, payload: ArraySlice<UInt8>) -> Bool {
        switch marker {
        case 0xFE: true
        case 0xE2: !payload.starts(with: iccIdentifier)
        case 0xE1...0xEF: true
        default: false
        }
    }

    /// The index of the `FF` that starts the first marker after a scan's entropy-coded data
    /// (skipping `FF 00` stuffing and `RSTn`).
    private static func endOfEntropyCodedData(_ bytes: [UInt8], from start: Int)
        throws(JPEGStructureError) -> Int
    {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0xFF {
                guard index + 1 < bytes.count else { throw .truncated }
                let next = bytes[index + 1]
                if next == 0x00 || (0xD0...0xD7).contains(next) {
                    index += 2
                    continue
                }
                return index
            }
            index += 1
        }
        throw .truncated
    }
}
