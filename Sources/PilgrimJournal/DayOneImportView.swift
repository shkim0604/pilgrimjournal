import DayOneImport
import JournalBackup
import JournalData
import JournalDomain
import SwiftUI
import UniformTypeIdentifiers

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
