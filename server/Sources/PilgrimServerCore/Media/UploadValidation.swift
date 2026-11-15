import Foundation
import PilgrimAPI
import Vapor

/// The fields of a `POST /uploads` multipart body (`PilgrimAPI.UploadFormField`). Everything but
/// the file is read as text so a bad value gets a precise 422 instead of a decoding 400.
struct UploadForm: Decodable {
    var purpose: String
    var clientId: String
    var groupId: String?
    var file: UploadFilePart
}

/// The `file` part with the `Content-Type` its own part header declares. (Vapor's `File` only
/// keeps the file name and guesses the type from its extension.)
struct UploadFilePart: Decodable, MultipartPartConvertible {
    var data: ByteBuffer
    var contentType: HTTPMediaType?

    init(data: ByteBuffer, contentType: HTTPMediaType?) {
        self.data = data
        self.contentType = contentType
    }

    init?(multipart: MultipartPart) {
        self.init(data: multipart.body, contentType: multipart.headers.contentType)
    }

    /// Never sent back as multipart.
    var multipart: MultipartPart? { nil }

    /// Reached only when the value is not a multipart part (another content type).
    init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(
            .init(
                codingPath: decoder.codingPath,
                debugDescription: "file must be a multipart/form-data file part"))
    }
}

/// A parsed upload request, before the file is looked at.
struct UploadFields: Equatable, Sendable {
    var purpose: MediaPurpose
    var clientID: UUID
    /// nil for `profile` (a profile photo belongs to no group, even when one is sent).
    var groupID: UUID?

    static func parse(purpose: String, clientId: String, groupId: String?) throws -> UploadFields {
        guard let parsedPurpose = MediaPurpose(rawValue: purpose) else {
            throw APIError.validationFailed(
                field: UploadFormField.purpose, "purpose must be post, comment, profile or sticker")
        }
        guard let clientID = UUID(uuidString: clientId.trimmingCharacters(in: .whitespaces)) else {
            throw APIError.validationFailed(
                field: UploadFormField.clientID, "clientId must be a UUID")
        }
        if parsedPurpose == .profile {
            return UploadFields(purpose: parsedPurpose, clientID: clientID, groupID: nil)
        }
        let groupText = groupId?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !groupText.isEmpty else {
            throw APIError.validationFailed(
                field: UploadFormField.groupID, "groupId is required for \(purpose) photos")
        }
        guard let groupID = UUID(uuidString: groupText) else {
            throw APIError.validationFailed(
                field: UploadFormField.groupID, "groupId must be a UUID")
        }
        return UploadFields(purpose: parsedPurpose, clientID: clientID, groupID: groupID)
    }
}

/// The server's photo check (design.md 7절, `PhotoLimits`): the part is declared `image/jpeg`, the
/// bytes are a well-formed JPEG, the size read from SOF fits the purpose (post · comment · profile:
/// long edge ≤ 1600; sticker: exactly 256 × 256), and the file fits the purpose's byte limit
/// (500KB / 100KB). Metadata is removed on the way (`JPEGSanitizer`).
///
/// Wrong type, structure or dimensions are 422 `MEDIA_INVALID`; too many bytes is 413
/// `MEDIA_TOO_LARGE` with the limit. The byte limit applies to the file as uploaded, so a file
/// is never accepted only because its metadata was large enough to strip it under the limit.
enum UploadValidation {
    static func validate(purpose: MediaPurpose, contentType: HTTPMediaType?, data: Data) throws
        -> SanitizedJPEG
    {
        guard let contentType, contentType.type == "image", contentType.subType == "jpeg" else {
            throw invalid("the file part must be image/jpeg")
        }
        let limit = PhotoLimits.maxBytes(for: purpose)
        if data.count > limit { throw tooLarge(limit: limit) }
        guard PhotoLimits.hasJPEGSignature(data) else {
            throw invalid("the file is not a JPEG")
        }
        let image: SanitizedJPEG
        do {
            image = try JPEGSanitizer.sanitize(data)
        } catch {
            throw invalid("the JPEG is malformed (\(error))")
        }
        do {
            try PhotoLimits.validate(
                purpose: purpose, width: image.width, height: image.height,
                byteCount: image.data.count)
        } catch {
            switch error {
            case .tooLarge(let limit): throw tooLarge(limit: limit)
            case .invalidDimensions:
                throw invalid(
                    "\(image.width)x\(image.height) is outside the \(purpose.rawValue) limits")
            }
        }
        return image
    }

    private static func invalid(_ message: String) -> APIError {
        APIError(code: .mediaInvalid, message: message, field: UploadFormField.file)
    }

    private static func tooLarge(limit: Int) -> APIError {
        APIError(
            code: .mediaTooLarge, message: "the file is larger than \(limit) bytes",
            field: UploadFormField.file, limit: limit)
    }
}
