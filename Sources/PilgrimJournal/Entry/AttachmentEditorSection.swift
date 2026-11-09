import JournalDomain
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif
#if os(iOS)
import QuickLook
import UIKit
#endif

struct AttachmentEditorSection: View {
    @EnvironmentObject private var model: AppModel
    let entryID: UUID?
    let ensureEntryID: () -> UUID?
    var allowsImport = true
    /// The iPhone's focus mode hides the list but keeps the section, so the
    /// photo requests below still have something to present them.
    var showsList = true
    /// When set (iPhone editor), every image this section stores also goes
    /// into the body at its caret; other files stay list-only.
    var bodyImageInserter: MarkdownImageInserter?
    /// A photo asked for from outside this section — the keyboard bar or the
    /// body's edit menu. Presented here so it is stored the same way.
    var photoRequest: Binding<AttachmentPhotoSource?> = .constant(nil)
    @State private var attachments: [AttachmentRecord] = []
    @State private var isImporting = false
    @State private var isPresentingPhotoPicker = false
    @State private var photoPickerSelection: [PhotosPickerItem] = []
    #if os(iOS)
    @State private var previewURL: URL?
    @State private var isPresentingCamera = false
    #endif
    @State private var exportDocument: AttachmentDocument?
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "attachment"
    @State private var isExporting = false
    @State private var pendingDelete: AttachmentRecord?

    var body: some View {
        // The container stays even when the list is hidden: the picker,
        // camera and file importer below hang off it.
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.small) {
            if showsList {
                HStack {
                    Text("첨부")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(JournalTheme.inkSecondary)
                    Spacer()
                    if allowsImport {
                        HStack(spacing: JournalTheme.Spacing.small) {
                            Button {
                                requireEntryThenRun { isImporting = true }
                            } label: {
                                Label("파일", systemImage: "paperclip")
                            }
                            .buttonStyle(.borderless)

                            Button {
                                requireEntryThenRun { isPresentingPhotoPicker = true }
                            } label: {
                                Label("사진", systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(.borderless)

                            #if os(iOS)
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                Button {
                                    requireEntryThenRun { isPresentingCamera = true }
                                } label: {
                                    Label("촬영", systemImage: "camera")
                                }
                                .buttonStyle(.borderless)
                            }
                            #endif
                        }
                    }
                }

                if attachments.isEmpty {
                    Text("첨부 파일 없음")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.inkSecondary)
                } else {
                    // Capped so a record with many attachments scrolls inside
                    // this section instead of pushing tags/footer far down the
                    // outer editor scroll view.
                    ScrollView {
                        VStack(spacing: JournalTheme.Spacing.small) {
                            ForEach(attachments) { attachment in
                                HStack(spacing: JournalTheme.Spacing.small) {
                                    Image(systemName: attachmentIcon(for: attachment.mimeType))
                                        .foregroundStyle(JournalTheme.brandPrimary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(attachment.originalName)
                                            .lineLimit(1)
                                        Text(attachmentStatus(attachment))
                                            .font(.caption2)
                                            .foregroundStyle(
                                                attachment.state == .failed
                                                    ? Color.red
                                                    : JournalTheme.inkSecondary
                                            )
                                    }
                                    Spacer()
                                    attachmentAction(attachment)
                                    Button(role: .destructive) {
                                        pendingDelete = attachment
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("첨부 삭제")
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.image, .movie, .audio, .pdf, .data],
            allowsMultipleSelection: false
        ) { result in
            do {
                let url = try result.get().first
                guard let url else { return }
                guard let targetID = entryID ?? ensureEntryID() else {
                    model.errorMessage = String(localized: "첨부할 기록을 먼저 저장해 주세요.")
                    return
                }
                Task {
                    if let attachmentID = await model.addAttachment(from: url, to: targetID) {
                        attachments = model.attachments(for: targetID)
                        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)
                            == true,
                            let data = model.attachmentData(for: attachmentID)
                        {
                            bodyImageInserter?.insertImage(id: attachmentID, data: data)
                        }
                    }
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .photosPicker(
            isPresented: $isPresentingPhotoPicker,
            selection: $photoPickerSelection,
            maxSelectionCount: 0,
            matching: .images
        )
        .onChange(of: photoPickerSelection) { _, newValue in
            guard !newValue.isEmpty else { return }
            importPhotoPickerSelection(newValue)
        }
        .onChange(of: photoRequest.wrappedValue) { _, request in
            guard let request else { return }
            photoRequest.wrappedValue = nil
            switch request {
            case .library:
                requireEntryThenRun { isPresentingPhotoPicker = true }
            case .camera:
                #if os(iOS)
                requireEntryThenRun { isPresentingCamera = true }
                #endif
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $isPresentingCamera) {
            CameraCaptureView(
                onCapture: { image in
                    isPresentingCamera = false
                    importCapturedPhoto(image)
                },
                onCancel: { isPresentingCamera = false }
            )
            .ignoresSafeArea()
        }
        #endif
        .onAppear { attachments = model.attachments(for: entryID) }
        .onChange(of: entryID) { _, newValue in
            attachments = model.attachments(for: newValue)
        }
        .onChange(of: model.attachmentRevision) { _, _ in
            attachments = model.attachments(for: entryID)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result,
                (error as NSError).code != NSUserCancelledError
            {
                model.errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        #if os(iOS)
        .quickLookPreview($previewURL)
        #endif
        .confirmationDialog(
            "이 첨부를 삭제할까요?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if let attachment = pendingDelete {
                    model.deleteAttachment(attachment.id)
                }
                pendingDelete = nil
            }
            Button("취소", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("이 기기와 iCloud에서 완전히 지워지며 되돌릴 수 없습니다.")
        }
    }

    private func requireEntryThenRun(_ action: () -> Void) {
        guard entryID != nil || ensureEntryID() != nil else {
            model.errorMessage = String(localized: "첨부 전에 제목이나 본문을 입력해 기록을 저장해 주세요.")
            return
        }
        action()
    }

    /// Photos from the library can be tens of megabytes at full resolution
    /// (HEIC, ProRAW-adjacent JPEGs). Only large images are recompressed —
    /// small ones (typically pasted screenshots elsewhere in the editor)
    /// pass through untouched so text stays crisp.
    private nonisolated static let compressionSizeThreshold = 3 * 1024 * 1024
    private nonisolated static let compressionMaxDimension: CGFloat = 2048
    private nonisolated static let compressionQuality: CGFloat = 0.85

    private func importPhotoPickerSelection(_ items: [PhotosPickerItem]) {
        guard let targetID = entryID ?? ensureEntryID() else {
            model.errorMessage = String(localized: "첨부할 기록을 먼저 저장해 주세요.")
            photoPickerSelection = []
            return
        }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    continue
                }
                let contentType = item.supportedContentTypes.first
                let isImage = contentType?.conforms(to: .image) ?? true
                var uploadData = data
                var fileExtension = contentType?.preferredFilenameExtension ?? "jpg"
                var mimeType = contentType?.preferredMIMEType ?? "image/jpeg"
                if isImage, data.count > Self.compressionSizeThreshold {
                    let compressed = await Task.detached(priority: .userInitiated) {
                        Self.compressedForUpload(data)
                    }.value
                    if let compressed {
                        uploadData = compressed
                        fileExtension = "jpg"
                        mimeType = "image/jpeg"
                    }
                }
                let attachmentID = await model.addAttachment(
                    data: uploadData,
                    originalName: "\(UUID().uuidString).\(fileExtension)",
                    mimeType: mimeType,
                    to: targetID
                )
                if isImage, let attachmentID {
                    bodyImageInserter?.insertImage(id: attachmentID, data: uploadData)
                }
            }
            attachments = model.attachments(for: targetID)
            photoPickerSelection = []
        }
    }

    #if os(iOS)
    private func importCapturedPhoto(_ image: UIImage) {
        guard let targetID = entryID ?? ensureEntryID() else {
            model.errorMessage = String(localized: "첨부할 기록을 먼저 저장해 주세요.")
            return
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else { return }
        Task {
            let uploadData: Data
            if data.count > Self.compressionSizeThreshold {
                uploadData =
                    await Task.detached(priority: .userInitiated) {
                        Self.compressedForUpload(data)
                    }.value ?? data
            } else {
                uploadData = data
            }
            if let attachmentID = await model.addAttachment(
                data: uploadData,
                originalName: "\(UUID().uuidString).jpg",
                mimeType: "image/jpeg",
                to: targetID
            ) {
                bodyImageInserter?.insertImage(id: attachmentID, data: uploadData)
            }
            attachments = model.attachments(for: targetID)
        }
    }
    #endif

    /// Decodes, downscales to `compressionMaxDimension` on the longest side
    /// (no upscaling), and re-encodes as JPEG. Called off the main actor —
    /// decoding and re-encoding a large image is itself not free.
    private nonisolated static func compressedForUpload(_ data: Data) -> Data? {
        #if os(iOS)
        guard let image = UIImage(data: data) else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        let scale =
            longestSide > compressionMaxDimension
            ? compressionMaxDimension / longestSide
            : 1
        let targetSize = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: compressionQuality)
        #elseif os(macOS)
        guard let image = NSImage(data: data) else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        let scale =
            longestSide > compressionMaxDimension
            ? compressionMaxDimension / longestSide
            : 1
        let targetSize = NSSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        guard let tiffData = resized.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: compressionQuality]
        )
        #endif
    }

    private func openAttachment(_ attachment: AttachmentRecord) {
        guard let url = model.temporaryPreviewURL(for: attachment.id) else { return }
        #if os(iOS)
        previewURL = url
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    private func beginExport(_ attachment: AttachmentRecord) {
        guard let data = model.attachmentData(for: attachment.id) else { return }
        exportDocument = AttachmentDocument(data: data)
        exportContentType = UTType(mimeType: attachment.mimeType) ?? .data
        let name =
            attachment.originalName.isEmpty
            ? String(localized: "첨부파일") : attachment.originalName
        exportFilename =
            (name as NSString).deletingPathExtension.isEmpty
            ? name
            : (name as NSString).deletingPathExtension
        isExporting = true
    }

    private func attachmentIcon(for mimeType: String) -> String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        return "doc"
    }

    private func attachmentStatus(_ attachment: AttachmentRecord) -> String {
        let size = ByteCountFormatter.string(
            fromByteCount: attachment.byteCount,
            countStyle: .file
        )
        let state =
            switch attachment.state {
            case .local: String(localized: "이 기기에 저장됨")
            case .pending: String(localized: "iCloud 업로드 대기")
            case .uploading: String(localized: "iCloud 업로드 중")
            case .uploaded: String(localized: "iCloud에 저장됨")
            case .downloading: String(localized: "다운로드 중")
            case .failed: String(localized: "전송 실패 · 다시 시도 필요")
            }
        return "\(size) · \(state)"
    }

    @ViewBuilder
    private func attachmentAction(_ attachment: AttachmentRecord) -> some View {
        if attachment.state == .failed {
            Button("재시도") {
                model.retryAttachmentTransfer(attachment.id)
            }
            .buttonStyle(.bordered)
        } else if attachment.state == .downloading {
            AttachmentDownloadStatusView(attachment: attachment)
        } else if attachment.state == .pending || attachment.state == .uploading {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(attachmentStatus(attachment))
        } else if !model.hasLocalBinary(for: attachment.id) {
            Button("다운로드") {
                model.requestAttachmentDownload(attachment.id)
            }
            .buttonStyle(.bordered)
        } else {
            HStack(spacing: JournalTheme.Spacing.small) {
                Button {
                    openAttachment(attachment)
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("미리보기")

                Button {
                    beginExport(attachment)
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("다른 위치에 저장")
            }
        }
    }
}

/// CloudKit has no public API to force-fetch a single record's asset, so a
/// requested download can only wait for the framework's own background
/// import. This surfaces that honestly instead of spinning forever: while an
/// import operation is actually running (`model.isCloudImportInProgress`) it
/// keeps waiting, otherwise it gives up after a timeout and offers "재시도".
private struct AttachmentDownloadStatusView: View {
    @EnvironmentObject private var model: AppModel
    let attachment: AttachmentRecord
    @State private var hasTimedOut = false

    private static let timeout: Duration = .seconds(25)

    var body: some View {
        Group {
            if hasTimedOut {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("iCloud에서 받아오지 못했습니다")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Button("재시도") {
                        model.retryAttachmentTransfer(attachment.id)
                    }
                    .buttonStyle(.bordered)
                }
            } else if model.isCloudImportInProgress {
                Label("동기화 진행 중", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2)
                    .foregroundStyle(JournalTheme.inkSecondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("다운로드 중")
            }
        }
        .task(id: attachment.updatedAt) {
            hasTimedOut = false
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.timeout)
                guard !Task.isCancelled else { return }
                if model.isCloudImportInProgress { continue }
                hasTimedOut = true
                return
            }
        }
    }
}
