import CoreGraphics
import Foundation
import ImageIO
import PilgrimAPI
import UniformTypeIdentifiers

/// A JPEG ready for `POST /uploads`.
public struct CompressedImage: Equatable, Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    /// The JPEG quality the data was written with.
    public var quality: Double

    public init(data: Data, width: Int, height: Int, quality: Double) {
        self.data = data
        self.width = width
        self.height = height
        self.quality = quality
    }
}

public enum ImageCompressionError: Error, Equatable, Sendable {
    /// ImageIO could not read the input.
    case unreadableImage
    /// Drawing or JPEG encoding failed.
    case encodingFailed
    /// Even the smallest size on the ladder is over the byte limit.
    case cannotFitLimit
}

/// Turns any image ImageIO reads (HEIC, JPEG, PNG, …) into an upload JPEG (design.md 7절):
///
/// - photos (post, comment, profile): long edge ≤ 1600 px (never enlarged), JPEG quality 0.7
///   stepping down by 0.1 to 0.3 until ≤ 500 KB, then the long edge × 0.8 and again;
/// - stickers: centre square crop, exactly 256 × 256, ≤ 100 KB.
///
/// The EXIF orientation is applied to the pixels, transparency is flattened onto white, and no
/// metadata is written: no EXIF, GPS, TIFF, IPTC or XMP (only JFIF and an ICC profile remain).
/// Pure and synchronous; call it off the main actor.
public enum ImageCompressor {
    /// The photo ladder never goes below this long edge.
    public static let minimumPhotoLongEdge = 160

    public static func compress(_ data: Data, for purpose: MediaPurpose)
        throws(ImageCompressionError) -> CompressedImage
    {
        switch purpose {
        case .sticker: try compressSticker(data)
        case .post, .comment, .profile: try compressPhoto(data)
        }
    }

    /// Profile photos use the photo limits.
    public static func compressProfilePhoto(_ data: Data) throws(ImageCompressionError)
        -> CompressedImage
    {
        try compressPhoto(data)
    }

    public static func compressPhoto(
        _ data: Data, maxLongEdge: Int = PhotoLimits.maxLongEdge,
        maxBytes: Int = PhotoLimits.maxPhotoBytes
    ) throws(ImageCompressionError) -> CompressedImage {
        let source = try makeSource(data)
        let (width, height) = try orientedSize(source)
        var longEdge = min(max(width, height), maxLongEdge)
        while longEdge >= min(minimumPhotoLongEdge, max(width, height)) {
            let image = try flattened(try thumbnail(source, maxPixelSize: longEdge))
            if let fitted = try encodeFitting(image, maxBytes: maxBytes) { return fitted }
            let next = Int(
                (Double(longEdge) * PhotoLimits.Compression.downscaleFactor).rounded(
                    .down))
            guard next < longEdge, next >= 1 else { break }
            longEdge = next
        }
        throw .cannotFitLimit
    }

    public static func compressSticker(
        _ data: Data, side: Int = PhotoLimits.stickerSide,
        maxBytes: Int = PhotoLimits.maxStickerBytes
    ) throws(ImageCompressionError) -> CompressedImage {
        let source = try makeSource(data)
        let (width, height) = try orientedSize(source)
        // Decode only as large as needed for the short edge to keep 2× the sticker side.
        let shortEdge = max(1, min(width, height))
        let longEdge = max(width, height)
        let wanted = Int((Double(longEdge) * Double(side * 2) / Double(shortEdge)).rounded(.up))
        let image = try thumbnail(source, maxPixelSize: min(longEdge, max(wanted, side)))
        let cropSide = min(image.width, image.height)
        let cropRect = CGRect(
            x: (image.width - cropSide) / 2, y: (image.height - cropSide) / 2, width: cropSide,
            height: cropSide)
        guard let square = image.cropping(to: cropRect) else { throw .encodingFailed }
        let scaled = try render(square, width: side, height: side)
        guard let fitted = try encodeFitting(scaled, maxBytes: maxBytes) else {
            throw .cannotFitLimit
        }
        return fitted
    }

    // MARK: Steps

    private static func makeSource(_ data: Data) throws(ImageCompressionError) -> CGImageSource {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            CGImageSourceGetCount(source) > 0
        else { throw .unreadableImage }
        return source
    }

    /// Pixel size after the EXIF orientation is applied.
    private static func orientedSize(_ source: CGImageSource) throws(ImageCompressionError)
        -> (Int, Int)
    {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        else { throw .unreadableImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// Decodes at most `maxPixelSize` on the long edge with the orientation applied.
    private static func thumbnail(_ source: CGImageSource, maxPixelSize: Int)
        throws(ImageCompressionError) -> CGImage
    {
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw .unreadableImage
        }
        return image
    }

    private static func flattened(_ image: CGImage) throws(ImageCompressionError) -> CGImage {
        try render(image, width: image.width, height: image.height)
    }

    /// Draws into an opaque 8-bit RGB bitmap on white (JPEG has no alpha).
    private static func render(_ image: CGImage, width: Int, height: Int)
        throws(ImageCompressionError) -> CGImage
    {
        let colorSpace =
            image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw .encodingFailed }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let output = context.makeImage() else { throw .encodingFailed }
        return output
    }

    /// Tries the quality ladder at this size; nil when even the lowest quality is too big.
    private static func encodeFitting(_ image: CGImage, maxBytes: Int)
        throws(ImageCompressionError) -> CompressedImage?
    {
        for quality in qualityLadder {
            let data = try encode(image, quality: quality)
            if data.count <= maxBytes {
                return CompressedImage(
                    data: data, width: image.width, height: image.height, quality: quality)
            }
        }
        return nil
    }

    /// 0.7, 0.6, 0.5, 0.4, 0.3.
    static let qualityLadder: [Double] = {
        let compression = PhotoLimits.Compression.self
        let steps = Int(
            ((compression.initialQuality - compression.minimumQuality) / compression.qualityStep)
                .rounded())
        return (0...steps).map {
            ((compression.initialQuality - Double($0) * compression.qualityStep) * 100).rounded()
                / 100
        }
    }()

    private static func encode(_ image: CGImage, quality: Double) throws(ImageCompressionError)
        -> Data
    {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw .encodingFailed }
        let properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination),
            let stripped = JPEGMetadataStripper.strip(output as Data)
        else { throw .encodingFailed }
        return stripped
    }
}
