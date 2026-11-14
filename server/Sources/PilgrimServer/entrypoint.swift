import Foundation
import Logging
import PilgrimServerCore
import Vapor

/// `PilgrimServer serve | worker | migrate [--yes] | migrate --revert`.
@main
enum Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = try await Application.make(env)
        do {
            try await configure(app)
            try await app.execute()
        } catch {
            // Configuration errors (for example dev login with APP_ENV=production) end here:
            // log one line and exit non-zero instead of crashing with a backtrace.
            app.logger.critical("\(String(describing: error))")
            try? await app.asyncShutdown()
            exit(1)
        }
        try await app.asyncShutdown()
    }
}
