import AuthenticationServices
import CloudKit
import Combine
import JournalData
import JournalDomain
import JournalSearch
import SwiftUI

#if PILGRIM_SWIFTDATA
import CoreData
import SwiftData
#endif

@main
@MainActor
struct PilgrimJournalApp: App {
    private static let cloudKitContainerIdentifier =
        "iCloud.com.dhouse.PilgrimJournal"
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("has-completed-onboarding") private var hasCompletedOnboarding = false
    @AppStorage(EditorTextScale.storageKey) private var editorTextScale =
        EditorTextScale.defaultValue
    @AppStorage(AppAppearance.storageKey) private var appearance =
        AppAppearance.defaultValue.rawValue
    @StateObject private var journalSession: JournalSessionController
    @StateObject private var appLock: AppLockCoordinator
    @StateObject private var authentication: AppleAuthenticationCoordinator

    private static var isVisualTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PILGRIM_VISUAL_TESTING"] == "1"
        #else
        false
        #endif
    }

    /// Skips the Apple sign-in gate while keeping the real store and CloudKit.
    ///
    /// Sign in with Apple needs Touch ID, which cannot be satisfied over screen
    /// sharing. This lets a DEBUG build reach the journal on a remote Mac so the
    /// Development CloudKit schema can be exercised. The value is used as the
    /// Apple user identifier that scopes the store.
    private static var developerSignInBypassUser: String? {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["PILGRIM_DEV_APPLE_USER"]
        return (value?.isEmpty == false) ? value : nil
        #else
        return nil
        #endif
    }

    /// Creates every canonical CloudKit record type, then exits.
    ///
    /// Runs before the sign-in gate on purpose: the schema lives in the
    /// CloudKit container, not in a user's journal, and Sign in with Apple
    /// needs Touch ID, which a screen-shared Mac cannot provide.
    ///
    /// Invoke with `PILGRIM_DEPLOY_CLOUDKIT_SCHEMA=1`. Only the Development
    /// environment accepts this, so it must run from a Debug build; promote to
    /// Production from the CloudKit Console afterwards.
    private static func deployDevelopmentSchemaIfRequested(
        containerIdentifier: String
    ) {
        #if DEBUG && PILGRIM_SWIFTDATA
        guard
            ProcessInfo.processInfo.environment[
                "PILGRIM_DEPLOY_CLOUDKIT_SCHEMA"
            ] == "1"
        else { return }
        do {
            let types =
                try CloudKitSchemaInitializer
                .initializeDevelopmentSchema(
                    cloudKitContainerIdentifier: containerIdentifier
                )
            print("CloudKit Development 스키마 배포 완료: \(types.joined(separator: ", "))")
            exit(0)
        } catch {
            print("CloudKit 스키마 배포 실패: \(error.localizedDescription)")
            exit(1)
        }
        #endif
    }

    /// Deletes every journal record, on this device and in CloudKit, then exits.
    ///
    /// Keeps the deployed schema: the record types live in the container, the
    /// rows live in zones, and only the zones are dropped.
    ///
    /// Invoke with `PILGRIM_WIPE_JOURNAL_DATA=1`. The CloudKit environment
    /// follows the build's entitlement, so a Debug build empties Development
    /// and a production-signed build empties Production.
    ///
    /// Add `PILGRIM_WIPE_LOCAL_DATA=1` to drop this device's stores too. Any
    /// device that keeps its copy re-creates the zone and re-uploads on next
    /// launch, which undoes the wipe.
    private static func wipeJournalDataIfRequested(
        containerIdentifier: String
    ) {
        #if DEBUG
        guard
            ProcessInfo.processInfo.environment[
                "PILGRIM_WIPE_JOURNAL_DATA"
            ] == "1"
        else { return }
        let identifier = containerIdentifier
        let alsoWipesLocal =
            ProcessInfo.processInfo.environment[
                "PILGRIM_WIPE_LOCAL_DATA"
            ] == "1"
        Task.detached {
            do {
                let zones = try await CloudKitDataWiper.wipePrivateData(
                    containerIdentifier: identifier
                )
                print("CloudKit 존 삭제: \(zones.isEmpty ? "없음" : zones.joined(separator: ", "))")
                if alsoWipesLocal {
                    let local = try CloudKitDataWiper.wipeLocalData(
                        rootURL: JournalPaths.applicationRoot()
                    )
                    print("로컬 삭제: \(local.isEmpty ? "없음" : local.joined(separator: ", "))")
                } else {
                    print("로컬 저장소는 그대로 둡니다.")
                }
                exit(0)
            } catch {
                print("데이터 삭제 실패: \(error.localizedDescription)")
                exit(1)
            }
        }
        // The task owns the exit, so the app must not reach its scene.
        dispatchMain()
        #endif
    }

    init() {
        let requestedCloudIdentifier =
            ProcessInfo.processInfo.environment[
                "PILGRIM_CLOUDKIT_CONTAINER"
            ] ?? Self.cloudKitContainerIdentifier
        Self.deployDevelopmentSchemaIfRequested(
            containerIdentifier: requestedCloudIdentifier
        )
        Self.wipeJournalDataIfRequested(
            containerIdentifier: requestedCloudIdentifier
        )
        let cloudKitEnabled =
            !Self.isVisualTesting
            && CloudKitEntitlement.includes(
                containerIdentifier: requestedCloudIdentifier
            )
        let appLockStore: any SecureValueStore =
            Self.isVisualTesting
            ? InMemorySecureValueStore()
            : KeychainSecureValueStore()
        let appLock = AppLockCoordinator(service: AppLockService(store: appLockStore))
        _appLock = StateObject(wrappedValue: appLock)
        let isVisualTesting = Self.isVisualTesting
        let visualTestingRoot = FileManager.default.temporaryDirectory.appending(
            path: "PilgrimJournal-VisualTesting-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let sessionService = AppleAuthenticationSessionService()
        // Only a real Apple user's iCloud data is erased; the visual-testing,
        // developer-bypass and entitlement-less builds keep the cloud step a
        // no-op, matching how they skip the identity binding below.
        let cloudEraser: (any CloudAccountDataErasing)? =
            cloudKitEnabled && Self.developerSignInBypassUser == nil
            ? CloudKitAccountDataEraser(containerIdentifier: requestedCloudIdentifier)
            : nil
        let accountDeleter = AccountDeletionService(
            rootURLProvider: {
                isVisualTesting ? visualTestingRoot : try JournalPaths.applicationRoot()
            },
            cloudEraser: cloudEraser,
            sessionService: sessionService,
            appLockStore: appLockStore,
            standardDefaultsKeys: ["has-completed-onboarding"],
            cloudKeyValueKeys: AppModel.cloudKeyValueKeys + [KindCatalogStore.key],
            temporaryItems: [
                FileManager.default.temporaryDirectory.appending(
                    path: "AttachmentPreview",
                    directoryHint: .isDirectory
                )
            ]
        )
        let cloudIdentityChecker: any CloudIdentityBindingChecking
        if Self.isVisualTesting {
            cloudIdentityChecker = VisualTestingCloudIdentityChecker()
        } else if Self.developerSignInBypassUser != nil {
            // The bypass user is not a real Apple identifier, so binding it to
            // the CloudKit account would block access. Mirroring is unaffected.
            cloudIdentityChecker = OfflineCloudIdentityChecker()
        } else if !cloudKitEnabled {
            cloudIdentityChecker = OfflineCloudIdentityChecker()
        } else {
            cloudIdentityChecker = CloudIdentityBindingService(
                store: CloudKitIdentityBindingStore(
                    containerIdentifier: requestedCloudIdentifier
                )
            )
        }
        _authentication = StateObject(
            wrappedValue: AppleAuthenticationCoordinator(
                service: sessionService,
                cloudIdentityChecker: cloudIdentityChecker,
                accountDeleter: accountDeleter,
                bypassForVisualTesting: Self.isVisualTesting
                    || Self.developerSignInBypassUser != nil
            )
        )
        _journalSession = StateObject(
            wrappedValue: JournalSessionController(
                rootURLProvider: {
                    isVisualTesting ? visualTestingRoot : try JournalPaths.applicationRoot()
                },
                cloudKitContainerIdentifier: cloudKitEnabled ? requestedCloudIdentifier : nil,
                isVisualTesting: isVisualTesting
            ))
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                switch authentication.state {
                case .checking:
                    AppleAuthenticationCheckingView()
                case .authenticated:
                    if let appModel = journalSession.appModel {
                        ContentView()
                            .environmentObject(appModel)
                            .allowsHitTesting(!appLock.isLocked)
                        if appLock.isLocked {
                            AppLockView()
                        }
                    } else if let message = journalSession.errorMessage {
                        JournalSessionErrorView(message: message) {
                            Task { await prepareJournalSession() }
                        }
                    } else {
                        AppleAuthenticationCheckingView()
                    }
                case .signedOut, .blockedDifferentUser,
                    .blockedCloudAccountMismatch, .failed:
                    AppleSignInView()
                }
                if authentication.canAccessJournal,
                    appLock.isPrivacyShieldVisible
                {
                    PrivacyShieldView()
                }
                if authentication.accountDeletionPhase != .idle {
                    AccountDeletionStatusView(
                        phase: authentication.accountDeletionPhase,
                        retry: {
                            Task { await authentication.deleteAccount(using: journalSession) }
                        },
                        returnToJournal: {
                            authentication.dismissAccountDeletionFailure()
                            Task { await prepareJournalSession() }
                        }
                    )
                }
            }
            .environmentObject(appLock)
            .environmentObject(authentication)
            .environmentObject(journalSession)
            .onAppear { AppAppearance(storedValue: appearance).apply() }
            .onChange(of: appearance) { _, newValue in
                AppAppearance(storedValue: newValue).apply()
            }
            .sheet(
                isPresented: Binding(
                    get: {
                        // Account deletion resets onboarding while the
                        // journal is still authenticated; don't pop it then.
                        authentication.canAccessJournal
                            && !hasCompletedOnboarding
                            && !Self.isVisualTesting
                            && authentication.accountDeletionPhase == .idle
                    },
                    set: { _ in }
                )
            ) {
                OnboardingView {
                    hasCompletedOnboarding = true
                }
            }
            .task {
                await authentication.bootstrap()
                await prepareJournalSession()
            }
            .onChange(of: authentication.canAccessJournal) { _, canAccess in
                if canAccess {
                    Task { await prepareJournalSession() }
                } else {
                    journalSession.deactivate()
                }
            }
            .onChange(of: authentication.didCompleteAccountDeletion) { _, didDelete in
                if didDelete {
                    appLock.resetAfterAccountDeletion()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .CKAccountChanged)
            ) { _ in
                Task {
                    // Reopening the store mid-deletion would re-upload it.
                    guard !authentication.isDeletingAccount else { return }
                    await authentication.refreshCloudIdentityBinding()
                    guard authentication.canAccessJournal,
                        let identifier = authentication.currentUserIdentifier
                    else {
                        journalSession.deactivate()
                        return
                    }
                    await journalSession.activate(
                        appleUserIdentifier: identifier,
                        forceRefresh: true
                    )
                    await journalSession.appModel?.refreshCloudAccountState()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSUbiquitousKeyValueStore.didChangeExternallyNotification
                )
            ) { _ in
                journalSession.appModel?.refreshNotebookCatalog()
                journalSession.appModel?.refresh()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: ASAuthorizationAppleIDProvider
                        .credentialRevokedNotification
                )
            ) { _ in
                Task { await authentication.handleCredentialRevoked() }
            }
            #if PILGRIM_SWIFTDATA
            .onReceive(
                NotificationCenter.default.publisher(for: ModelContext.didSave)
                    .receive(on: RunLoop.main)
            ) { notification in
                if let change = JournalStoreChangeExtractor.extract(from: notification) {
                    journalSession.appModel?.handleJournalStoreChange(change)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSPersistentCloudKitContainer.eventChangedNotification
                )
                .receive(on: RunLoop.main)
            ) { notification in
                if let event = cloudSyncStoreEvent(from: notification) {
                    journalSession.appModel?.handleCloudSyncStoreEvent(event)
                }
            }
            #endif
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    if authentication.canAccessJournal {
                        appLock.sceneDidBecomeActive()
                        Task {
                            await authentication.refreshCredentialState()
                            await journalSession.appModel?.refreshCloudAccountState()
                        }
                    }
                case .inactive:
                    if authentication.canAccessJournal {
                        appLock.sceneWillResignActive()
                    }
                case .background:
                    if authentication.canAccessJournal {
                        appLock.sceneDidEnterBackground()
                    }
                @unknown default:
                    if authentication.canAccessJournal {
                        appLock.sceneWillResignActive()
                    }
                }
            }
        }
        #if os(macOS)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("새 기록") { journalSession.appModel?.beginNewEntry() }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(!authentication.canAccessJournal)
            }
            CommandGroup(after: .newItem) {
                Button("Day One 가져오기…") {
                    journalSession.appModel?.isPresentingImporter = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!authentication.canAccessJournal)
            }
            CommandGroup(replacing: .appSettings) {
                Button("설정…") { journalSession.appModel?.showSettings() }
                .keyboardShortcut(",", modifiers: [.command])
                .disabled(!authentication.canAccessJournal)
            }
            CommandGroup(after: .saveItem) {
                Button("지금 저장") {
                    NotificationCenter.default.post(
                        name: .saveJournalEntry,
                        object: nil
                    )
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!authentication.canAccessJournal)
            }
            CommandGroup(after: .sidebar) {
                Button("사이드바 표시/숨기기") {
                    NotificationCenter.default.post(
                        name: .toggleJournalSidebar,
                        object: nil
                    )
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!authentication.canAccessJournal)
                Button("집중 모드 전환") {
                    NotificationCenter.default.post(
                        name: .toggleJournalFocusMode,
                        object: nil
                    )
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!authentication.canAccessJournal)
                // Text size lives in the system View menu. A separate
                // CommandMenu("보기") showed up as a second 보기 once the
                // system menus became Korean.
                Divider()
                Button("확대") { adjustEditorTextScale(by: 0.1) }
                .keyboardShortcut("+", modifiers: [.command])
                Button("축소") { adjustEditorTextScale(by: -0.1) }
                .keyboardShortcut("-", modifiers: [.command])
                Button("기본 크기") {
                    editorTextScale = EditorTextScale.defaultValue
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
            CommandMenu("기록") {
                Button("검색") { post(.focusJournalSearch) }
                .keyboardShortcut("f", modifiers: [.command])
                Divider()
                Button("이전 기록") { post(.navigateToPreviousJournalEntry) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("다음 기록") { post(.navigateToNextJournalEntry) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            CommandMenu("Markdown") {
                markdownCommand(String(localized: "굵게"), command: .bold, key: "b")
                markdownCommand(String(localized: "기울임"), command: .italic, key: "i")
                markdownCommand(String(localized: "링크"), command: .link, key: "k")
                Divider()
                markdownCommand(
                    String(localized: "번호 목록"),
                    command: .numberedList,
                    key: "7",
                    modifiers: [.command, .shift]
                )
                markdownCommand(
                    String(localized: "글머리표 목록"),
                    command: .bulletList,
                    key: "8",
                    modifiers: [.command, .shift]
                )
                markdownCommand(
                    String(localized: "인용문"),
                    command: .quote,
                    key: "9",
                    modifiers: [.command, .shift]
                )
                Divider()
                markdownCommand(
                    String(localized: "제목 1"),
                    command: .heading1,
                    key: "1",
                    modifiers: [.command, .option]
                )
                markdownCommand(
                    String(localized: "제목 2"),
                    command: .heading2,
                    key: "2",
                    modifiers: [.command, .option]
                )
                markdownCommand(
                    String(localized: "제목 3"),
                    command: .heading3,
                    key: "3",
                    modifiers: [.command, .option]
                )
            }
        }
        #endif
    }

    #if os(macOS)
    private func adjustEditorTextScale(by amount: Double) {
        editorTextScale = min(
            EditorTextScale.maximum,
            max(EditorTextScale.minimum, editorTextScale + amount)
        )
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    private func markdownCommand(
        _ title: String,
        command: MarkdownKeyboardCommand,
        key: KeyEquivalent,
        modifiers: EventModifiers = [.command]
    ) -> some View {
        Button(title) {
            NotificationCenter.default.post(
                name: .applyMarkdownKeyboardCommand,
                object: command.rawValue
            )
        }
        .keyboardShortcut(key, modifiers: modifiers)
        .disabled(!authentication.canAccessJournal)
    }
    #endif

    private func prepareJournalSession() async {
        guard authentication.canAccessJournal,
            !authentication.isDeletingAccount
        else { return }
        let identifier: String
        if Self.isVisualTesting {
            identifier = "visual-testing-user"
        } else if let bypassUser = Self.developerSignInBypassUser {
            identifier = bypassUser
        } else if let current = authentication.currentUserIdentifier {
            identifier = current
        } else {
            return
        }
        await journalSession.activate(appleUserIdentifier: identifier)
        guard let appModel = journalSession.appModel else { return }
        await appLock.bootstrap()
        await appModel.refreshCloudAccountState()
        #if DEBUG
        if Self.isVisualTesting {
            seedVisualTestingContentIfNeeded()
        }
        #endif
        appModel.refreshNotebookCatalog()
        appModel.refresh()
    }

    #if DEBUG
    private func seedVisualTestingContentIfNeeded() {
        guard let appModel = journalSession.appModel else { return }
        guard
            (try? appModel.repository.list(
                kind: nil,
                includeDeleted: false,
                limit: 1
            ).isEmpty) == true
        else { return }

        let calendar = Calendar(identifier: .gregorian)
        let baseDate =
            calendar.date(
                from: DateComponents(
                    timeZone: TimeZone(identifier: "Asia/Seoul"),
                    year: 2026,
                    month: 8,
                    day: 9,
                    hour: 7,
                    minute: 30
                )
            ) ?? .now
        let fixtures: [(JournalKind, String, String, String, [String], EntryDetails)] = [
            (
                .prayer,
                "오늘의 감사와 기도",
                "# 감사\n\n고요한 아침을 주셔서 감사합니다.\n\n* 가족의 건강과 평안을 위해\n* 새로운 한 주의 지혜를 위해",
                "아침 묵상",
                ["감사", "가족"],
                EntryDetails(prayerStatus: .ongoing)
            ),
            (
                .bibleStudy,
                "로마서 8장 — 끊을 수 없는 사랑",
                "## 관찰\n\n현재의 고난은 장차 나타날 영광과 비교할 수 없다. Nothing can separate us from the love of God.",
                "로마서",
                ["말씀", "은혜"],
                EntryDetails(scriptureReference: "로마서 8:18–39")
            ),
            (
                .reading,
                "긴 문장과 English title이 함께 있는 독서 기록의 레이아웃 확인",
                "### 기억할 문장\n\n좋은 문장은 생각의 속도를 늦추고, 익숙한 하루를 새롭게 바라보게 한다. This paragraph intentionally mixes Korean and English to verify wrapping and readability at large text sizes.",
                "2026 독서",
                ["문장", "사유", "천천히"],
                EntryDetails(bookTitle: "고요함의 기술", bookAuthor: "김순례")
            ),
            (
                .diary,
                "비가 그친 오후",
                "창문을 열자 젖은 나무 냄새가 들어왔다.\n\n---\n\n오늘은 서두르지 않고 해야 할 일을 하나씩 마쳤다.",
                "일상",
                ["여름", "기록"],
                EntryDetails(mood: "평온")
            ),
        ]

        var savedRecords: [JournalEntryRecord] = []
        for (index, fixture) in fixtures.enumerated() {
            var draft = JournalEntryDraft(
                kind: fixture.0,
                title: fixture.1,
                body: fixture.2,
                occurredAt: calendar.date(
                    byAdding: .day,
                    value: -index,
                    to: baseDate
                ) ?? baseDate,
                tags: fixture.4,
                isStarred: index == 1,
                isPinned: index == 0,
                details: fixture.5
            )
            draft.notebookName = fixture.3
            if let record = appModel.saveAndReturnRecord(
                draft,
                closeEditor: false,
                selectSavedEntry: false
            ) {
                savedRecords.append(record)
            }
        }

        switch ProcessInfo.processInfo.environment["PILGRIM_VISUAL_TEST_SCREEN"] {
        case "search-empty":
            appModel.searchText = "일치하지 않는 검색어"
            appModel.refresh()
        case "detail":
            appModel.selectEntry(savedRecords.first?.id)
        case "editor":
            if let reading = savedRecords.first(where: { $0.kind == .reading }) {
                appModel.beginEditing(reading)
            }
        case "editor-long":
            // A body several screens tall. Short fixtures can't show whether
            // a long entry actually scrolls, which is exactly where the
            // iPhone editor's nested-scroll-view bug lived.
            var long = JournalEntryDraft(
                kind: .diary,
                title: "긴 본문 스크롤 확인",
                body: (1...60)
                    .map { "\($0)번째 문단 — 본문이 화면보다 길어졌을 때 스크롤되는지 확인하기 위한 문장이다." }
                    .joined(separator: "\n\n"),
                occurredAt: baseDate
            )
            long.notebookName = "레이아웃 확인"
            if let record = appModel.saveAndReturnRecord(
                long, closeEditor: false, selectSavedEntry: false
            ) {
                appModel.beginEditing(record)
            }
        default:
            break
        }
    }
    #endif
}

private struct JournalSessionErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("저장소를 열 수 없습니다")
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("다시 시도", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JournalTheme.canvas)
    }
}

private struct VisualTestingCloudIdentityChecker: CloudIdentityBindingChecking {
    func verifyOrBind(
        userIdentifier: String
    ) async -> CloudIdentityBindingResult {
        .matched
    }
}

private struct OfflineCloudIdentityChecker: CloudIdentityBindingChecking {
    func verifyOrBind(
        userIdentifier: String
    ) async -> CloudIdentityBindingResult {
        .unavailable(reason: String(localized: "이 빌드에는 iCloud 권한이 없어 로컬 모드로 실행합니다."))
    }
}

#if PILGRIM_SWIFTDATA
private func cloudSyncStoreEvent(
    from notification: Notification
) -> CloudSyncStoreEvent? {
    guard
        notification.name
            == NSPersistentCloudKitContainer.eventChangedNotification,
        let event = notification.userInfo?[
            NSPersistentCloudKitContainer.eventNotificationUserInfoKey
        ] as? NSPersistentCloudKitContainer.Event
    else {
        return nil
    }
    let operation: CloudSyncStoreOperation =
        switch event.type {
        case .setup: .setup
        case .import: .importing
        case .export: .exporting
        @unknown default: .setup
        }
    let errorPresentation = cloudSyncErrorPresentation(for: event.error)
    return CloudSyncStoreEvent(
        operation: operation,
        completedAt: event.endDate,
        succeeded: event.succeeded,
        errorDescription: errorPresentation?.message,
        errorRetryable: errorPresentation?.retryable
    )
}

struct CloudSyncErrorPresentation: Equatable {
    var message: String
    var retryable: Bool
}

func cloudSyncErrorPresentation(
    for error: Error?
) -> CloudSyncErrorPresentation? {
    guard let error else { return nil }
    let errors = flattenedCloudErrors(error as NSError)

    if errors.contains(where: {
        cloudDiagnosticText($0).localizedCaseInsensitiveContains(
            "cannot create new type"
        )
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "CloudKit 프로덕션 스키마가 아직 배포되지 않았습니다."),
            retryable: false
        )
    }
    if errors.contains(where: {
        $0.domain == CKErrorDomain && $0.code == CKError.notAuthenticated.rawValue
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "iCloud에 로그인한 뒤 동기화를 다시 시도하세요."),
            retryable: true
        )
    }
    if errors.contains(where: {
        $0.domain == CKErrorDomain && $0.code == CKError.quotaExceeded.rawValue
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "iCloud 저장 공간이 부족해 동기화할 수 없습니다."),
            retryable: false
        )
    }
    if errors.contains(where: {
        guard $0.domain == CKErrorDomain else { return false }
        return [
            CKError.networkUnavailable,
            .networkFailure,
            .serviceUnavailable,
            .requestRateLimited,
            .zoneBusy,
        ].map(\.rawValue).contains($0.code)
    }) {
        return CloudSyncErrorPresentation(
            message: String(localized: "네트워크 또는 CloudKit 서비스가 일시적으로 불안정합니다."),
            retryable: true
        )
    }
    if errors.contains(where: {
        $0.domain == CKErrorDomain && $0.code == CKError.partialFailure.rawValue
    }) {
        let detail = errors.dropFirst().first.map { cloudDiagnosticText($0) }
        return CloudSyncErrorPresentation(
            message: detail.map { String(localized: "일부 기록 동기화에 실패했습니다: \($0)") }
                ?? String(localized: "일부 기록 동기화에 실패했습니다."),
            retryable: true
        )
    }
    return CloudSyncErrorPresentation(
        message: error.localizedDescription,
        retryable: true
    )
}

private func flattenedCloudErrors(
    _ error: NSError,
    depth: Int = 0
) -> [NSError] {
    guard depth < 8 else { return [error] }
    var result = [error]
    if let partial = error.userInfo[CKPartialErrorsByItemIDKey]
        as? [AnyHashable: NSError]
    {
        for nested in partial.values {
            result.append(contentsOf: flattenedCloudErrors(nested, depth: depth + 1))
        }
    }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        result.append(contentsOf: flattenedCloudErrors(underlying, depth: depth + 1))
    }
    return result
}

private func cloudDiagnosticText(_ error: NSError) -> String {
    [
        error.localizedDescription,
        error.localizedFailureReason,
        error.userInfo[NSDebugDescriptionErrorKey] as? String,
        error.userInfo["CKErrorDescription"] as? String,
    ]
    .compactMap { $0 }
    .joined(separator: " ")
}
#endif
