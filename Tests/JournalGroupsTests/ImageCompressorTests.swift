#if canImport(XCTest)
import CoreGraphics
import Foundation
import ImageIO
import JournalGroups
import PilgrimAPI
import UniformTypeIdentifiers
import XCTest

/// Generated test images (no real photos in the repo).
enum TestImages {
    /// A gradient with deterministic noise, so JPEG cannot squeeze it much.
    static func cgImage(width: Int, height: Int, alpha: Bool = false, noise: Bool = true)
        throws -> CGImage
    {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<height {
            for x in 0..<width {
                state ^= state << 13
                state ^= state >> 7
                state ^= state << 17
                let n = noise ? Int(state & 0x7F) : 0
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8(min(255, x * 255 / max(1, width) / 2 + n))
                pixels[offset + 1] = UInt8(min(255, y * 255 / max(1, height) / 2 + n))
                pixels[offset + 2] = UInt8(min(255, 64 + Int((state >> 8) & 0x7F)))
                pixels[offset + 3] = alpha ? UInt8(x % 255) : 255
            }
        }
        let info =
            alpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: space, bitmapInfo: info),
            let image = context.makeImage()
        else { throw ImageCompressionError.encodingFailed }
        return image
    }

    /// A camera-like JPEG: EXIF, GPS, TIFF and IPTC metadata plus an orientation tag.
    static func jpegWithMetadata(width: Int, height: Int, orientation: Int, quality: Double = 0.95)
        throws -> Data
    {
        let image = try cgImage(width: width, height: height)
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.5665, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 126.978, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:14 09:00:00",
                kCGImagePropertyExifUserComment: "private note",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "One",
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "caption"],
        ]
        return try encode(image, type: .jpeg, properties: properties)
    }

    static func png(width: Int, height: Int, alpha: Bool) throws -> Data {
        try encode(try cgImage(width: width, height: height, alpha: alpha), type: .png)
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) throws
        -> Data
    {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, type.identifier as CFString, 1, nil)
        else { throw ImageCompressionError.encodingFailed }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageCompressionError.encodingFailed
        }
        return output as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return properties
    }
}

final class ImageCompressorTests: XCTestCase {
    func testLargeCameraPhotoIsShrunkStrippedAndUpright() throws {
        // 3000 × 2000 stored landscape, orientation 6 = displayed portrait.
        let input = try TestImages.jpegWithMetadata(width: 3_000, height: 2_000, orientation: 6)
        let inputProperties = TestImages.properties(input)
        XCTAssertNotNil(inputProperties[kCGImagePropertyGPSDictionary], "fixture has GPS")
        XCTAssertGreaterThan(input.count, PhotoLimits.maxPhotoBytes, "fixture is over the limit")

        let output = try ImageCompressor.compress(input, for: .post)

        XCTAssertLessThanOrEqual(output.data.count, PhotoLimits.maxPhotoBytes)
        XCTAssertLessThanOrEqual(max(output.width, output.height), PhotoLimits.maxLongEdge)
        XCTAssertGreaterThan(output.height, output.width, "orientation applied to pixels")
        XCTAssertTrue(PhotoLimits.hasJPEGSignature(output.data))
        XCTAssertNoThrow(
            try PhotoLimits.validate(
                purpose: .post, width: output.width, height: output.height,
                byteCount: output.data.count))

        let properties = TestImages.properties(output.data)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(properties[kCGImagePropertyExifDictionary])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        XCTAssertNil(properties[kCGImagePropertyIPTCDictionary])
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, output.width)

        let markers = try XCTUnwrap(JPEGMetadataStripper.segmentMarkers(output.data))
        XCTAssertFalse(markers.contains { (0xE1...0xEF).contains($0) && $0 != 0xE2 })
        XCTAssertFalse(markers.contains(0xFE))
        XCTAssertEqual(markers.last, 0xDA)
    }

    func testTightLimitWalksTheWholeLadder() throws {
        let input = try TestImages.jpegWithMetadata(width: 1_200, height: 900, orientation: 1)

        let output = try ImageCompressor.compressPhoto(input, maxBytes: 40 * 1_024)

        XCTAssertLessThanOrEqual(output.data.count, 40 * 1_024)
        XCTAssertLessThan(output.width, 1_200, "had to shrink after quality 0.3")
        XCTAssertEqual(output.quality, PhotoLimits.Compression.minimumQuality, accuracy: 0.001)
    }

    func testSmallImageKeepsItsSizeAndLosesAlpha() throws {
        let input = try TestImages.png(width: 400, height: 300, alpha: true)

        let output = try ImageCompressor.compress(input, for: .comment)

        XCTAssertEqual(output.width, 400)
        XCTAssertEqual(output.height, 300)
        XCTAssertEqual(output.quality, PhotoLimits.Compression.initialQuality, accuracy: 0.001)
        let properties = TestImages.properties(output.data)
        XCTAssertNotEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
        XCTAssertEqual(properties[kCGImagePropertyColorModel] as? String, "RGB")
    }

    func testProfilePhotoUsesPhotoLimits() throws {
        let input = try TestImages.jpegWithMetadata(width: 2_400, height: 2_400, orientation: 1)
        let output = try ImageCompressor.compressProfilePhoto(input)
        XCTAssertNoThrow(
            try PhotoLimits.validate(
                purpose: .profile, width: output.width, height: output.height,
                byteCount: output.data.count))
        XCTAssertEqual(output.width, 1_600)
    }

    func testStickerIsACentredSquare() throws {
        let input = try TestImages.jpegWithMetadata(width: 900, height: 500, orientation: 1)

        let output = try ImageCompressor.compress(input, for: .sticker)

        XCTAssertEqual(output.width, PhotoLimits.stickerSide)
        XCTAssertEqual(output.height, PhotoLimits.stickerSide)
        XCTAssertLessThanOrEqual(output.data.count, PhotoLimits.maxStickerBytes)
        XCTAssertNoThrow(
            try PhotoLimits.validate(
                purpose: .sticker, width: output.width, height: output.height,
                byteCount: output.data.count))
        XCTAssertNil(TestImages.properties(output.data)[kCGImagePropertyGPSDictionary])
    }

    func testTinyStickerIsEnlargedToTheExactSide() throws {
        let input = try TestImages.png(width: 40, height: 90, alpha: false)
        let output = try ImageCompressor.compressSticker(input)
        XCTAssertEqual(output.width, 256)
        XCTAssertEqual(output.height, 256)
    }

    func testUnreadableInput() {
        XCTAssertThrowsError(try ImageCompressor.compress(Data("not an image".utf8), for: .post)) {
            error in
            XCTAssertEqual(error as? ImageCompressionError, .unreadableImage)
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "사진을 읽을 수 없어요")
        }
    }

    func testStripperDropsMetadataSegmentsAndKeepsTheImage() throws {
        let clean = try TestImages.encode(
            try TestImages.cgImage(width: 32, height: 32), type: .jpeg)
        // Splice an APP1 (EXIF-like), an APP13 and a COM segment right after SOI.
        func segment(_ marker: UInt8, _ payload: String) -> [UInt8] {
            let bytes = Array(payload.utf8)
            let length = bytes.count + 2
            return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + bytes
        }
        let icc = segment(0xE2, "ICC_PROFILE\0fake")
        let spliced =
            Data([0xFF, 0xD8]) + Data(segment(0xE1, "Exif\0\0GPS")) + Data(segment(0xED, "IPTC"))
            + Data(segment(0xFE, "comment")) + Data(icc) + clean.dropFirst(2)

        let stripped = try XCTUnwrap(JPEGMetadataStripper.strip(spliced))

        let markers = try XCTUnwrap(JPEGMetadataStripper.segmentMarkers(stripped))
        XCTAssertFalse(markers.contains(0xE1))
        XCTAssertFalse(markers.contains(0xED))
        XCTAssertFalse(markers.contains(0xFE))
        XCTAssertTrue(markers.contains(0xE2), "ICC profile kept")
        XCTAssertNil(stripped.range(of: Data("GPS".utf8)))
        let cleanStripped = try XCTUnwrap(JPEGMetadataStripper.strip(clean))
        XCTAssertEqual(stripped.count, cleanStripped.count + icc.count)
        XCTAssertEqual(
            (TestImages.properties(stripped)[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            32)
        XCTAssertNil(JPEGMetadataStripper.strip(Data([0x00, 0x01, 0x02, 0x03])))
    }
}
#endif
