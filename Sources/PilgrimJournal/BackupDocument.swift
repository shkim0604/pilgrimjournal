import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let pilgrimJournalBackup = UTType(
        exportedAs: "com.pilgrimjournal.backup",
        conformingTo: .zip
    )
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.pilgrimJournalBackup, .zip, .data]
    }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
