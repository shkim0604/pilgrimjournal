import Combine
import DayOneImport
import Foundation
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import UniformTypeIdentifiers

extension AppModel {
    func attachments(for entryID: UUID?) -> [AttachmentRecord] {
        guard let entryID, sharedSpaceID(for: entryID) == nil,
            let attachmentRepository = repository as? any AttachmentRepository
        else {
            return []
        }
        do {
            // Scoped to this entry and never touches `.binary` — unlike the
            // old `allAttachments()`-based version, which faulted every
            // attachment blob in the whole journal just to filter and
            // immediately discard them.
            return try attachmentRepository.attachments(forEntry: entryID)
                .filter { $0.deletedAt == nil }
                .sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Checks CAS file presence only — never faults the SwiftData blob.
    /// Fast path for attachments created on this device (their CAS file was
    /// written at upload time) and for anything already hydrated by a prior
    /// call. Only faults the DB blob (once, then self-heals — see
    /// `AttachmentFileStore.hydrate`) for attachments synced in from
    /// another device, whose CAS file was never written locally.
    func hasLocalBinary(for attachmentID: UUID) -> Bool {
        guard let attachmentRepository = repository as? any AttachmentRepository,
            let checksum = try? attachmentRepository.attachmentChecksum(id: attachmentID),
            let fileStore = attachmentFileStore
        else {
            return false
        }
        if fileStore.hasData(checksum: checksum) { return true }
        guard let stored = try? attachmentRepository.attachment(id: attachmentID),
            let binary = stored.binary
        else { return false }
        try? fileStore.hydrate(checksum: checksum, data: binary)
        return true
    }

    /// Same cheap-first, self-healing strategy as `hasLocalBinary`: try the
    /// mmap'd CAS file (no blob fault) before falling back to the SwiftData
    /// blob, hydrating the CAS on the way through so the next call is cheap.
    /// Backed by single-row queries throughout — safe for hot paths like the
    /// live editor's inline image rendering, which can be called often and
    /// must not scan the whole journal each time.
    func attachmentData(for attachmentID: UUID) -> Data? {
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            return nil
        }
        if let checksum = try? attachmentRepository.attachmentChecksum(id: attachmentID),
            let fileStore = attachmentFileStore,
            let cached = try? fileStore.data(checksum: checksum)
        {
            return cached
        }
        guard let stored = try? attachmentRepository.attachment(id: attachmentID)
        else { return nil }
        if let fileStore = attachmentFileStore, let binary = stored.binary {
            try? fileStore.hydrate(checksum: stored.record.checksum, data: binary)
        }
        return stored.binary
    }

    /// Writes the attachment's binary to a per-attachment temp directory so
    /// QuickLook (iOS) or the default external app (macOS) can open it by
    /// URL. The blob itself only lives in SwiftData's external storage
    /// attribute, not as a named file, so this is the only way to hand it to
    /// a URL-based viewer.
    func temporaryPreviewURL(for attachmentID: UUID) -> URL? {
        guard let attachmentRepository = repository as? any AttachmentRepository,
            let stored = try? attachmentRepository.attachment(id: attachmentID),
            let data = attachmentData(for: attachmentID)
        else { return nil }
        let record = stored.record
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AttachmentPreview", directoryHint: .isDirectory)
            .appending(path: attachmentID.uuidString, directoryHint: .isDirectory)
        let filename =
            record.originalName.isEmpty
            ? attachmentID.uuidString
            : record.originalName
        let url = directory.appending(path: filename)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            }
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Reading the file and hashing/writing it into the CAS store both scale
    /// with file size and used to run synchronously on the main actor,
    /// blocking editor typing while a large attachment imported. Both now
    /// happen off the main actor; only the final SwiftData save (which must
    /// stay on the main actor) runs here.
    @discardableResult
    func addAttachment(from url: URL, to entryID: UUID) async -> UUID? {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            let contentType = UTType(filenameExtension: url.pathExtension)
            return await addAttachment(
                data: data,
                originalName: url.lastPathComponent,
                mimeType: contentType?.preferredMIMEType ?? "application/octet-stream",
                to: entryID
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// See `addAttachment(from:to:)` — the CAS hash+write is offloaded for
    /// the same reason.
    @discardableResult
    func addAttachment(
        data: Data,
        originalName: String,
        mimeType: String,
        to entryID: UUID
    ) async -> UUID? {
        guard sharedSpaceID(for: entryID) == nil else {
            errorMessage = String(localized: "공유 노트북에는 아직 사진을 넣을 수 없습니다.")
            return nil
        }
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            errorMessage = String(localized: "이 저장소에서는 첨부 파일을 사용할 수 없습니다.")
            return nil
        }
        let attachmentsRoot = paths.attachments
        do {
            let stored = try await Task.detached(priority: .userInitiated) {
                try AttachmentFileStore(root: attachmentsRoot).store(
                    data: data,
                    entryID: entryID,
                    originalName: originalName,
                    mimeType: mimeType
                )
            }.value
            var record = stored.record
            record.state = cloudAccountMonitor == nil ? .local : .pending
            record.updatedAt = .now
            try attachmentRepository.saveAttachment(record, binary: data)
            attachmentRevision += 1
            markLocalMutation()
            return record.id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Removes one attachment from its entry. Irreversible; the caller is
    /// expected to have already confirmed with the user. Frees the CAS file
    /// only if no other row (including other entries, via checksum dedupe)
    /// still references it.
    func deleteAttachment(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            guard let checksum = try attachmentRepository.deleteAttachment(id: attachmentID)
            else { return }
            attachmentRevision += 1
            markLocalMutation()
            releaseAttachmentFiles([checksum])
            removePreviewTempFiles(for: [attachmentID])
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestAttachmentDownload(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            // Single-row fetch — needed to know whether the binary is
            // already present (decides which state to transition to) — but
            // the actual write goes through `updateAttachmentState`, which
            // never rewrites that binary back to disk.
            guard let stored = try attachmentRepository.attachment(id: attachmentID)
            else { return }
            let newState: AttachmentTransferState =
                stored.binary != nil
                ? (cloudAccountMonitor == nil ? .local : .uploaded)
                : .downloading
            try attachmentRepository.updateAttachmentState(
                id: attachmentID, state: newState, updatedAt: .now
            )
            attachmentRevision += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryAttachmentTransfer(_ attachmentID: UUID) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            guard let stored = try attachmentRepository.attachment(id: attachmentID)
            else { return }
            let newState: AttachmentTransferState = stored.binary == nil ? .downloading : .pending
            try attachmentRepository.updateAttachmentState(
                id: attachmentID, state: newState, updatedAt: .now
            )
            attachmentRevision += 1
            markLocalMutation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateAttachmentTransferStates(
        matching states: Set<AttachmentTransferState>,
        to newState: AttachmentTransferState
    ) {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            var didUpdate = false
            // Scoped to just the matching states — a small, transient
            // subset — and never rewrites `binary` (unlike the old
            // saveAttachment(record, binary:) round-trip, which faulted
            // every matching row's blob just to flip an enum, and could
            // re-upload the same CKAsset on every sync event).
            for stored in try attachmentRepository.attachments(inStates: states)
            where stored.record.deletedAt == nil {
                if try attachmentRepository.updateAttachmentState(
                    id: stored.record.id, state: newState, updatedAt: .now
                ) {
                    didUpdate = true
                }
            }
            if didUpdate { attachmentRevision += 1 }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reconcileDownloadedAttachments() {
        guard let attachmentRepository = repository as? any AttachmentRepository else { return }
        do {
            var didUpdate = false
            for stored in try attachmentRepository.attachments(inStates: [.downloading])
            where stored.binary != nil {
                if try attachmentRepository.updateAttachmentState(
                    id: stored.record.id, state: .uploaded, updatedAt: .now
                ) {
                    didUpdate = true
                }
            }
            if didUpdate { attachmentRevision += 1 }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
