import Foundation
import os

/// Debug-only stage timings for the group posting path (`log stream --predicate
/// 'category == "group-timing"'`). Logs a stage name and milliseconds; never content, IDs or
/// tokens. Release builds compile it to nothing.
public enum GroupTiming {
    #if DEBUG
    private static let logger = Logger(
        subsystem: "com.dhouse.PilgrimJournal", category: "group-timing")
    #endif

    public static var now: ContinuousClock.Instant { ContinuousClock.now }

    public static func log(
        _ stage: String, since start: ContinuousClock.Instant, server: String? = nil
    ) {
        log(stage, ContinuousClock.now - start, server: server)
    }

    public static func log(_ stage: String, _ elapsed: Duration, server: String? = nil) {
        #if DEBUG
        let ms = Int(
            Double(elapsed.components.seconds) * 1_000
                + Double(elapsed.components.attoseconds) / 1e15)
        let serverPart = server.map { " server=\($0)" } ?? ""
        logger.notice(
            "\(stage, privacy: .public) \(ms, privacy: .public)ms\(serverPart, privacy: .public)")
        #endif
    }

    /// `["groups", "<uuid>", "posts"]` → `groups/:id/posts`.
    static func route(_ path: [String]) -> String {
        path.map { UUID(uuidString: $0) == nil && Int($0) == nil ? $0 : ":id" }
            .joined(separator: "/")
    }

    /// The `dur` of a `Server-Timing: app;dur=12.3` header, as text.
    static func serverDuration(_ header: String?) -> String? {
        guard let header, let range = header.range(of: "dur=") else { return nil }
        return String(header[range.upperBound...].prefix { $0 != "," && $0 != ";" }) + "ms"
    }
}
