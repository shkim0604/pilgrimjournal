import Foundation

/// Photo rules shared by the app's `ImageCompressor` and the server's upload check
/// (design.md 7절). JPEG only.
public enum PhotoLimits {
    /// post, comment, profile: long edge ≤ 1600 px.
    public static let maxLongEdge = 1_600
    /// post, comment, profile: ≤ 500 KB.
    public static let maxPhotoBytes = 500 * 1_024
    /// Stickers are exactly 256 × 256.
    public static let stickerSide = 256
    /// Stickers: ≤ 100 KB.
    public static let maxStickerBytes = 100 * 1_024
    public static let maxPerPost = APILimits.photosPerPost
    public static let maxPerComment = APILimits.photosPerComment
    public static let contentType = "image/jpeg"
    /// Every JPEG starts with SOI followed by a marker: `FF D8 FF`.
    public static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]
    /// Uploads not attached within this window are deleted by the worker.
    public static let unattachedLifetime: TimeInterval = 24 * 3_600

    /// The app's compression ladder: start at 0.7, step down 0.1 to 0.3, then shrink the long
    /// edge by 0.8 and repeat.
    public enum Compression {
        public static let initialQuality = 0.7
        public static let qualityStep = 0.1
        public static let minimumQuality = 0.3
        public static let downscaleFactor = 0.8
    }

    public static func maxBytes(for purpose: MediaPurpose) -> Int {
        purpose == .sticker ? maxStickerBytes : maxPhotoBytes
    }

    public static func hasJPEGSignature(_ bytes: some Collection<UInt8>) -> Bool {
        bytes.starts(with: jpegSignature)
    }

    /// Checks an upload's size against its purpose. The server reads `width`/`height` from the
    /// JPEG SOF segment.
    public static func validate(
        purpose: MediaPurpose, width: Int, height: Int, byteCount: Int
    ) throws(PhotoLimitViolation) {
        guard width > 0, height > 0 else { throw .invalidDimensions }
        if byteCount > maxBytes(for: purpose) { throw .tooLarge(limit: maxBytes(for: purpose)) }
        switch purpose {
        case .sticker:
            guard width == stickerSide, height == stickerSide else { throw .invalidDimensions }
        case .post, .comment, .profile:
            guard max(width, height) <= maxLongEdge else { throw .invalidDimensions }
        }
    }
}

public enum PhotoLimitViolation: Error, Equatable, Sendable {
    /// 413 `MEDIA_TOO_LARGE`.
    case tooLarge(limit: Int)
    /// 422 `MEDIA_INVALID`.
    case invalidDimensions

    public var code: APIErrorCode {
        switch self {
        case .tooLarge: .mediaTooLarge
        case .invalidDimensions: .mediaInvalid
        }
    }
}
