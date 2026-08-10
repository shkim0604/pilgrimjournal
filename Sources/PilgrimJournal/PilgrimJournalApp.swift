import AuthenticationServices
import DayOneImport
import CloudKit
import Combine
import JournalBackup
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
    @AppStorage("editor-text-scale") private var editorTextScale =
        EditorTextScale.defaultValue
    @StateObject private var appModel: AppModel
    @StateObject private var appLock: AppLockCoordinator
    @StateObject private var authentication: AppleAuthenticationCoordinator
    @State private var hasPreparedJournalSession = false

    private static var isVisualTesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PILGRIM_VISUAL_TESTING"] == "1"
        #else
        false
        #endif
    }

    init() {
        let appLock = Self.isVisualTesting
            ? AppLockCoordinator(
                service: AppLockService(store: InMemorySecureValueStore())
            )
            : AppLockCoordinator()
        _appLock = StateObject(wrappedValue: appLock)
        let cloudIdentityChecker: any CloudIdentityBindingChecking
        if Self.isVisualTesting {
            cloudIdentityChecker = VisualTestingCloudIdentityChecker()
        } else {
            cloudIdentityChecker = CloudIdentityBindingService(
                store: CloudKitIdentityBindingStore(
                    containerIdentifier: Self.cloudKitContainerIdentifier
                )
            )
        }
        _authentication = StateObject(
            wrappedValue: AppleAuthenticationCoordinator(
                cloudIdentityChecker: cloudIdentityChecker,
                bypassForVisualTesting: Self.isVisualTesting
            )
        )
        do {
            #if PILGRIM_SWIFTDATA
            let cloudIdentifier = ProcessInfo.processInfo.environment[
                "PILGRIM_CLOUDKIT_CONTAINER"
            ] ?? Self.cloudKitContainerIdentifier
            let container = try JournalContainerFactory.make(
                inMemory: Self.isVisualTesting,
                cloudKitContainerIdentifier: Self.isVisualTesting ? nil : cloudIdentifier
            )
            let paths = try Self.isVisualTesting
                ? JournalPaths(
                    root: FileManager.default.temporaryDirectory.appending(
                        path: "PilgrimJournal-VisualTesting-\(UUID().uuidString)",
                        directoryHint: .isDirectory
                    )
                )
                : JournalPaths.applicationDefault()
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
                cloudAccountMonitor: Self.isVisualTesting
                    ? nil
                    : CloudAccountMonitor(containerIdentifier: cloudIdentifier),
                notebookDefaults: Self.isVisualTesting
                    ? (UserDefaults(suiteName: "PilgrimJournalVisualTesting") ?? .standard)
                    : .standard
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
                switch authentication.state {
                case .checking:
                    AppleAuthenticationCheckingView()
                case .authenticated:
                    ContentView()
                        .environmentObject(appModel)
                        .allowsHitTesting(!appLock.isLocked)
                    if appLock.isLocked {
                        AppLockView()
                    }
                case .signedOut, .blockedDifferentUser,
                     .blockedCloudAccountMismatch, .failed:
                    AppleSignInView()
                }
                if authentication.canAccessJournal,
                   appLock.isPrivacyShieldVisible {
                    PrivacyShieldView()
                }
            }
            .environmentObject(appLock)
            .environmentObject(authentication)
            .sheet(
                isPresented: Binding(
                    get: {
                        authentication.canAccessJournal
                            && !hasCompletedOnboarding
                            && !Self.isVisualTesting
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
                await prepareJournalSessionIfNeeded()
            }
            .onChange(of: authentication.canAccessJournal) { _, canAccess in
                if canAccess {
                    Task { await prepareJournalSessionIfNeeded() }
                } else {
                    hasPreparedJournalSession = false
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: .CKAccountChanged)
            ) { _ in
                Task {
                    await authentication.refreshCloudIdentityBinding()
                    await appModel.refreshCloudAccountState()
                }
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
                    appModel.handleJournalStoreChange(change)
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: NSPersistentCloudKitContainer.eventChangedNotification
                )
                .receive(on: RunLoop.main)
            ) { notification in
                if let event = cloudSyncStoreEvent(from: notification) {
                    appModel.handleCloudSyncStoreEvent(event)
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
                            await appModel.refreshCloudAccountState()
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
                Button("새 기록") { appModel.beginNewEntry() }
                    .keyboardShortcut("n", modifiers: [.command])
                    .disabled(!authentication.canAccessJournal)
            }
            CommandGroup(after: .newItem) {
                Button("Day One 가져오기…") { appModel.isPresentingImporter = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(!authentication.canAccessJournal)
            }
            CommandGroup(replacing: .appSettings) {
                Button("설정…") { appModel.showSettings() }
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
            }
            CommandMenu("보기") {
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
                markdownCommand("굵게", command: .bold, key: "b")
                markdownCommand("기울임", command: .italic, key: "i")
                markdownCommand("링크", command: .link, key: "k")
                Divider()
                markdownCommand(
                    "번호 목록",
                    command: .numberedList,
                    key: "7",
                    modifiers: [.command, .shift]
                )
                markdownCommand(
                    "글머리표 목록",
                    command: .bulletList,
                    key: "8",
                    modifiers: [.command, .shift]
                )
                markdownCommand(
                    "인용문",
                    command: .quote,
                    key: "9",
                    modifiers: [.command, .shift]
                )
                Divider()
                markdownCommand(
                    "제목 1",
                    command: .heading1,
                    key: "1",
                    modifiers: [.command, .option]
                )
                markdownCommand(
                    "제목 2",
                    command: .heading2,
                    key: "2",
                    modifiers: [.command, .option]
                )
                markdownCommand(
                    "제목 3",
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

    private func prepareJournalSessionIfNeeded() async {
        guard authentication.canAccessJournal,
              !hasPreparedJournalSession else { return }
        hasPreparedJournalSession = true
        await appLock.bootstrap()
        await appModel.refreshCloudAccountState()
        #if DEBUG
        if Self.isVisualTesting {
            seedVisualTestingContentIfNeeded()
        }
        #endif
        appModel.refresh()
    }

    #if DEBUG
    private func seedVisualTestingContentIfNeeded() {
        guard (try? appModel.repository.list(
            kind: nil,
            includeDeleted: false,
            limit: 1
        ).isEmpty) == true else { return }

        let calendar = Calendar(identifier: .gregorian)
        let baseDate = calendar.date(
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
        default:
            break
        }
    }
    #endif
}

private struct VisualTestingCloudIdentityChecker: CloudIdentityBindingChecking {
    func verifyOrBind(
        userIdentifier: String
    ) async -> CloudIdentityBindingResult {
        .matched
    }
}

#if PILGRIM_SWIFTDATA
private func cloudSyncStoreEvent(
    from notification: Notification
) -> CloudSyncStoreEvent? {
    guard notification.name
            == NSPersistentCloudKitContainer.eventChangedNotification,
          let event = notification.userInfo?[
            NSPersistentCloudKitContainer.eventNotificationUserInfoKey
          ] as? NSPersistentCloudKitContainer.Event else {
        return nil
    }
    let operation: CloudSyncStoreOperation = switch event.type {
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

    if errors.contains(where: { cloudDiagnosticText($0).localizedCaseInsensitiveContains(
        "cannot create new type"
    ) }) {
        return CloudSyncErrorPresentation(
            message: "CloudKit 프로덕션 스키마가 아직 배포되지 않았습니다.",
            retryable: false
        )
    }
    if errors.contains(where: { $0.domain == CKErrorDomain && $0.code == CKError.notAuthenticated.rawValue }) {
        return CloudSyncErrorPresentation(
            message: "iCloud에 로그인한 뒤 동기화를 다시 시도하세요.",
            retryable: true
        )
    }
    if errors.contains(where: { $0.domain == CKErrorDomain && $0.code == CKError.quotaExceeded.rawValue }) {
        return CloudSyncErrorPresentation(
            message: "iCloud 저장 공간이 부족해 동기화할 수 없습니다.",
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
            message: "네트워크 또는 CloudKit 서비스가 일시적으로 불안정합니다.",
            retryable: true
        )
    }
    if errors.contains(where: { $0.domain == CKErrorDomain && $0.code == CKError.partialFailure.rawValue }) {
        let detail = errors.dropFirst().first.map { cloudDiagnosticText($0) }
        return CloudSyncErrorPresentation(
            message: detail.map { "일부 기록 동기화에 실패했습니다: \($0)" }
                ?? "일부 기록 동기화에 실패했습니다.",
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
        as? [AnyHashable: NSError] {
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
