import Foundation
import Vapor

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// `PilgrimServer worker`: runs every registered `WorkerJob` until SIGINT or SIGTERM
/// (`docker compose stop`). Same image and configuration as `serve`.
struct WorkerCommand: AsyncCommand {
    struct Signature: CommandSignature {}

    var help: String { "Runs the background loops (expiry, push, votes, reports, ...)." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let jobs = app.workerJobs.jobs
        let runner = WorkerRunner(application: app)
        let task = Task { await runner.run(jobs: jobs) }

        let signalQueue = DispatchQueue(label: "pilgrim.worker.signals")
        var sources: [any DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: signalQueue)
            source.setEventHandler {
                app.logger.info("worker received signal \(signalNumber), stopping")
                task.cancel()
            }
            source.resume()
            sources.append(source)
        }
        await task.value
        sources.forEach { $0.cancel() }
    }
}
