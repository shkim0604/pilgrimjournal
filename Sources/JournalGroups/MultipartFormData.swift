import Foundation

/// A `multipart/form-data` body (RFC 7578) with CRLF line breaks.
public struct MultipartFormData: Equatable, Sendable {
    public let boundary: String
    public private(set) var body = Data()
    private var isFinished = false

    public init(boundary: String = MultipartFormData.makeBoundary()) {
        self.boundary = boundary
    }

    /// `multipart/form-data; boundary=<boundary>`.
    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public static func makeBoundary() -> String {
        "pilgrim-\(UUID().uuidString.lowercased())"
    }

    public mutating func addField(name: String, value: String) {
        precondition(!isFinished, "MultipartFormData is already finished")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(Self.quoted(name))\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    public mutating func addFile(name: String, fileName: String, contentType: String, data: Data) {
        precondition(!isFinished, "MultipartFormData is already finished")
        append("--\(boundary)\r\n")
        append(
            "Content-Disposition: form-data; name=\"\(Self.quoted(name))\"; "
                + "filename=\"\(Self.quoted(fileName))\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    /// Appends the closing boundary. Call once, after the last part.
    public mutating func finish() {
        guard !isFinished else { return }
        append("--\(boundary)--\r\n")
        isFinished = true
    }

    private mutating func append(_ text: String) {
        body.append(Data(text.utf8))
    }

    /// Field and file names are ASCII here; escape the two characters that would break the
    /// quoted header value anyway.
    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
