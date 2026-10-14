import CloudKit
import Foundation

/// Deletes every mirrored journal record while leaving the schema intact.
///
/// `NSPersistentCloudKitContainer` keeps all mirrored rows in custom record
/// zones it owns. Record *types* live in the container's schema, which is
/// separate from any zone, so dropping the zones empties the data without
/// touching the types that were just deployed. Deleting records one by one
/// through the console would take thousands of clicks and cannot be scripted
/// without a management token.
///
/// The account binding record lives in the default zone and is deliberately
/// left alone: it is not journal data, and removing it would unbind the
/// CloudKit account from the Apple user that owns it.
public enum CloudKitDataWiper {
    /// Zone-name prefix that Core Data's CloudKit mirroring owns.
    private static let mirroringZonePrefix = "com.apple.coredata.cloudkit"

    /// Removes the mirroring zones from the user's private database.
    ///
    /// - Returns: The names of the zones that were deleted.
    public static func wipePrivateData(
        containerIdentifier: String
    ) async throws -> [String] {
        let database = CKContainer(identifier: containerIdentifier)
            .privateCloudDatabase
        let zones = try await database.allRecordZones()
        let targets =
            zones
            .map(\.zoneID)
            .filter { $0.zoneName.hasPrefix(mirroringZonePrefix) }
        guard !targets.isEmpty else { return [] }

        _ = try await database.modifyRecordZones(
            saving: [],
            deleting: targets
        )
        return targets.map(\.zoneName).sorted()
    }

    /// Deletes the on-disk stores, search indexes and pending queues.
    ///
    /// CloudKit would otherwise re-upload everything from this device the
    /// moment the app reopens, undoing the wipe.
    ///
    /// - Returns: The directories that were removed.
    public static func wipeLocalData(rootURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path(percentEncoded: false))
        else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        for url in contents {
            try fileManager.removeItem(at: url)
        }
        return contents.map(\.lastPathComponent).sorted()
    }
}
