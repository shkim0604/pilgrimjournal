import Foundation
import PilgrimAPI

/// Signed media URLs by media ID (design.md 7절). Every `MediaRef` in a response carries a URL
/// that lives 10 minutes; this keeps the newest one per ID and asks `GET /media/:id` for a
/// fresh one only when it is about to expire (one request per ID even with many callers).
/// The file behind an ID never changes, so image caches can key on the ID, not the URL.
public actor GroupMediaURLCache {
    private struct Entry {
        var url: URL
        var expiresAt: Date
    }

    private let api: any GroupAPI
    private let now: @Sendable () -> Date
    private let margin: TimeInterval
    private var entries: [UUID: Entry] = [:]
    private var inFlight: [UUID: Task<MediaURLResponse, any Error>] = [:]

    /// - Parameter margin: treat a URL as expired this many seconds early.
    public init(
        api: any GroupAPI, margin: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.api = api
        self.margin = margin
        self.now = now
    }

    /// Remembers the URLs that came with a response (posts, comments, stickers, profiles).
    public func remember(_ refs: some Sequence<MediaRef>) {
        for ref in refs { store(ref.id, url: ref.url, expiresAt: ref.urlExpiresAt) }
    }

    /// A URL for `ref` that is still valid.
    public func url(for ref: MediaRef) async throws -> URL {
        store(ref.id, url: ref.url, expiresAt: ref.urlExpiresAt)
        return try await url(forMediaID: ref.id)
    }

    public func url(forMediaID id: UUID) async throws -> URL {
        if let entry = entries[id], entry.expiresAt.addingTimeInterval(-margin) > now() {
            return entry.url
        }
        let task: Task<MediaURLResponse, any Error>
        if let existing = inFlight[id] {
            task = existing
        } else {
            let api = api
            task = Task { try await api.mediaURL(id: id) }
            inFlight[id] = task
        }
        do {
            let response = try await task.value
            inFlight[id] = nil
            store(id, url: response.url, expiresAt: response.expiresAt)
            return response.url
        } catch {
            inFlight[id] = nil
            throw error
        }
    }

    /// Drops the cached URL (a download answered 403, for example).
    public func invalidate(_ id: UUID) {
        entries[id] = nil
    }

    public func removeAll() {
        entries.removeAll()
    }

    private func store(_ id: UUID, url: URL, expiresAt: Date) {
        if let existing = entries[id], existing.expiresAt >= expiresAt { return }
        entries[id] = Entry(url: url, expiresAt: expiresAt)
    }
}
