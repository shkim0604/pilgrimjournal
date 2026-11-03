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
    #if DEBUG
    @AppStorage(PremiumCodeFeatureAccess.simulateLockedKey) private var simulateLocked = false
    #endif

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
                    Label(
                        "유형 편집",
                        systemImage: model.featureAccess.canManageKinds
                            ? "slider.horizontal.3" : "lock.fill"
                    )
                }
                NavigationLink("태그 및 Day One 분류 규칙") {
                    OrganizationSettingsView()
                }
            }
            Section("유료 기능") {
                if model.featureAccess.isPremium {
                    LabeledContent("상태", value: String(localized: "사용 중"))
                } else {
                    Button {
                        model.isPresentingPremiumNotice = true
                    } label: {
                        Label("코드 입력…", systemImage: "key")
                    }
                }
                Text("유형 추가·삭제·편집은 유료 기능입니다. 코드는 입력한 기기에만 적용됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            #if DEBUG
            Section("개발") {
                Toggle("유료 기능 잠금 시뮬레이션", isOn: $simulateLocked)
                if let access = model.featureAccess as? PremiumCodeFeatureAccess,
                    access.isPremium
                {
                    Button("유료 코드 해제 초기화") {
                        access.resetForTesting()
                        model.featureAccessDidChange()
                    }
                }
                Text("Debug 빌드에서만 보입니다. 켜면 유형 편집 대신 유료 안내가 뜹니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle("설정")
        #if DEBUG
        // `featureAccess` reads the flag but publishes nothing, so tell the
        // model to re-render the sidebar's 편집 label and gate.
        .onChange(of: simulateLocked) { _, _ in
            model.featureAccessDidChange()
        }
        #endif
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

#if os(macOS)
struct DayOneImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var isSelectingFile = false
    @State private var resultFilter = ResultFilter.all
    @State private var selectedImportItemIDs = Set<UUID>()
    @State private var importNotebookName = ""

    var body: some View {
        NavigationStack {
            Group {
                if case .analyzing = model.importActivity {
                    ContentUnavailableView {
                        Label("Day One 보관함 분석 중", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("ZIP 안전성과 JSON 구조를 확인하고 있습니다. 아직 일기 데이터는 변경되지 않았습니다.")
                    } actions: {
                        ProgressView()
                            .controlSize(.large)
                    }
                } else if let preview = model.importPreview,
                    let result = model.importResult
                {
                    resultView(preview: preview, result: result)
                } else if let preview = model.importPreview {
                    previewView(preview)
                } else {
                    ContentUnavailableView(
                        "Day One ZIP을 선택하세요",
                        systemImage: "square.and.arrow.down",
                        description: Text("분석 단계에서는 기록을 변경하지 않습니다.")
                    )
                    Button("파일 선택…") { isSelectingFile = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Day One 가져오기")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.isWorking {
                        Button("취소") { model.cancelDayOneImport() }
                    } else {
                        Button("닫기") {
                            model.resetDayOneImport()
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .fileImporter(
            isPresented: $isSelectingFile,
            allowedContentTypes: [.zip],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                model.analyzeDayOne(url: url)
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: model.importPreview?.archiveFingerprint) { _, _ in
            selectedImportItemIDs.removeAll()
            importNotebookName = ""
        }
    }

    @ViewBuilder
    private func previewView(_ preview: DayOneImportPreview) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.jsonDisplayName)
                        .font(.title2.bold())
                    Text("Day One export \(preview.exportVersion)")
                        .foregroundStyle(.secondary)
                    if let range = preview.dateRange {
                        Text(
                            "\(range.lowerBound.formatted(date: .abbreviated, time: .omitted))"
                                + " – "
                                + "\(range.upperBound.formatted(date: .abbreviated, time: .omitted))"
                        )
                        .font(.callout)
                    }
                }
                Spacer()
                summaryMetric("기록", value: preview.items.count)
                summaryMetric("미분류", value: preview.unclassifiedCount)
                summaryMetric("중복", value: preview.duplicateSourceUUIDs.count)
                summaryMetric("누락 첨부", value: preview.missingAttachmentCount)
            }
            .padding(24)

            Divider()

            HStack(spacing: 10) {
                Button(
                    selectedImportItemIDs.count == preview.items.count
                        ? "전체 선택 해제"
                        : "전체 선택"
                ) {
                    if selectedImportItemIDs.count == preview.items.count {
                        selectedImportItemIDs.removeAll()
                    } else {
                        selectedImportItemIDs = Set(preview.items.map(\.id))
                    }
                }
                Text("\(selectedImportItemIDs.count)개 선택")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().frame(height: 20)

                TextField("노트북 이름", text: $importNotebookName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)

                if !model.notebooks.isEmpty {
                    Menu("기존 노트북") {
                        ForEach(model.notebooks, id: \.self) { notebook in
                            Button(notebook) { importNotebookName = notebook }
                        }
                    }
                }

                Button("선택 항목에 지정") {
                    let sourceUUIDs = Set(
                        preview.items.compactMap { item in
                            selectedImportItemIDs.contains(item.id) ? item.sourceUUID : nil
                        })
                    _ = model.assignDayOneImportNotebook(
                        named: importNotebookName,
                        to: sourceUUIDs
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedImportItemIDs.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            Table(preview.items, selection: $selectedImportItemIDs) {
                TableColumn("선택") { item in
                    Toggle(
                        "선택",
                        isOn: Binding(
                            get: { selectedImportItemIDs.contains(item.id) },
                            set: { selected in
                                if selected {
                                    selectedImportItemIDs.insert(item.id)
                                } else {
                                    selectedImportItemIDs.remove(item.id)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                }
                .width(42)

                TableColumn("날짜") { item in
                    Text(
                        item.draft.occurredAt.formatted(
                            date: .numeric,
                            time: .omitted
                        ))
                }
                .width(min: 90, ideal: 110)

                TableColumn("기록") { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            item.draft.title.isEmpty
                                ? String(localized: "제목 없음") : item.draft.title
                        )
                        .lineLimit(1)
                        Text(item.draft.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                TableColumn("분류") { item in
                    Picker(
                        "분류",
                        selection: Binding(
                            get: { item.draft.kind },
                            set: { model.setDayOneImportKind($0, for: item.sourceUUID) }
                        )
                    ) {
                        ForEach(
                            model.kindPickerOptions(
                                including: item.draft.kind, activeOnly: true),
                            id: \.kind
                        ) { definition in
                            Text(definition.displayName).tag(definition.kind)
                        }
                    }
                    .labelsHidden()
                }
                .width(min: 105, ideal: 130)

                TableColumn("노트북") { item in
                    Text(item.draft.notebookName ?? "—")
                        .foregroundStyle(
                            item.draft.notebookName == nil ? .secondary : .primary
                        )
                        .lineLimit(1)
                }
                .width(min: 100, ideal: 140)

                TableColumn("확인") { item in
                    if preview.duplicateSourceUUIDs.contains(item.sourceUUID) {
                        Label("중복", systemImage: "doc.on.doc")
                            .foregroundStyle(.secondary)
                    } else if item.classification.isConflict {
                        Label("규칙 충돌", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else if !item.warnings.isEmpty {
                        Label("\(item.warnings.count)", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help(item.warnings.joined(separator: "\n"))
                    } else {
                        Label("준비됨", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))

            if !allPreviewWarnings(preview).isEmpty {
                DisclosureGroup("확인할 내용 \(allPreviewWarnings(preview).count)개") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(
                                Array(allPreviewWarnings(preview).enumerated()),
                                id: \.offset
                            ) { _, warning in
                                Label(warning, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            if !preview.optionalFieldCounts.isEmpty {
                Text(optionalFieldSummary(preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("다른 파일 선택") { isSelectingFile = true }
                Spacer()
                if case let .importing(completed, total) = model.importActivity {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                        .frame(width: 180)
                    Text("\(completed)/\(total)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("가져오기") { model.executeDayOneImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func resultView(
        preview: DayOneImportPreview,
        result: DayOneImportResult
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(
                    systemName: result.failed == 0
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.system(size: 30))
                .foregroundStyle(result.failed == 0 ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mac 가져오기 완료")
                        .font(.title2.bold())
                    Text(syncConvergenceDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                summaryMetric("성공", value: result.succeeded)
                summaryMetric("건너뜀", value: result.skipped)
                summaryMetric("실패", value: result.failed)
                summaryMetric(
                    "미분류",
                    value: result.outcomes.filter { $0.kind == .unclassified }.count
                )
            }
            .padding(24)

            Divider()

            Picker("결과 필터", selection: $resultFilter) {
                ForEach(ResultFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(16)

            let outcomes = filteredOutcomes(result)
            if outcomes.isEmpty {
                ContentUnavailableView(
                    "해당 결과 없음",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("다른 결과 필터를 선택해 보세요.")
                )
            } else {
                List(outcomes) { outcome in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label(
                                outcomeTitle(outcome),
                                systemImage: outcomeIcon(outcome.status)
                            )
                            .foregroundStyle(outcomeColor(outcome.status))
                            Spacer()
                            Text(model.kindDefinition(for: outcome.kind).displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(outcome.sourceUUID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        if let message = outcome.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(outcome.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }

            Divider()
            HStack {
                Text(preview.archiveURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("다른 파일 가져오기") {
                    model.resetDayOneImport()
                    isSelectingFile = true
                }
                Button("완료") {
                    model.resetDayOneImport()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }

    private func summaryMetric(_ title: LocalizedStringKey, value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func allPreviewWarnings(_ preview: DayOneImportPreview) -> [String] {
        preview.warnings + preview.items.flatMap(\.warnings)
    }

    private func optionalFieldSummary(_ preview: DayOneImportPreview) -> String {
        let fields = preview.optionalFieldCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
        return String(localized: "발견한 선택 필드: \(fields)")
    }

    private func filteredOutcomes(_ result: DayOneImportResult) -> [DayOneImportOutcome] {
        result.outcomes.filter { outcome in
            switch resultFilter {
            case .all: true
            case .imported: outcome.status == .imported
            case .skipped: outcome.status == .skipped
            case .failed: outcome.status == .failed
            case .warnings: !outcome.warnings.isEmpty
            case .unclassified: outcome.kind == .unclassified
            }
        }
    }

    private func outcomeTitle(_ outcome: DayOneImportOutcome) -> String {
        if !outcome.title.isEmpty { return outcome.title }
        return switch outcome.status {
        case .imported: String(localized: "가져온 기록")
        case .skipped: String(localized: "건너뛴 기록")
        case .failed: String(localized: "실패한 기록")
        }
    }

    private func outcomeIcon(_ status: DayOneImportOutcomeStatus) -> String {
        switch status {
        case .imported: "checkmark.circle"
        case .skipped: "forward.circle"
        case .failed: "xmark.circle"
        }
    }

    private func outcomeColor(_ status: DayOneImportOutcomeStatus) -> Color {
        switch status {
        case .imported: .green
        case .skipped: .secondary
        case .failed: .red
        }
    }

    private var syncConvergenceDescription: String {
        switch model.syncState {
        case .localOnly:
            String(localized: "기록은 이 Mac에만 저장됐습니다. iCloud를 켜기 전에는 iPhone으로 전송되지 않습니다.")
        case .savedLocally:
            String(localized: "이 Mac에는 저장됐고 CloudKit 업로드 상태를 확인하고 있습니다.")
        case .pending:
            String(localized: "이 Mac에는 저장됐습니다. CloudKit 업로드와 iPhone 수신은 진행 중입니다.")
        case let .synced(date):
            date.map {
                String(
                    localized: "CloudKit 동기화 완료: \($0.formatted()). 같은 iCloud 계정의 iPhone에서 수신됩니다.")
            }
                ?? String(localized: "CloudKit 동기화가 완료됐습니다. 같은 iCloud 계정의 iPhone에서 수신됩니다.")
        case let .unavailable(reason):
            String(localized: "이 Mac에는 저장됐지만 iCloud를 사용할 수 없습니다: \(reason)")
        case let .failed(message, _):
            String(localized: "이 Mac에는 저장됐지만 CloudKit 동기화에 실패했습니다: \(message)")
        }
    }

    private enum ResultFilter: String, CaseIterable, Identifiable {
        case all
        case imported
        case skipped
        case failed
        case warnings
        case unclassified

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: String(localized: "전체")
            case .imported: String(localized: "성공")
            case .skipped: String(localized: "건너뜀")
            case .failed: String(localized: "실패")
            case .warnings: String(localized: "경고")
            case .unclassified: String(localized: "미분류")
            }
        }
    }
}
#endif
