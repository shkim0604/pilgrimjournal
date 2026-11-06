import Foundation

/// A single prayer topic (기도제목) inside a prayer-note entry.
///
/// Stored as part of `EntryDetails`, so it rides inside the entry's `detailsData` JSON blob:
/// no CloudKit schema field is added, and revisions/backups/kind-moves cover it automatically.
/// All fields except `id`/`text`/`status` are optional so that older blobs (and future blobs
/// with extra keys, e.g. a deadline) keep decoding.
public struct PrayerTopic: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var status: PrayerStatus
    public var memo: String?
    public var answeredAt: Date?
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        text: String,
        status: PrayerStatus = .ongoing,
        memo: String? = nil,
        answeredAt: Date? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.memo = memo
        self.answeredAt = answeredAt
        self.createdAt = createdAt
    }
}
