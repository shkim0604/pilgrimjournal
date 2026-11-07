#if PILGRIM_SWIFTDATA
import CloudKit
import Combine
import JournalData
import JournalDomain
import JournalSharing
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Invitations opened before the journal is open (signed out, locked, still loading) wait
/// here until a `FamilySharingController` starts and accepts them.
@MainActor
final class PendingShareInvitations {
    static let shared = PendingShareInvitations()
    private var waiting: [CKShare.Metadata] = []
    var onReceive: (() -> Void)?

    func add(_ metadata: CKShare.Metadata) {
        waiting.append(metadata)
        onReceive?()
    }

    func drain() -> [CKShare.Metadata] {
        defer { waiting = [] }
        return waiting
    }
}

/// The app's side of shared notebooks: the spaces this user owns or joined, their entry
/// caches, and the CloudKit engines that sync them. Owned by `AppModel`, so everything
/// stops when the journal store closes.
@MainActor
final class FamilySharingController: ObservableObject {
    @Published private(set) var spaces: [SharedSpaceRecord] = []
    @Published var presentedShare: PresentedShare?

    struct PresentedShare: Identifiable {
        let id = UUID()
        let share: CKShare
    }

    /// Called after spaces or shared entries change, locally or from another device.
    var onChange: (() -> Void)?
    /// Called with a message when a background sync step fails.
    var onError: ((String) -> Void)?

    let container: CKContainer
    private let store: SharedSpaceStore
    private let host: SharedSyncEngineHost
    private let service: SharedSpaceService

    init(containerIdentifier: String, directory: URL, deviceID: String) throws {
        container = CKContainer(identifier: containerIdentifier)
        let store = try SharedSpaceStore(
            directory: directory,
            deviceID: deviceID,
            provider: SwiftDataSharedEntryCacheProvider(directory: directory)
        )
        let host = SharedSyncEngineHost(container: container, store: store)
        self.store = store
        self.host = host
        service = SharedSpaceService(container: container)
        spaces = store.spaces

        store.onEnqueue = { [weak host] saves, deletes in
            host?.enqueueSave(saves)
            host?.enqueueDelete(deletes)
        }
        store.onChange = { [weak self, unowned store] in
            self?.spaces = store.spaces
            self?.onChange?()
        }
        host.start()
        PendingShareInvitations.shared.onReceive = { [weak self] in
            self?.acceptPendingInvitations()
        }
        acceptPendingInvitations()
    }

    // MARK: Reading

    func space(_ id: UUID) -> SharedSpaceRecord? {
        spaces.first { $0.id == id }
    }

    func entries(in spaceID: UUID) -> [JournalEntryRecord] {
        (try? store.cache(for: spaceID).list(kind: nil, includeDeleted: false, limit: 1_000)) ?? []
    }

    func spaceID(containing entryID: UUID) -> UUID? {
        store.spaceID(containing: entryID)
    }

    func entry(id: UUID) -> JournalEntryRecord? {
        guard let spaceID = spaceID(containing: id) else { return nil }
        return try? store.cache(for: spaceID).entry(id: id)
    }

    /// The label shared entries carry for a kind this device's catalog doesn't know.
    func kindSnapshot(for kind: JournalKind) -> SharedKindSnapshot? {
        store.kindSnapshot(for: kind)
    }

    func revisions(entryID: UUID, in spaceID: UUID) throws -> [EntryRevisionRecord] {
        try store.cache(for: spaceID).revisions(entryID: entryID)
    }

    /// Every live entry of a space with its history, to copy back into the journal.
    func contents(of spaceID: UUID) throws -> [(JournalEntryRecord, [EntryRevisionRecord])] {
        let cache = try store.cache(for: spaceID)
        return try cache.list(kind: nil, includeDeleted: false, limit: 100_000).map {
            ($0, try cache.revisions(entryID: $0.id))
        }
    }

    // MARK: Editing

    @discardableResult
    func save(
        _ draft: JournalEntryDraft,
        kind: SharedKindSnapshot?,
        in spaceID: UUID,
        basedOn baseRevisionID: UUID?
    ) throws -> JournalEntryRecord {
        let saved = try store.save(draft, kind: kind, in: spaceID, basedOn: baseRevisionID)
        sendSoon()
        return saved
    }

    func moveToTrash(entryID: UUID, in spaceID: UUID) throws {
        try store.moveToTrash(entryID: entryID, in: spaceID)
        sendSoon()
    }

    @discardableResult
    func restoreRevision(
        entryID: UUID, revisionID: UUID, kind: SharedKindSnapshot?, in spaceID: UUID
    ) throws -> JournalEntryRecord {
        let restored = try store.restoreRevision(
            entryID: entryID, revisionID: revisionID, kind: kind, in: spaceID)
        sendSoon()
        return restored
    }

    // MARK: Sharing

    /// Creates a share named `name`, moves `entries` into it, and opens the system
    /// invitation sheet. Nothing is moved if the share cannot be created.
    func share(
        named name: String,
        scope: SharedSpaceRecord.Scope,
        entries: [(
            entry: JournalEntryRecord, revisions: [EntryRevisionRecord], kind: SharedKindSnapshot
        )]
    ) async throws -> SharedSpaceRecord {
        let space = SharedSpaceRecord(scope: scope, name: name, role: .owner)
        let share = try await service.createShare(for: space)
        store.addSpace(space)
        for item in entries {
            try store.importEntry(
                item.entry, revisions: item.revisions, kind: item.kind, into: space.id)
        }
        sendSoon()
        presentedShare = PresentedShare(share: share)
        return space
    }

    func manageShare(of spaceID: UUID) async throws {
        guard let space = space(spaceID) else { return }
        if let share = try await service.existingShare(for: space) {
            presentedShare = PresentedShare(share: share)
        }
    }

    /// Ends a share this user owns: the server copies go away for everyone. The caller
    /// copies the entries back into the journal first.
    func stopSharing(_ spaceID: UUID) async throws {
        guard let space = space(spaceID), let zoneID = store.zoneID(for: spaceID) else { return }
        try await service.stopSharing(space)
        store.removeSpace(zoneID: zoneID)
    }

    /// Leaves a share someone else owns; their copy is untouched.
    func leave(_ spaceID: UUID) async throws {
        guard let zoneID = store.zoneID(for: spaceID) else { return }
        try await service.leave(zoneID: zoneID)
        store.removeSpace(zoneID: zoneID)
    }

    // MARK: Sync

    /// Pulls now instead of waiting for a push, which can be late or coalesced.
    func fetchNow() async {
        do {
            try await host.fetchChanges()
        } catch {
            report(error)
        }
    }

    private func sendSoon() {
        Task { [weak self] in
            do {
                try await self?.host.sendChanges()
            } catch {
                self?.report(error)
            }
        }
    }

    private func acceptPendingInvitations() {
        for metadata in PendingShareInvitations.shared.drain() {
            Task {
                do {
                    let space = try await service.accept(metadata)
                    store.addSpace(space, zoneOwnerName: metadata.share.recordID.zoneID.ownerName)
                    try await host.fetchChanges()
                } catch {
                    report(error)
                }
            }
        }
    }

    private func report(_ error: Error) {
        // Offline is normal; the engines retry by themselves.
        if let ckError = error as? CKError,
            [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited]
                .contains(ckError.code)
        {
            return
        }
        onError?(error.localizedDescription)
    }
}

// MARK: - Invitation sheet

extension View {
    /// Shows the system iCloud sharing sheet whenever the controller has a share to present.
    func sharedSpaceInvitationSheet(_ controller: FamilySharingController?) -> some View {
        modifier(SharedSpaceInvitationSheet(controller: controller))
    }
}

private struct SharedSpaceInvitationSheet: ViewModifier {
    let controller: FamilySharingController?

    func body(content: Content) -> some View {
        if let controller {
            content.modifier(Presenter(controller: controller))
        } else {
            content
        }
    }

    private struct Presenter: ViewModifier {
        @ObservedObject var controller: FamilySharingController

        func body(content: Content) -> some View {
            #if os(iOS)
            content.sheet(item: $controller.presentedShare) { presented in
                CloudSharingSheet(share: presented.share, container: controller.container)
                    .ignoresSafeArea()
            }
            #else
            content.onChange(of: controller.presentedShare?.id) { _, _ in
                guard let presented = controller.presentedShare else { return }
                controller.presentedShare = nil
                let provider = NSItemProvider()
                provider.registerCloudKitShare(presented.share, container: controller.container)
                NSSharingService(named: .cloudSharing)?.perform(withItems: [provider])
            }
            #endif
        }
    }
}

#if os(iOS)
private struct CloudSharingSheet: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        // Invite-only: no "anyone with the link" option for prayer notes.
        controller.availablePermissions = [.allowPrivate, .allowReadWrite, .allowReadOnly]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func itemTitle(for csc: UICloudSharingController) -> String? {
            csc.share?[CKShare.SystemFieldKey.title] as? String
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {}
    }
}
#endif

// MARK: - Invitation delivery

#if os(iOS)
final class FamilySharingAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // A cold launch from an invitation link carries the share here.
        if let metadata = options.cloudKitShareMetadata {
            PendingShareInvitations.shared.add(metadata)
        }
        let configuration = UISceneConfiguration(
            name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = FamilySharingSceneDelegate.self
        return configuration
    }
}

final class FamilySharingSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        PendingShareInvitations.shared.add(cloudKitShareMetadata)
    }
}
#else
final class FamilySharingAppDelegate: NSObject, NSApplicationDelegate {
    func application(
        _ application: NSApplication,
        userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
    ) {
        PendingShareInvitations.shared.add(metadata)
    }
}
#endif
#endif
