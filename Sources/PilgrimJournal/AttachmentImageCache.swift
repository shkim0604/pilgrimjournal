import CoreGraphics
import Foundation
import ImageIO

// Named distinctly from MarkdownSupport.swift's file-private `PlatformImage`
// alias (same underlying type, NSImage/UIImage) — this one can't be
// `private` since it's this cache's public return type, and a second
// same-named typealias at a different access level in the same module
// conflicts with the other file's declaration.
#if os(macOS)
import AppKit
typealias CachedPlatformImage = NSImage
#elseif os(iOS)
import UIKit
typealias CachedPlatformImage = UIImage
#endif

/// Large enough to look sharp at any width this editor actually draws
/// images at (including a full-width image on a Retina display), small
/// enough to be a fraction of most photos' native resolution. Matches the
/// max dimension already used when compressing photo-library uploads
/// (`AttachmentEditorSection.compressionMaxDimension`). File-scope rather
/// than a member of `AttachmentImageCache` so the nonisolated decode
/// function below can reference it without crossing actor isolation.
private let attachmentImageMaxPixelSize = 2048

/// Shared, app-lifetime cache of DOWNSAMPLED attachment images, decoded via
/// ImageIO's thumbnail API at a fixed, generous max pixel size — never at
/// the source image's full resolution. There was previously zero
/// downsampling anywhere in this app: a 12MP photo (~4032px) displayed at a
/// few hundred points was decoded (and re-resampled on every draw call) at
/// full resolution. This caps the decode itself instead.
///
/// Keyed by attachment id, not content checksum: attachments in this app
/// are immutable once created (content-addressed storage — only transfer
/// *state* changes afterward, via `AttachmentRepository.updateAttachmentState`,
/// never the bytes), so id-keying is safe and needs no checksum lookup.
///
/// Deliberately NOT a replacement for the per-Coordinator synchronous front
/// caches in `MarkdownSupport.swift` — `draw(_:)` needs those to stay a
/// zero-cost synchronous hit, exactly as documented there. This sits behind
/// them, reached only from their existing async load path, so switching
/// between entries (which discards the per-Coordinator cache) doesn't force
/// a full re-decode of images already seen this session.
@MainActor
final class AttachmentImageCache {
    static let shared = AttachmentImageCache()

    private final class Entry {
        let image: CachedPlatformImage
        init(_ image: CachedPlatformImage) { self.image = image }
    }

    private let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 96 * 1024 * 1024 // ~96MB of decoded RGBA pixels
        return cache
    }()

    private init() {}

    /// Synchronous lookup only — never decodes.
    func cachedImage(id: UUID) -> CachedPlatformImage? {
        cache.object(forKey: key(id))?.image
    }

    /// Decodes off the main actor (`Task.detached`, matching the pattern
    /// already used by `AppModel.addAttachment`) and stores the result.
    /// Safe to call repeatedly for the same id — a concurrent duplicate
    /// decode just overwrites the cache entry with an equivalent image; the
    /// callers in MarkdownSupport.swift already serialize this via their
    /// own `loadingAttachmentIDs` guard, so in practice it never races.
    func loadAndCache(id: UUID, data: Data) async -> CachedPlatformImage? {
        if let cached = cachedImage(id: id) { return cached }
        let task = Task.detached(priority: .userInitiated) {
            Self.downsample(data: data)
        }
        guard let decoded = await task.value else { return nil }
        cache.setObject(Entry(decoded.image), forKey: key(id), cost: decoded.cost)
        return decoded.image
    }

    private func key(_ id: UUID) -> NSString { id.uuidString as NSString }

    nonisolated private static func downsample(data: Data) -> ImageTransfer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: attachmentImageMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            )
        else { return nil }
        #if os(macOS)
        let image = CachedPlatformImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        #elseif os(iOS)
        let image = CachedPlatformImage(cgImage: cgImage)
        #endif
        return ImageTransfer(image: image, cost: cgImage.width * cgImage.height * 4)
    }
}

/// One-shot handoff out of a detached task — never mutated after creation,
/// so `@unchecked Sendable` is honest here (same pattern already used by
/// `AttachmentFileStore`). Not `private`: `loadAndCache`'s `Task.detached`
/// closure return type must be at least as visible as the method itself.
struct ImageTransfer: @unchecked Sendable {
    let image: CachedPlatformImage
    let cost: Int
}
