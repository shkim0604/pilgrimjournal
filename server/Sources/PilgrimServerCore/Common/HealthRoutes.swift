import Fluent
import Foundation
import PilgrimAPI
import SQLKit
import Vapor

/// `GET /api/health` (outside v1, no client header, no auth; spec "공개 경로와 터널 경계").
///
/// - Database unreachable → 503, `status: degraded`, `database: false`.
/// - Database fine but a worker loop has not beaten for `WorkerHealth.staleAfter` → 200,
///   `status: degraded`, `worker.healthy: false`.
enum HealthRoutes {
    static func register(_ app: Application) {
        app.get("api", "health") { req async -> Response in
            let report = await check(req)
            let status: HTTPResponseStatus = report.database ? .ok : .serviceUnavailable
            do {
                var headers = HTTPHeaders()
                headers.contentType = .json
                headers.replaceOrAdd(name: .cacheControl, value: "no-store")
                return Response(
                    status: status, headers: headers,
                    body: .init(data: try PilgrimJSON.encode(report)))
            } catch {
                return Response(status: .internalServerError)
            }
        }
    }

    private struct BeatRow: Decodable {
        var loop: String
        var lastBeatAt: Date

        enum CodingKeys: String, CodingKey {
            case loop
            case lastBeatAt = "last_beat_at"
        }
    }

    static func check(_ req: Request, now: Date = Date()) async -> HealthResponse {
        let version = req.pilgrimConfig.version
        let expected = Set(req.application.workerJobs.names)
        let beats: [BeatRow]
        do {
            guard let sql = req.db as? any SQLDatabase else { throw Abort(.internalServerError) }
            beats = try await sql.raw("SELECT loop, last_beat_at FROM worker_heartbeat")
                .all(decoding: BeatRow.self)
        } catch {
            req.logger.warning("health: database check failed: \(String(describing: error))")
            return HealthResponse(
                status: .degraded, database: false,
                worker: WorkerHealth(lastBeatAt: nil, healthy: false), version: version)
        }
        let worker = workerHealth(expected: expected, beats: beats, now: now)
        return HealthResponse(
            status: worker.healthy ? .ok : .degraded, database: true, worker: worker,
            version: version)
    }

    /// Healthy when every registered loop beat within `staleAfter`. `lastBeatAt` is the oldest
    /// of those beats (nil when a loop never beat).
    private static func workerHealth(expected: Set<String>, beats: [BeatRow], now: Date)
        -> WorkerHealth
    {
        let latest = Dictionary(
            beats.map { ($0.loop, $0.lastBeatAt) }, uniquingKeysWith: { max($0, $1) })
        guard !expected.isEmpty else { return WorkerHealth(lastBeatAt: nil, healthy: false) }
        let expectedBeats = expected.map { latest[$0] }
        if expectedBeats.contains(where: { $0 == nil }) {
            return WorkerHealth(lastBeatAt: nil, healthy: false)
        }
        let oldest = expectedBeats.compactMap { $0 }.min()!
        return WorkerHealth(
            lastBeatAt: oldest,
            healthy: now.timeIntervalSince(oldest) <= WorkerHealth.staleAfter)
    }
}
