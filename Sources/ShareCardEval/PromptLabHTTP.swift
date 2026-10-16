import Foundation

// The prompt lab's wire format and a minimal HTTP/1.1 parser, kept free of FoundationModels
// so they build and test everywhere.

struct LabDiary: Codable, Sendable {
    /// A fixture id, or nil for a diary typed into the page (never logged).
    var id: String?
    var title: String
    var date: String
    var body: String
    var names: [String]?
}

struct LabRunRequest: Codable, Sendable {
    var instructions: String
    var template: String
    var greedy: Bool?
    var diary: LabDiary
}

struct LabRunResult: Codable, Sendable {
    let text: String?
    let lines: [String]
    let seconds: Double
    let outcome: String
    let leakedNames: [String]
    /// Instructions plus the filled prompt, so people see how close they are to the ~4K
    /// token context.
    let promptCharacters: Int
}

struct LabDiarySummary: Codable, Sendable {
    let id: String
    let title: String
    let date: String
    let body: String
    let points: [String]
    let names: [String]
}

struct LabState: Codable, Sendable {
    let instructions: String
    let template: String
    let promptVersion: String
    let diaries: [LabDiarySummary]

    static var current: LabState {
        LabState(
            instructions: SharePrompts.prayerRequestInstructions,
            template: SharePrompts.prayerRequestTemplate,
            promptVersion: SharePrompts.prayerRequestVersion,
            diaries: PrayerDiaryFixtures.all.map {
                LabDiarySummary(
                    id: $0.id, title: $0.title, date: $0.date.description, body: $0.body,
                    points: $0.points, names: $0.names)
            }
        )
    }
}

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Parses one complete request from `buffer`, or returns nil while headers or the
    /// `Content-Length` body are still incomplete.
    init?(parsing buffer: Data) {
        guard let headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8)),
            let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        method = String(requestLine[0])
        path = String(requestLine[1])
        self.headers = headers
        body = buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)]
    }

    /// A browser page from another site may not drive the local model: requests that carry an
    /// `Origin` must come from the lab itself.
    func isSameOrigin(port: UInt16) -> Bool {
        guard let origin = headers["origin"] else { return true }
        return origin == "http://localhost:\(port)" || origin == "http://127.0.0.1:\(port)"
    }
}

enum HTTPResponse {
    static func make(status: Int, contentType: String, body: Data) -> Data {
        let reason =
            [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found"][status] ?? ""
        let head = """
            HTTP/1.1 \(status) \(reason)\r
            Content-Type: \(contentType)\r
            Content-Length: \(body.count)\r
            Cache-Control: no-store\r
            Connection: close\r
            \r

            """
        return Data(head.utf8) + body
    }

    static func json(_ value: some Encodable) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return make(status: 200, contentType: "application/json; charset=utf-8", body: body)
    }

    static func error(_ status: Int, _ message: String) -> Data {
        make(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }
}
