#if canImport(XCTest)
import CoreGraphics
import Foundation
import ImageIO
@testable import PilgrimJournal
import XCTest

final class AttachmentImageCacheTests: XCTestCase {
    private func makeTestPNGData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    @MainActor
    func testLoadAndCacheDecodesAndIsRetrievableSynchronouslyAfter() async throws {
        let id = UUID()
        XCTAssertNil(AttachmentImageCache.shared.cachedImage(id: id))

        let data = makeTestPNGData(width: 120, height: 90)
        let decoded = await AttachmentImageCache.shared.loadAndCache(id: id, data: data)
        let loaded = try XCTUnwrap(decoded)

        XCTAssertEqual(loaded.size.width, 120)
        XCTAssertEqual(loaded.size.height, 90)
        // The whole point: a synchronous lookup after the async decode
        // completes must hit, without decoding again.
        XCTAssertNotNil(AttachmentImageCache.shared.cachedImage(id: id))
    }

    @MainActor
    func testLoadAndCacheReturnsNilAndCachesNothingForUndecodableData() async {
        let id = UUID()
        let image = await AttachmentImageCache.shared.loadAndCache(
            id: id, data: Data("not an image".utf8)
        )

        XCTAssertNil(image)
        XCTAssertNil(AttachmentImageCache.shared.cachedImage(id: id))
    }

    @MainActor
    func testDifferentAttachmentIDsAreCachedIndependently() async throws {
        let firstID = UUID()
        let secondID = UUID()
        let decoded = await AttachmentImageCache.shared.loadAndCache(
            id: firstID, data: makeTestPNGData(width: 40, height: 40)
        )
        _ = try XCTUnwrap(decoded)

        // A lookup for an id that was never loaded must never spuriously hit.
        XCTAssertNil(AttachmentImageCache.shared.cachedImage(id: secondID))
    }
}
#endif
