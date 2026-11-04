#if DEBUG && PILGRIM_SWIFTDATA
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

// Family sharing spike: a Debug-only screen (설정 › 개발 › 가족 공유 실험) to check the
// CloudKit sharing layer between two Apple IDs on real devices before the real UI is built.
// Steps are in docs/development.md, "가족 공유 스파이크".

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

@MainActor
final class FamilySharingController: ObservableObject {
    @Published private(set) var spaces: [SharedSpaceRecord] = []
    @Published private(set) var changeCount = 0
    @Published private(set) var log: [String] = []
    @Published var presentedShare: PresentedShare?

    struct PresentedShare: Identifiable {
        let id = UUID()
        let share: CKShare
    }

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
            self?.changeCount += 1
        }
        host.start()
        PendingShareInvitations.shared.onReceive = { [weak self] in self?.acceptPendingInvitations()
        }
        acceptPendingInvitations()
    }

    func entries(in space: SharedSpaceRecord) -> [JournalEntryRecord] {
        (try? store.cache(for: space.id).list(kind: nil, includeDeleted: false, limit: 500)) ?? []
    }

    func createSpace(named name: String) async {
        let space = SharedSpaceRecord(scope: .notebook, name: name, role: .owner)
        await run("공유 만들기 \(name)") {
            let share = try await service.createShare(for: space)
            store.addSpace(space)
            presentedShare = PresentedShare(share: share)
        }
    }

    func manageShare(of space: SharedSpaceRecord) async {
        await run("공유 관리 \(space.name)") {
            if let share = try await service.existingShare(for: space) {
                presentedShare = PresentedShare(share: share)
            } else {
                append("공유 레코드를 찾지 못했습니다.")
            }
        }
    }

    func save(title: String, body: String, entry: JournalEntryRecord?, in space: SharedSpaceRecord)
        async
    {
        var draft = entry?.draft ?? JournalEntryDraft(kind: .prayer)
        draft.title = title
        draft.body = body
        await run("저장 \(title)") {
            try store.save(draft, kind: Self.prayerKind, in: space.id)
            try await host.sendChanges()
        }
    }

    func fetchNow(quietly: Bool = false) async {
        do {
            try await host.fetchChanges()
            if !quietly { append("가져오기 완료") }
        } catch {
            append("가져오기 실패: \(error.localizedDescription)")
        }
    }

    func stopSharing(_ space: SharedSpaceRecord) async {
        await run("공유 중지 \(space.name)") {
            try await service.stopSharing(space)
            if let zoneID = store.zoneID(for: space.id) { store.removeSpace(zoneID: zoneID) }
        }
    }

    func leave(_ space: SharedSpaceRecord) async {
        guard let zoneID = store.zoneID(for: space.id) else { return }
        await run("나가기 \(space.name)") {
            try await service.leave(zoneID: zoneID)
            store.removeSpace(zoneID: zoneID)
        }
    }

    private func acceptPendingInvitations() {
        for metadata in PendingShareInvitations.shared.drain() {
            Task {
                await run("초대 수락") {
                    let space = try await service.accept(metadata)
                    store.addSpace(space, zoneOwnerName: metadata.share.recordID.zoneID.ownerName)
                    try await host.fetchChanges()
                }
            }
        }
    }

    private func run(_ label: String, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            append("\(label): 성공")
        } catch {
            append("\(label): 실패 — \(error.localizedDescription)")
        }
    }

    private func append(_ line: String) {
        let time = Date.now.formatted(date: .omitted, time: .standard)
        log.insert("\(time) \(line)", at: 0)
        log = Array(log.prefix(50))
    }

    private static let prayerKind = SharedKindSnapshot(
        kind: .prayer, name: BuiltInKind.prayer.defaultName, colorToken: .amber,
        iconToken: "hands.sparkles")
}

// MARK: - Screens

struct FamilySharingDebugView: View {
    @ObservedObject var controller: FamilySharingController
    @State private var newSpaceName = "우리집 기도제목"

    var body: some View {
        Form {
            Section("새 공유") {
                TextField("이름", text: $newSpaceName)
                Button("만들고 초대하기") {
                    Task { await controller.createSpace(named: newSpaceName) }
                }
                Text("iPhone에서 시스템 공유 화면이 열립니다. 다른 Apple ID에 메시지로 초대를 보내세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("공유됨") {
                if controller.spaces.isEmpty {
                    Text("아직 없습니다.").foregroundStyle(.secondary)
                }
                ForEach(controller.spaces) { space in
                    NavigationLink {
                        FamilySharingSpaceDebugView(controller: controller, space: space)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(space.name.isEmpty ? "(이름 받는 중)" : space.name)
                            Text(
                                "\(space.role == .owner ? "내가 소유" : "받음 · \(space.ownerName ?? "?")") · \(space.participantCount)명"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                Button("지금 가져오기") {
                    Task { await controller.fetchNow() }
                }
            }
            Section("기록") {
                ForEach(controller.log, id: \.self) { line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("가족 공유 실험")
        .sheet(item: $controller.presentedShare) { presented in
            #if os(iOS)
            CloudSharingSheet(share: presented.share, container: controller.container)
            #else
            MacShareInfo(share: presented.share)
            #endif
        }
    }
}

private struct FamilySharingSpaceDebugView: View {
    @ObservedObject var controller: FamilySharingController
    let space: SharedSpaceRecord
    @State private var editing: JournalEntryRecord?
    @State private var title = ""
    @State private var text = ""

    var body: some View {
        Form {
            Section(editing == nil ? "새 노트" : "노트 편집") {
                TextField("제목", text: $title)
                TextEditor(text: $text).frame(minHeight: 120)
                HStack {
                    Button("저장") {
                        let entry = editing
                        Task {
                            await controller.save(title: title, body: text, entry: entry, in: space)
                        }
                        editing = nil
                        title = ""
                        text = ""
                    }
                    if editing != nil {
                        Button("취소", role: .cancel) {
                            editing = nil
                            title = ""
                            text = ""
                        }
                    }
                }
            }
            Section("노트") {
                let _ = controller.changeCount
                ForEach(controller.entries(in: space)) { entry in
                    Button {
                        editing = entry
                        title = entry.title
                        text = entry.body
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.headline)
                            Text(entry.body).lineLimit(4)
                            Text(
                                "\(entry.updatedAt.formatted(date: .omitted, time: .standard)) · \(entry.modifiedByDeviceID.prefix(8))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                if space.role == .owner {
                    Button("참여자 관리") { Task { await controller.manageShare(of: space) } }
                    Button("공유 중지 (서버 사본 삭제)", role: .destructive) {
                        Task { await controller.stopSharing(space) }
                    }
                } else {
                    Button("나가기", role: .destructive) { Task { await controller.leave(space) } }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(space.name)
        // Pushes can be late or coalesced, so poll while the space is on screen.
        .task {
            while !Task.isCancelled {
                await controller.fetchNow(quietly: true)
                try? await Task.sleep(for: .seconds(8))
            }
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
        ) {
            print("Family sharing: share save failed: \(error)")
        }
    }
}
#else
private struct MacShareInfo: View {
    let share: CKShare

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS 초대 화면은 아직 없습니다. iPhone에서 참여자를 초대하세요.")
            if let url = share.url {
                Text(url.absoluteString).textSelection(.enabled).font(.caption.monospaced())
            }
        }
        .padding()
        .frame(minWidth: 360)
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
