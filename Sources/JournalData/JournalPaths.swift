import Foundation

public struct JournalPaths: Sendable {
    public var root: URL
    public var attachments: URL
    public var importStaging: URL
    public var backupStaging: URL
    public var search: URL

    public init(root: URL) {
        self.root = root
        attachments = root.appending(path: "Attachments", directoryHint: .isDirectory)
        importStaging = root.appending(path: "ImportStaging", directoryHint: .isDirectory)
        backupStaging = root.appending(path: "BackupStaging", directoryHint: .isDirectory)
        search = root.appending(path: "Search", directoryHint: .isDirectory)
    }

    public static func applicationDefault(
        fileManager: FileManager = .default
    ) throws -> JournalPaths {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return JournalPaths(
            root: base.appending(path: "PilgrimJournal", directoryHint: .isDirectory)
        )
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for directory in [root, attachments, importStaging, backupStaging, search] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
    }
}
