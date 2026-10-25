#if canImport(FoundationModels)
import Foundation
import FoundationModels
import Network

/// `swift run ShareCardEval --serve`: a page on this Mac where people edit the
/// diary → prayer request prompt and run it on the on-device model themselves. It listens on
/// the loopback interface only, so diaries typed into it never leave the machine.
@available(macOS 26, iOS 26, *)
@MainActor
final class PromptLabServer {
    private let pipeline: SharePipeline
    private let page: Data
    private let port: UInt16
    private let logURL: URL?
    private var listener: NWListener?

    init(pipeline: SharePipeline, page: Data, port: UInt16, logDirectory: String?) {
        self.pipeline = pipeline
        self.page = page
        self.port = port
        logURL = logDirectory.map {
            URL(fileURLWithPath: $0).appendingPathComponent("lab-runs.jsonl")
        }
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
        if let logURL {
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(parsing: buffer) {
                    let response = await self.respond(to: request)
                    connection.send(
                        content: response,
                        completion: .contentProcessed { _ in connection.cancel() })
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest) async -> Data {
        guard request.isSameOrigin(port: port) else {
            return HTTPResponse.error(403, "다른 사이트에서 온 요청은 받지 않습니다.")
        }
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return HTTPResponse.make(
                status: 200, contentType: "text/html; charset=utf-8", body: page)
        case ("GET", "/api/state"):
            return HTTPResponse.json(LabState.current)
        case ("POST", "/api/run"):
            guard let run = try? JSONDecoder().decode(LabRunRequest.self, from: request.body) else {
                return HTTPResponse.error(400, "요청 형식이 맞지 않습니다.")
            }
            return HTTPResponse.json(await self.run(run))
        default:
            return HTTPResponse.error(404, "없는 주소입니다.")
        }
    }

    private func run(_ request: LabRunRequest) async -> LabRunResult {
        let diary = request.diary
        let entry = EvalEntry(
            id: diary.id ?? "custom", kind: .diary,
            date: DayDate(iso: diary.date) ?? EvalFixtures.defaultDate, title: diary.title,
            body: diary.body, expected: Expected())
        let prompt = SharePrompts.fill(request.template, with: entry)
        let (text, call) = await pipeline.draft(
            instructions: request.instructions, prompt: prompt, greedy: request.greedy ?? true)
        let result = LabRunResult(
            text: text,
            lines: text.map(SharePrompts.requestLines) ?? [],
            seconds: call.seconds,
            outcome: call.outcome,
            leakedNames: EvalScorer.nameLeaks(diary.names ?? [], in: ["text": text ?? ""]),
            promptCharacters: request.instructions.count + prompt.count
        )
        log(request, result)
        return result
    }

    /// Appends fixture runs to `--log-dir` so prompt experiments can be read back later.
    /// A diary typed into the page is recorded only as "custom", never its text or output.
    private func log(_ request: LabRunRequest, _ result: LabRunResult) {
        guard let logURL else { return }
        let record: [String: Any]
        if let id = request.diary.id {
            record = [
                "at": ISO8601DateFormatter().string(from: Date()), "diary": id,
                "instructions": request.instructions, "template": request.template,
                "greedy": request.greedy ?? true, "text": result.text ?? NSNull(),
                "seconds": result.seconds, "outcome": result.outcome,
            ]
        } else {
            record = ["at": ISO8601DateFormatter().string(from: Date()), "diary": "custom"]
        }
        guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: logURL)
        }
    }
}
#endif
