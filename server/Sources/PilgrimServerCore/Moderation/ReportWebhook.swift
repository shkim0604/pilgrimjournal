import Foundation
import NIOCore
import PilgrimAPI
import Vapor

/// What the report webhook learns about a new report: the reason and the target type, nothing
/// else (design.md 14절 — no body, no names, no IDs).
public struct ReportWebhookSummary: Equatable, Sendable, Codable {
    public var reason: ReportReason
    public var targetType: ReportTargetType

    public init(reason: ReportReason, targetType: ReportTargetType) {
        self.reason = reason
        self.targetType = targetType
    }

    /// `새 신고 <reason> (<targetType>)`.
    public var text: String { "새 신고 \(reason.rawValue) (\(targetType.rawValue))" }

    /// The JSON body: `{ "text": "…" }`.
    public var payload: [String: String] { ["text": text] }
}

/// Tells the operator about a new report. Must not block or fail the request.
public protocol ReportNotifying: Sendable {
    func reportFiled(_ summary: ReportWebhookSummary, app: Application)
}

/// POSTs `ReportWebhookSummary.payload` to `REPORT_WEBHOOK_URL` in the background. Does
/// nothing when the URL is unset. Failures are logged, never surfaced to the reporter.
public struct WebhookReportNotifier: ReportNotifying {
    public static let timeout: TimeAmount = .seconds(10)

    public init() {}

    public func reportFiled(_ summary: ReportWebhookSummary, app: Application) {
        guard let url = app.pilgrimConfig.reportWebhookURL else { return }
        let client = app.client
        let logger = app.logger
        let payload = summary.payload
        Task {
            do {
                let response = try await client.post(URI(string: url.absoluteString)) { request in
                    request.timeout = Self.timeout
                    try request.content.encode(payload, as: .json)
                }
                if !(200..<300).contains(response.status.code) {
                    logger.warning(
                        "report webhook answered \(response.status.code)",
                        metadata: ["targetType": .string(summary.targetType.rawValue)])
                }
            } catch {
                logger.warning(
                    "report webhook failed: \(String(describing: error))",
                    metadata: ["targetType": .string(summary.targetType.rawValue)])
            }
        }
    }
}

extension Application {
    private struct ReportNotifierKey: StorageKey {
        typealias Value = any ReportNotifying
    }

    /// How new reports reach the operator. Tests may replace it after `configure`.
    public var reportNotifier: any ReportNotifying {
        get { storage[ReportNotifierKey.self] ?? WebhookReportNotifier() }
        set { storage[ReportNotifierKey.self] = newValue }
    }
}
