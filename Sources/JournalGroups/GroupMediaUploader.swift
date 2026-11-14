import Foundation
import PilgrimAPI

/// Compresses a picked image and uploads it (`POST /uploads`, design.md 7절).
///
/// The multipart body has the fields `purpose`, `clientId`, `groupId` (all but profile
/// photos) and `file` (`image/jpeg`). Width and height are not sent: the server reads them
/// from the JPEG itself.
public struct GroupMediaUploader: Sendable {
    public let api: any GroupAPI

    public init(api: any GroupAPI) {
        self.api = api
    }

    /// Compresses `imageData` for `purpose` and uploads it. Reuse `clientID` when retrying
    /// the same picked image so the server returns the first upload instead of a new one.
    public func upload(
        imageData: Data, purpose: MediaPurpose, groupID: UUID?, clientID: UUID = UUID()
    ) async throws -> MediaRef {
        let compressed = try ImageCompressor.compress(imageData, for: purpose)
        if Task.isCancelled { throw GroupAPIError.cancelled }
        return try await api.upload(
            compressed.upload(purpose: purpose, groupID: groupID, clientID: clientID))
    }

    /// The `POST /uploads` body for an already compressed JPEG.
    public static func multipartForm(
        for upload: GroupMediaUpload, boundary: String = MultipartFormData.makeBoundary()
    ) -> MultipartFormData {
        var form = MultipartFormData(boundary: boundary)
        form.addField(name: UploadFormField.purpose, value: upload.purpose.rawValue)
        form.addField(name: UploadFormField.clientID, value: upload.clientID.pilgrimString)
        if let groupID = upload.groupID {
            form.addField(name: UploadFormField.groupID, value: groupID.pilgrimString)
        }
        form.addFile(
            name: UploadFormField.file, fileName: "\(upload.clientID.pilgrimString).jpg",
            contentType: PhotoLimits.contentType, data: upload.jpegData)
        form.finish()
        return form
    }
}

extension CompressedImage {
    /// The upload for this JPEG.
    public func upload(purpose: MediaPurpose, groupID: UUID?, clientID: UUID = UUID())
        -> GroupMediaUpload
    {
        GroupMediaUpload(
            clientID: clientID, purpose: purpose, groupID: purpose == .profile ? nil : groupID,
            jpegData: data, width: width, height: height)
    }
}
