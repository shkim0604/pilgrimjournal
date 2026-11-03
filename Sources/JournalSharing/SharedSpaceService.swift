import CloudKit
import Foundation
import JournalDomain

public enum SharedSpaceServiceError: Error, Equatable {
    case shareNotSaved
    case notASharedSpace(String)
}

/// Creates, accepts and ends family shares. Each space is one zone with a zone-wide share,
/// so whatever lands in the zone (entries, revisions, attachments) is shared with it.
@MainActor
public final class SharedSpaceService {
    public let container: CKContainer

    public init(container: CKContainer) {
        self.container = container
    }

    /// Makes the owner's zone for `space` and shares it. Participants are added from the
    /// system sharing sheet, which takes the returned share.
    public func createShare(for space: SharedSpaceRecord) async throws -> CKShare {
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: space.zoneName)
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])

        let share = CKShare(recordZoneID: zone.zoneID)
        share[CKShare.SystemFieldKey.title] = space.name
        share.publicPermission = .none
        let (saved, _) = try await database.modifyRecords(saving: [share], deleting: [])
        guard case .success(let record)? = saved[share.recordID],
            let savedShare = record as? CKShare
        else {
            throw SharedSpaceServiceError.shareNotSaved
        }
        return savedShare
    }

    /// The share of a space this user owns, for managing participants later.
    public func existingShare(for space: SharedSpaceRecord) async throws -> CKShare? {
        let zoneID = SharedRecordMapper.zoneID(for: space)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        do {
            return try await container.privateCloudDatabase.record(for: shareID) as? CKShare
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound
        {
            return nil
        }
    }

    /// Accepts an invitation opened from Messages or Mail and describes the space it adds.
    public func accept(_ metadata: CKShare.Metadata) async throws -> SharedSpaceRecord {
        let zoneID = metadata.share.recordID.zoneID
        guard let id = SharedSpaceRecord.id(fromZoneName: zoneID.zoneName) else {
            throw SharedSpaceServiceError.notASharedSpace(zoneID.zoneName)
        }
        _ = try await container.accept(metadata)
        let owner = metadata.ownerIdentity.nameComponents.map {
            PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
        }
        return SharedSpaceRecord(
            id: id,
            scope: .notebook,
            name: metadata.share[CKShare.SystemFieldKey.title] as? String ?? "",
            role: .participant,
            ownerName: owner,
            participantCount: metadata.share.participants.count
        )
    }

    /// Ends sharing for a space this user owns. Deleting the zone removes the share and the
    /// server copies for everyone, so the caller moves the entries back into the private
    /// journal first.
    public func stopSharing(_ space: SharedSpaceRecord) async throws {
        let zoneID = SharedRecordMapper.zoneID(for: space)
        _ = try await container.privateCloudDatabase.modifyRecordZones(
            saving: [], deleting: [zoneID])
    }

    /// Leaves a space someone else shared. Deleting the share from the shared database
    /// removes this user as a participant; the owner's copy is untouched.
    public func leave(zoneID: CKRecordZone.ID) async throws {
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        _ = try await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [shareID])
    }
}
