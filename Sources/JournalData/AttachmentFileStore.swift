import Foundation
import JournalDomain

public struct StoredAttachment: Sendable {
    public var record: AttachmentRecord
    public var localURL: URL
    public var wasDeduplicated: Bool
}

public final class AttachmentFileStore: @unchecked Sendable {
    private let root: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func store(
        data: Data,
        entryID: UUID,
        originalName: String,
        mimeType: String
    ) throws -> StoredAttachment {
        try withLock {
            let checksum = ContentHash.sha256Hex(data)
            let directory = root.appending(
                path: String(checksum.prefix(2)),
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appending(path: checksum)
            let exists = fileManager.fileExists(atPath: fileURL.path)
            if !exists {
                let temporary = directory.appending(path: ".\(UUID().uuidString).partial")
                do {
                    try data.write(to: temporary, options: [.atomic])
                    try fileManager.moveItem(at: temporary, to: fileURL)
                } catch {
                    try? fileManager.removeItem(at: temporary)
                    throw error
                }
            }
            return StoredAttachment(
                record: AttachmentRecord(
                    entryID: entryID,
                    originalName: originalName,
                    mimeType: mimeType,
                    checksum: checksum,
                    byteCount: Int64(data.count),
                    state: .local
                ),
                localURL: fileURL,
                wasDeduplicated: exists
            )
        }
    }

    public func data(checksum: String) throws -> Data {
        try withLock {
            try Data(contentsOf: fileURL(checksum: checksum), options: [.mappedIfSafe])
        }
    }

    /// The CAS file's location for `checksum` — a pure path computation, no
    /// I/O. Lets callers (e.g. an image decoder) open the file directly
    /// (`CGImageSourceCreateWithURL`) without going through `data(checksum:)`
    /// and materializing a `Data` copy first.
    public func url(checksum: String) -> URL {
        fileURL(checksum: checksum)
    }

    /// Whether `checksum`'s file exists on disk — path computation +
    /// `fileExists` only, never reads the file's contents. Safe to call from
    /// a hot path (e.g. once per attachment row per render) where
    /// `data(checksum:)` would be wasteful.
    public func hasData(checksum: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileManager.fileExists(atPath: fileURL(checksum: checksum).path)
    }

    /// Writes `data` into the CAS under `checksum` if it isn't there
    /// already — the self-healing counterpart to `hasData`/`data`. Used
    /// when an attachment's binary is only available from the SwiftData
    /// blob (e.g. synced in from another device, so the CAS file was never
    /// written locally): after this, `hasData(checksum:)` is true for good,
    /// so the slow DB-blob fallback only ever fires once per attachment per
    /// device. Trusts `checksum` — it's the row's already-verified
    /// checksum, not recomputed here.
    public func hydrate(checksum: String, data: Data) throws {
        try withLock {
            let url = fileURL(checksum: checksum)
            guard !fileManager.fileExists(atPath: url.path) else { return }
            let directory = url.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(UUID().uuidString).partial")
            do {
                try data.write(to: temporary, options: [.atomic])
                try fileManager.moveItem(at: temporary, to: url)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
        }
    }

    public func removeIfUnreferenced(
        checksum: String,
        referencedChecksums: Set<String>
    ) throws {
        guard !referencedChecksums.contains(checksum) else { return }
        try withLock {
            let url = fileURL(checksum: checksum)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func fileURL(checksum: String) -> URL {
        root
            .appending(path: String(checksum.prefix(2)), directoryHint: .isDirectory)
            .appending(path: checksum)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
