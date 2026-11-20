import Vapor

/// Adds `Server-Timing: app;dur=<ms>` to every response, so a client can tell server time from
/// network time (the tunnel round trip) without reading server logs. Only a duration: no route,
/// IDs or content.
public struct ServerTimingMiddleware: AsyncMiddleware {
    public init() {}

    public func respond(to request: Request, chainingTo next: any AsyncResponder) async throws
        -> Response
    {
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await next.respond(to: request)
        let elapsed = start.duration(to: clock.now)
        let ms =
            Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1_000
        response.headers.replaceOrAdd(
            name: "Server-Timing", value: "app;dur=\(String(format: "%.1f", ms))")
        return response
    }
}
