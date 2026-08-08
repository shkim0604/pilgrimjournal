import CryptoKit
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
            let checksum = sha256(data)
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
            let url = root
                .appending(path: String(checksum.prefix(2)), directoryHint: .isDirectory)
                .appending(path: checksum)
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
    }

    public func removeIfUnreferenced(
        checksum: String,
        referencedChecksums: Set<String>
    ) throws {
        guard !referencedChecksums.contains(checksum) else { return }
        try withLock {
            let url = root
                .appending(path: String(checksum.prefix(2)), directoryHint: .isDirectory)
                .appending(path: checksum)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
