import DayOneImport
import JournalBackup
import JournalData
import JournalDomain
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var authentication: AppleAuthenticationCoordinator
    @EnvironmentObject private var journalSession: JournalSessionController
    @State private var restoreMode = RestoreMode.merge
    @State private var isConfirmingRestore = false
    @State private var isConfirmingSignOut = false
    @AppStorage(AppAppearance.storageKey) private var appearance =
        AppAppearance.defaultValue.rawValue
    @State private var language = AppLanguage.current()
    /// The language the app launched with; differs from `language` until the
    /// app is reopened.
    @State private var launchedLanguage = AppLanguage.current()

    var body: some View {
        Form {
            Section("Apple 로그인") {
                LabeledContent(
                    "상태",
                    value: authentication.isUsingOfflineAuthorization
                        ? String(localized: "로그인됨 · 오프라인 확인")
                        : String(localized: "로그인됨")
                )
                if let account = authentication.accountDisplayName {
                    LabeledContent("계정", value: account)
                        .textSelection(.enabled)
                }
                Button("로그아웃", role: .destructive) {
                    isConfirmingSignOut = true
                }
                Text("로그아웃해도 이 기기의 일기 데이터는 삭제되지 않으며, 다시 인증하기 전까지 화면만 잠깁니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                NavigationLink {
                    AccountDeletionView()
                } label: {
                    Label("계정 삭제", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(.red)
                }
                Text("계정을 삭제하면 iCloud와 이 기기의 기록, 로그인 정보가 모두 지워집니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("동기화") {
                LabeledContent("상태", value: syncDescription)
                LabeledContent("저장 위치", value: storageLocationDescription)
                if journalSession.canReopenForSync {
                    Button {
                        // A local, not `journalSession` through self: the
                        // task would otherwise hold this view and with it the
                        // old model, which the reopen waits to be released.
                        let session = journalSession
                        Task { await session.reopenForManualSync() }
                    } label: {
                        Label("지금 동기화", systemImage: "arrow.triangle.2.circlepath.icloud")
                    }
                    .disabled(
                        journalSession.isReopeningForSync
                            || journalSession.isLoading
                            || model.isWorking
                            || model.isCloudImportInProgress
                    )
                    Text("iCloud 저장소를 다시 열어 다른 기기의 변경을 바로 받아오고 이 기기의 변경을 올립니다. 잠깐 화면이 다시 그려집니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "기록과 첨부는 현재 시스템 iCloud의 개인 데이터베이스에 저장됩니다. 이 저장 공간은 최초 연결한 Apple 로그인 사용자에게 귀속되며 다른 사용자는 차단됩니다."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let migration = journalSession.pendingMigration {
                Section("iCloud로 데이터 이전") {
                    Text(
                        "이 기기에만 저장된 기록 \(migration.entryCount)개가 있습니다. 현재 iCloud 계정의 별도 저장소로 복사한 뒤, 완료된 저장소로 전환할 수 있습니다."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button {
                        journalSession.confirmPendingMigration()
                    } label: {
                        Label("로컬 기록을 iCloud로 이전", systemImage: "icloud.and.arrow.up")
                    }
                    Button("이 기기에만 계속 저장") {
                        journalSession.keepLocalOnly()
                    }
                    if let error = journalSession.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            Section("검색") {
                Button("검색 인덱스 다시 만들기") { model.rebuildSearchIndex() }
                Text("검색 인덱스는 각 기기에만 저장되며 원본 기록에서 다시 만들 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("정리") {
                Button {
                    model.openKindManagement()
                } label: {
                    Label("유형 편집", systemImage: "slider.horizontal.3")
                }
                NavigationLink("태그 및 Day One 분류 규칙") {
                    OrganizationSettingsView()
                }
            }
            Section("데이터 관리") {
                Button {
                    model.refreshTrash()
                    model.isPresentingTrash = true
                } label: {
                    Label("휴지통 열기", systemImage: "trash")
                }
                #if os(macOS)
                Button {
                    model.isPresentingImporter = true
                } label: {
                    Label(
                        "Day One 가져오기…",
                        systemImage: "square.and.arrow.down"
                    )
                }
                #endif
            }
            Section("화면") {
                Picker("화면 모드", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text("시스템 설정을 고르면 기기의 라이트·다크 설정을 따릅니다. 이 기기에만 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("언어") {
                Picker("언어", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: language) { _, newValue in
                    newValue.apply()
                }
                if language != launchedLanguage {
                    #if os(macOS)
                    Button("지금 다시 시작") { AppLanguage.relaunch() }
                    #endif
                    Text("바꾼 언어는 앱을 다시 열면 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.brandPrimary)
                } else {
                    Text("시스템 설정을 고르면 기기의 언어를 따릅니다. 이 기기에만 적용됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("보안") {
                NavigationLink("앱 잠금") {
                    AppLockSettingsView()
                }
                Text("비밀번호와 잠금 설정은 이 기기에만 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("도움말") {
                NavigationLink {
                    AppUsageGuideView()
                } label: {
                    Label("앱 사용법", systemImage: "questionmark.circle")
                }
                Link(destination: SupportLinks.supportPage) {
                    Label("지원 페이지", systemImage: "safari")
                }
                Link(destination: SupportLinks.contactMail) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("이메일 문의")
                            Text(SupportLinks.contactEmail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "envelope")
                    }
                }
            }
            #if os(macOS)
            Section("백업 및 복원") {
                Toggle(
                    "Day One 원본 snapshot 포함",
                    isOn: $model.backupIncludesSourceSnapshots
                )
                Text(
                    "원본 snapshot에는 Day One의 전체 메타데이터가 들어갈 수 있습니다. 필요할 때만 포함하고 백업 파일을 민감한 데이터로 다루세요."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Button("전체 백업 내보내기…") {
                    Task { await model.prepareBackup() }
                }
                .disabled(model.isWorking)
                if let message = model.lastBackupExportMessage {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(JournalTheme.brandPrimary)
                        .textSelection(.enabled)
                }
                Picker("복원 방식", selection: $restoreMode) {
                    Text("병합").tag(RestoreMode.merge)
                    Text("현재 데이터 교체").tag(RestoreMode.replace)
                }
                Button("백업에서 복원…") { model.isImportingBackup = true }
                    .disabled(model.isWorking)
                if let description = model.dataOperationDescription {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let result = model.lastRestoreResult {
                    Text(
                        "최근 복원: \(result.restored)개 반영, \(result.tombstoned)개 휴지통, 충돌 \(result.conflicts)개"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !model.lastRestoreConflicts.isEmpty {
                    DisclosureGroup("충돌 기록 \(model.lastRestoreConflicts.count)개") {
                        ForEach(model.lastRestoreConflicts) { conflict in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(untitledFallback(conflict.currentTitle))
                                    .font(.caption.weight(.semibold))
                                if conflict.currentTitle != conflict.backupTitle {
                                    Text("백업: \(untitledFallback(conflict.backupTitle))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let safetyURL = model.lastSafetyBackupURL {
                    Text("교체 전 안전 백업: \(safetyURL.lastPathComponent)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("안전 백업으로 복귀") {
                        Task { await model.restoreSafetyBackup() }
                    }
                }
                if let failure = model.lastRestoreFailureMessage {
                    Text("최근 복원 실패: \(failure)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    if model.pendingRestoreData != nil {
                        Button("실패한 복원 다시 시도") {
                            Task { await model.retryPendingRestore(mode: restoreMode) }
                        }
                    }
                }
                Button("데이터 무결성 검사") { model.runIntegrityCheck() }
                if let report = model.lastIntegrityReport {
                    if report.isHealthy {
                        Label(
                            "문제가 없습니다 · 기록 \(report.entryCount)개, revision \(report.revisionCount)개, 첨부 \(report.attachmentCount)개",
                            systemImage: "checkmark.circle"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        DisclosureGroup("확인할 문제 \(report.issues.count)개") {
                            ForEach(report.issues) { issue in
                                Text(issue.message)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Text("검사는 데이터를 자동으로 삭제하거나 수정하지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
            Section("개인정보") {
                NavigationLink("데이터 및 개인정보") {
                    PrivacyInformationView(syncState: model.syncState)
                }
                Text(
                    "Apple 로그인은 앱 접근과 iCloud 저장 공간 귀속 확인에 사용합니다. Apple이 제공한 이메일은 계정 표시를 위해 기기 Keychain에 저장하며, 기록 동기화는 시스템 iCloud를 사용합니다. 앱 잠금은 추가 화면 보호 기능입니다."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle("설정")
        .confirmationDialog(
            "Apple 계정에서 로그아웃할까요?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("로그아웃", role: .destructive) {
                Task { await authentication.signOut() }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("일기 데이터는 삭제되지 않지만 다시 로그인하기 전까지 볼 수 없습니다.")
        }
        #if os(macOS)
        .fileExporter(
            isPresented: $model.isExportingBackup,
            document: model.backupDocument,
            contentType: .pilgrimJournalBackup,
            defaultFilename:
                "PilgrimJournal-\(Date.now.formatted(.iso8601.year().month().day())).journalbackup"
        ) { result in
            switch result {
            case let .success(url):
                model.lastBackupExportMessage = String(
                    localized: "백업을 저장했습니다 · \(url.lastPathComponent)")
                model.reportOutcome(
                    title: String(localized: "백업을 저장했습니다"),
                    message: url.path(percentEncoded: false)
                )
            case let .failure(error):
                // Dismissing the save panel is a choice, not a failure.
                if (error as NSError).code != NSUserCancelledError {
                    model.errorMessage = error.localizedDescription
                }
            }
            model.backupDocument = nil
        }
        .fileImporter(
            isPresented: $model.isImportingBackup,
            allowedContentTypes: [.pilgrimJournalBackup, .zip, .data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                model.pendingRestoreData = try Data(contentsOf: url)
                isConfirmingRestore = true
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            restoreMode == .replace ? "현재 데이터를 백업으로 교체할까요?" : "백업을 병합할까요?",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button(
                restoreMode == .replace ? "교체 복원" : "병합 복원",
                role: restoreMode == .replace ? .destructive : nil
            ) {
                if let data = model.pendingRestoreData {
                    Task { await model.restoreBackup(data: data, mode: restoreMode) }
                }
            }
            Button("취소", role: .cancel) { model.pendingRestoreData = nil }
        } message: {
            Text(
                restoreMode == .replace
                    ? "현재 상태의 안전 백업을 먼저 만든 뒤, 백업에 없는 기록을 휴지통으로 이동합니다."
                    : "같은 기록의 변경은 revision 충돌로 보존합니다."
            )
        }
        #endif
    }

    private var storageLocationDescription: String {
        switch journalSession.activeScope?.storageLocation {
        case .localOnly:
            String(localized: "이 기기만")
        case .iCloud(accountHash: _):
            String(localized: "현재 iCloud 계정")
        case nil:
            String(localized: "확인 중")
        }
    }

    private var syncDescription: String {
        switch model.syncState {
        case .localOnly: String(localized: "이 기기에만 저장")
        case .savedLocally: String(localized: "로컬 저장 완료")
        case .pending: String(localized: "동기화 대기")
        case let .synced(date): date?.formatted() ?? String(localized: "동기화됨")
        case let .unavailable(reason): String(localized: "사용 불가: \(reason)")
        case let .failed(message, _): String(localized: "오류: \(message)")
        }
    }

    private func untitledFallback(_ title: String) -> String {
        title.isEmpty ? String(localized: "제목 없음") : title
    }
}
