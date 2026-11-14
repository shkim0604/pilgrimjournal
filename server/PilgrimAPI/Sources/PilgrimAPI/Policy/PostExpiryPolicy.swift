import Foundation

/// When a group post disappears (design.md 4절).
///
/// | kind | `expiresAt` |
/// | --- | --- |
/// | prayer with deadline D | midnight after D + 3 days in the poster's zone = `startOfDay(D + 4)` |
/// | prayer without deadline | `createdAt + visibleDays` (3, 7, 14, 30; default 7) |
/// | book report | `createdAt + 7 days`; each extension adds 7 days to the current value |
/// | testimony | `createdAt + 7 days` |
///
/// `dayLength` is `TIME_SCALE_DAY_SECONDS`. At the real 86 400 seconds a deadline ends at local
/// midnight (DST-correct). In scaled mode (anything else) a deadline post lasts
/// `(calendar days from today to D + 4) × dayLength` from `createdAt`.
public struct PostExpiryPolicy: Sendable {
    public static let realDayLength: TimeInterval = 86_400
    public static let allowedVisibleDays: [Int] = [3, 7, 14, 30]
    public static let defaultVisibleDays = 7
    /// Book reports and testimonies.
    public static let fixedLifetimeDays = 7
    /// Days added by one book-report extension.
    public static let extensionDays = 7
    /// Days a deadline post stays after the deadline day ends.
    public static let daysAfterDeadline = 3
    public static let maxDeadlineDaysAhead = APILimits.deadlineMaxDaysAhead

    public let dayLength: TimeInterval

    public init(dayLength: TimeInterval = 86_400) {
        precondition(dayLength > 0, "dayLength must be positive")
        self.dayLength = dayLength
    }

    public var isScaled: Bool { dayLength != Self.realDayLength }

    /// The expiry of a new post. Throws `PostExpiryError` for a request the server answers with
    /// 422 `VALIDATION_FAILED` (`error.field`).
    public func expiresAt(
        kind: PostKind, createdAt: Date, deadline: LocalDate?, visibleDays: Int?,
        timeZone: TimeZone
    ) throws -> Date {
        switch kind {
        case .prayer:
            if let deadline {
                guard visibleDays == nil else { throw PostExpiryError.deadlineWithVisibleDays }
                try validateDeadline(deadline, now: createdAt, timeZone: timeZone)
                if isScaled {
                    let today = LocalDate(createdAt, in: timeZone)
                    let days = today.days(until: deadline) + Self.daysAfterDeadline + 1
                    return createdAt + Double(days) * dayLength
                }
                return deadline.adding(days: Self.daysAfterDeadline + 1).startOfDay(in: timeZone)
            }
            let days = visibleDays ?? Self.defaultVisibleDays
            guard Self.allowedVisibleDays.contains(days) else {
                throw PostExpiryError.invalidVisibleDays(days)
            }
            return createdAt + Double(days) * dayLength
        case .bookReport, .testimony:
            if deadline != nil { throw PostExpiryError.deadlineNotAllowed }
            if visibleDays != nil { throw PostExpiryError.visibleDaysNotAllowed }
            return createdAt + Double(Self.fixedLifetimeDays) * dayLength
        }
    }

    /// A book report's expiry after one more discussion extension.
    public func extended(_ expiresAt: Date) -> Date {
        expiresAt + Double(Self.extensionDays) * dayLength
    }

    /// A deadline must be today … today + 365 days in the poster's time zone.
    public func validateDeadline(_ deadline: LocalDate, now: Date, timeZone: TimeZone) throws {
        let today = LocalDate(now, in: timeZone)
        if deadline < today { throw PostExpiryError.deadlineInPast }
        if today.days(until: deadline) > Self.maxDeadlineDaysAhead {
            throw PostExpiryError.deadlineTooFar
        }
    }
}

public enum PostExpiryError: Error, Equatable, Sendable {
    case deadlineInPast
    case deadlineTooFar
    /// Only prayer posts take a deadline.
    case deadlineNotAllowed
    /// Only prayer posts take `visibleDays`.
    case visibleDaysNotAllowed
    /// A deadline and `visibleDays` together.
    case deadlineWithVisibleDays
    case invalidVisibleDays(Int)

    /// The request field the server names in its 422 response.
    public var field: String {
        switch self {
        case .deadlineInPast, .deadlineTooFar, .deadlineNotAllowed: "deadline"
        case .visibleDaysNotAllowed, .deadlineWithVisibleDays, .invalidVisibleDays: "visibleDays"
        }
    }

    public var apiError: APIError {
        APIError(code: .validationFailed, message: message, field: field)
    }

    private var message: String {
        switch self {
        case .deadlineInPast: "deadline is before today in the post's time zone"
        case .deadlineTooFar: "deadline is more than 365 days ahead"
        case .deadlineNotAllowed: "only prayer posts take a deadline"
        case .visibleDaysNotAllowed: "only prayer posts take visibleDays"
        case .deadlineWithVisibleDays: "send either deadline or visibleDays, not both"
        case .invalidVisibleDays(let days): "visibleDays \(days) is not one of 3, 7, 14, 30"
        }
    }
}
