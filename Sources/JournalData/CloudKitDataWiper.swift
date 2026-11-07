import CloudKit
import Foundation
import JournalDomain

/// Some zones or shares were deleted and others were not.
///
/// CloudKit reports zone and record deletions one by one, so a request can
/// succeed overall while single items fail. Each failed item is named here, so
/// the user sees that deletion is unfinished and can retry.
public struct CloudKitWipeError: LocalizedError, Equatable, Sendable {
    /// Zone or share record names that are still in iCloud.
    public var remaining: [String]
    /// The first item's CloudKit error, for the message.
    public var reason: String

    public init(remaining: [String], reason: String) {
        self.remaining = remaining
        self.reason = reason
    }

    public var errorDescription: String? {
        String(
            localized: "iCloud 항목 \(remaining.count)개를 지우지 못했습니다: \(reason)",
            bundle: .module
        )
    }
}

/// Deletes journal records from CloudKit while leaving the schema intact.
///
/// `NSPersistentCloudKitContainer` keeps all mirrored rows in custom record
/// zones it owns. Record *types* live in the container's schema, which is
/// separate from any zone, so dropping the zones empties the data without
/// touching the types that were just deployed. Deleting records one by one
/// through the console would take thousands of clicks and cannot be scripted
/// without a management token.
///
/// Family sharing keeps each shared notebook or entry in its own
/// `pilgrim-share-<uuid>` zone. The developer wipe (`wipePrivateData`) leaves
/// those alone; account deletion (`wipeAccountZones` and
/// `leaveAcceptedShares`) removes them too.
///
/// The account binding record lives in the default zone and is deliberately
/// left alone: it is not journal data, and removing it would unbind the
/// CloudKit account from the Apple user that owns it. In-app account deletion
/// (`CloudKitAccountDataEraser`) removes the binding separately.
public enum CloudKitDataWiper {
    /// Zone-name prefix that Core Data's CloudKit mirroring owns.
    private static let mirroringZonePrefix = "com.apple.coredata.cloudkit"

    /// CloudKit takes at most 400 items per modify request.
    private static let batchSize = 200

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
        return try await deleteZones(targets, in: database)
    }

    /// Removes every zone this app keeps in the user's private database: the
    /// mirroring zones and the `pilgrim-share-*` zones of spaces this user
    /// shared. Deleting a shared zone also deletes its share, so every
    /// participant loses the copy. Only the default zone, which holds the
    /// account binding, stays.
    ///
    /// - Returns: The names of the zones that were deleted.
    public static func wipeAccountZones(
        containerIdentifier: String
    ) async throws -> [String] {
        let database = CKContainer(identifier: containerIdentifier)
            .privateCloudDatabase
        let zones = try await database.allRecordZones()
        return try await deleteZones(accountZoneIDs(in: zones.map(\.zoneID)), in: database)
    }

    /// Leaves every space other family members shared with this user, by
    /// deleting each zone-wide share from the shared database. The owners'
    /// copies stay; this user is removed from the participants.
    ///
    /// - Returns: The names of the zones this user left.
    public static func leaveAcceptedShares(
        containerIdentifier: String
    ) async throws -> [String] {
        let database = CKContainer(identifier: containerIdentifier)
            .sharedCloudDatabase
        let zones = try await database.allRecordZones()
        let shareIDs = acceptedShareIDs(in: zones.map(\.zoneID))
        // One request per share: each lives in a different owner's zone, and
        // one owner's failure must not keep this user in the other spaces.
        var results: [(name: String, result: Result<Void, Error>)] = []
        for shareID in shareIDs {
            let result: Result<Void, Error>
            do {
                let (_, deleted) = try await database.modifyRecords(
                    saving: [], deleting: [shareID])
                result = deleted[shareID] ?? .success(())
            } catch {
                result = .failure(error)
            }
            results.append((shareID.zoneID.zoneName, result))
        }
        try throwIfAnyFailed(results)
        return shareIDs.map(\.zoneID.zoneName).sorted()
    }

    /// Every custom zone, so nothing the app wrote outlives account deletion.
    static func accountZoneIDs(in zoneIDs: [CKRecordZone.ID]) -> [CKRecordZone.ID] {
        zoneIDs.filter { $0.zoneName != CKRecordZone.ID.defaultZoneName }
    }

    /// The zone-wide share of each family space in the shared database.
    static func acceptedShareIDs(in zoneIDs: [CKRecordZone.ID]) -> [CKRecord.ID] {
        zoneIDs
            .filter { $0.zoneName.hasPrefix(SharedSpaceRecord.zoneNamePrefix) }
            .map { CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: $0) }
    }

    /// Throws `CloudKitWipeError` naming each item whose deletion failed. An
    /// item that is already gone counts as deleted: another device or the
    /// owner removed it first.
    static func throwIfAnyFailed(_ results: [(name: String, result: Result<Void, Error>)]) throws {
        let failures = results.compactMap { item -> (String, Error)? in
            guard case .failure(let error) = item.result, !isAlreadyGone(error) else {
                return nil
            }
            return (item.name, error)
        }
        .sorted { $0.0 < $1.0 }
        guard let first = failures.first else { return }
        throw CloudKitWipeError(
            remaining: failures.map(\.0),
            reason: first.1.localizedDescription
        )
    }

    private static func isAlreadyGone(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        return [.zoneNotFound, .userDeletedZone, .unknownItem].contains(error.code)
    }

    private static func deleteZones(
        _ zoneIDs: [CKRecordZone.ID],
        in database: CKDatabase
    ) async throws -> [String] {
        var results: [CKRecordZone.ID: Result<Void, Error>] = [:]
        for batch in zoneIDs.chunked(into: batchSize) {
            let (_, deleted) = try await database.modifyRecordZones(saving: [], deleting: batch)
            results.merge(deleted) { _, new in new }
        }
        try throwIfAnyFailed(results.map { ($0.key.zoneName, $0.value) })
        return zoneIDs.map(\.zoneName).sorted()
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

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
