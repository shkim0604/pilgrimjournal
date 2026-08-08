import DayOneImport
import CloudKit
import Combine
import JournalBackup
import JournalData
import JournalDomain
import JournalSearch
import SwiftUI
#if PILGRIM_SWIFTDATA
import SwiftData
#endif

@main
@MainActor
struct PilgrimJournalApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("has-completed-onboarding") private var hasCompletedOnboarding = false
    @StateObject private var appModel: AppModel
    @StateObject private var appLock: AppLockCoordinator

    init() {
        _appLock = StateObject(wrappedValue: AppLockCoordinator())
        do {
            #if PILGRIM_SWIFTDATA
            let cloudIdentifier = ProcessInfo.processInfo.environment[
                "PILGRIM_CLOUDKIT_CONTAINER"
            ]
            let container = try JournalContainerFactory.make(
                cloudKitContainerIdentifier: cloudIdentifier
            )
            let paths = try JournalPaths.applicationDefault()
            try paths.prepare()
            let repository = SwiftDataJournalRepository(container: container)
            let searchIndex = try JournalSearchIndex(
                url: paths.search.appending(path: "journal-search.sqlite")
            )
            _appModel = StateObject(wrappedValue: AppModel(
                repository: repository,
                importStore: LocalImportStore(container: container),
                searchIndex: searchIndex,
                paths: paths,
                cloudAccountMonitor: cloudIdentifier.map(CloudAccountMonitor.init)
            ))
            #else
            let paths = try JournalPaths.applicationDefault()
            try paths.prepare()
            let searchIndex = try JournalSearchIndex(
                url: paths.search.appending(path: "journal-search.sqlite")
            )
            let repository = try InMemoryJournalRepository(
                storageURL: paths.root.appending(path: "journal-local.json")
            )
            _appModel = StateObject(wrappedValue: AppModel(
                repository: repository,
                importStore: InMemoryImportStore(),
                searchIndex: searchIndex,
                paths: paths,
                cloudAccountMonitor: nil
            ))
            #endif
        } catch {
            fatalError("Pilgrim Journal 초기화 실패: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appModel)
                    .allowsHitTesting(!appLock.isLocked)
                if appLock.isLocked {
                    AppLockView()
                }
                if appLock.isPrivacyShieldVisible {
                    PrivacyShieldView()
                }
            }
            .environmentObject(appLock)
            .sheet(
                isPresented: Binding(
                    get: { !hasCompletedOnboarding },
                    set: { _ in }
                )
            ) {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
            .task {
                await appLock.bootstrap()
                await appModel.refreshCloudAccountState()
                appModel.refresh()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .CKAccountChanged)
            ) { _ in
                Task { await appModel.refreshCloudAccountState() }
            }
            #if PILGRIM_SWIFTDATA
            .onReceive(
                NotificationCenter.default.publisher(for: ModelContext.didSave)
                    .receive(on: RunLoop.main)
            ) { notification in
                if let change = JournalStoreChangeExtractor.extract(from: notification) {
                    appModel.handleJournalStoreChange(change)
                }
            }
            #endif
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    appLock.sceneDidBecomeActive()
                    Task { await appModel.refreshCloudAccountState() }
                case .inactive:
                    appLock.sceneWillResignActive()
                case .background:
                    appLock.sceneDidEnterBackground()
                @unknown default:
                    appLock.sceneWillResignActive()
                }
            }
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .newItem) {
                Button("새 기록") { appModel.beginNewEntry() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Day One 가져오기…") { appModel.isPresentingImporter = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        #endif
    }
}
