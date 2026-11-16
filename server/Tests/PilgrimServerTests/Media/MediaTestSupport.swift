import Foundation
import PilgrimAPI
import Vapor
import XCTVapor

@testable import PilgrimServerCore

// Fixtures and request helpers for the Media and Stickers tests (S6). Every module-scope name
// here starts with `TestJPEG` / `media` so it cannot collide with other tracks' helpers.

/// Synthetic JPEG files: the marker structure of a real file (SOI, APPn, DQT, SOF, DHT, SOS,
/// entropy-coded data with stuffing and restart markers, EOI) without real image data. The
/// server never decodes pixels, so structure is all its checks see.
enum TestJPEG {
    static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = payload.count + 2
        return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }

    static let soi: [UInt8] = [0xFF, 0xD8]
    static let eoi: [UInt8] = [0xFF, 0xD9]

    static let jfif = segment(0xE0, Array("JFIF\0".utf8) + [1, 1, 0, 0, 1, 0, 1, 0, 0])
    static let exifWithGPS = segment(
        0xE1, Array("Exif\0\0".utf8) + Array("GPSLatitude 37.5665 GPSLongitude 126.9780".utf8))
    static let xmp = segment(
        0xE1, Array("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>Creator</x:xmpmeta>".utf8))
    static let icc = segment(
        0xE2, Array("ICC_PROFILE\0".utf8) + [1, 1] + Array(repeating: 0x42, count: 16))
    static let mpf = segment(0xE2, Array("MPF\0".utf8) + [0x4D, 0x4D, 0, 0x2A])
    static let iptc = segment(0xED, Array("Photoshop 3.0\0".utf8) + Array("8BIM City Seoul".utf8))
    static let app15 = segment(0xEF, Array("vendor".utf8))
    static let comment = segment(0xFE, Array("Shot on a phone".utf8))
    static let dqt = segment(0xDB, [0x00] + Array(repeating: 1, count: 64))
    static let dht = segment(0xC4, [0x00, 1] + Array(repeating: 0, count: 15) + [0])
    static let sos = segment(0xDA, [1, 1, 0x00, 0, 63, 0])
    /// Entropy-coded bytes with `FF 00` stuffing and an `RST0` marker.
    static let scanData: [UInt8] = [0x12, 0x34, 0xFF, 0x00, 0x56, 0xFF, 0xD0, 0x78, 0x9A]

    static func sof(_ marker: UInt8 = 0xC0, width: Int, height: Int) -> [UInt8] {
        segment(
            marker,
            [
                8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF),
                1,
            ]
                + [1, 0x11, 0])
    }

    /// Every metadata segment the server must remove.
    static var metadataSegments: [UInt8] {
        exifWithGPS + xmp + mpf + iptc + app15 + comment
    }

    /// A baseline JPEG of `width` × `height`. With `metadata`, EXIF (GPS), XMP, MPF, IPTC, APP15
    /// and COM segments are mixed in and a trailer follows EOI. `scanPadding` adds that many
    /// entropy-coded bytes to reach a file size.
    static func make(
        width: Int = 800, height: Int = 600, metadata: Bool = false, scanPadding: Int = 0
    ) -> Data {
        var bytes = soi + jfif
        if metadata { bytes += exifWithGPS + xmp }
        bytes += icc
        if metadata { bytes += mpf + iptc + app15 + comment }
        bytes += dqt + sof(width: width, height: height) + dht + sos + scanData
        bytes += [UInt8](repeating: 0x11, count: scanPadding)
        bytes += eoi
        if metadata { bytes += Array("TRAILER-THUMBNAIL".utf8) }
        return Data(bytes)
    }

    /// What `make(width:height:metadata: true, scanPadding:)` must become.
    static func stripped(width: Int = 800, height: Int = 600, scanPadding: Int = 0) -> Data {
        make(width: width, height: height, metadata: false, scanPadding: scanPadding)
    }

    /// A file of exactly `byteCount` bytes (at least the size of an unpadded `make`).
    static func make(width: Int, height: Int, byteCount: Int) -> Data {
        let base = make(width: width, height: height).count
        precondition(byteCount >= base)
        return make(width: width, height: height, scanPadding: byteCount - base)
    }
}

extension ServerTestCase {
    /// `POST /api/v1/uploads` as multipart form data. `groupID` nil leaves the field out.
    func mediaUpload(
        _ purpose: String, groupID: UUID?, as user: User?, jpeg: Data, clientID: UUID = UUID(),
        partContentType: String? = "image/jpeg", file: StaticString = #filePath, line: UInt = #line
    ) async throws -> XCTHTTPResponse {
        let boundary = "pilgrim-test-\(UUID().uuidString)"
        let body = mediaMultipartBody(
            boundary: boundary, purpose: purpose, groupID: groupID, jpeg: jpeg,
            clientID: clientID, partContentType: partContentType)

        var headers = try headers(as: user)
        headers.contentType = HTTPMediaType(
            type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
        let request = XCTHTTPRequest(
            method: .POST, url: URI(string: "/api/v1/uploads"), headers: headers,
            body: ByteBuffer(data: body))
        do {
            return try await app.testable().performTest(request: request)
        } catch {
            XCTFail("upload: \(error)", file: file, line: line)
            throw error
        }
    }

    /// `GET` of a signed media file URL (path and query only; no client header).
    func mediaFetch(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws
        -> XCTHTTPResponse
    {
        let target = url.query.map { "\(url.path)?\($0)" } ?? url.path
        let request = XCTHTTPRequest(
            method: .GET, url: URI(string: target), headers: HTTPHeaders(),
            body: ByteBufferAllocator().buffer(capacity: 0))
        do {
            return try await app.testable().performTest(request: request)
        } catch {
            XCTFail("GET \(target): \(error)", file: file, line: line)
            throw error
        }
    }
}

/// A `POST /uploads` multipart body, laid out like the app's `GroupMediaUploader`.
func mediaMultipartBody(
    boundary: String, purpose: String, groupID: UUID?, jpeg: Data, clientID: UUID,
    partContentType: String?
) -> Data {
    var body = Data()
    func field(_ name: String, _ value: String) {
        body += Data("--\(boundary)\r\n".utf8)
        body += Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
        body += Data("\(value)\r\n".utf8)
    }
    field(UploadFormField.purpose, purpose)
    field(UploadFormField.clientID, clientID.uuidString.lowercased())
    if let groupID { field(UploadFormField.groupID, groupID.uuidString.lowercased()) }
    body += Data("--\(boundary)\r\n".utf8)
    body += Data(
        "Content-Disposition: form-data; name=\"\(UploadFormField.file)\"; filename=\"photo.jpg\"\r\n"
            .utf8)
    if let partContentType { body += Data("Content-Type: \(partContentType)\r\n".utf8) }
    body += Data("\r\n".utf8)
    body += jpeg
    body += Data("\r\n--\(boundary)--\r\n".utf8)
    return body
}

/// The `APIError` `body` throws, or nil (and a test failure) when it throws something else.
func mediaThrownAPIError(
    file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void
) -> APIError? {
    do {
        try body()
        XCTFail("expected an APIError", file: file, line: line)
    } catch let error as APIError {
        return error
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
    return nil
}
