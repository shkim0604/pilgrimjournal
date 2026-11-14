import Foundation
import JournalGroups
import PhotosUI
import PilgrimAPI
import SwiftUI

/// Writes a group post: 기도제목 (title, lines, deadline or visible period), 독후감 (book,
/// quote, body) or 간증 (title, body), with up to four photos. Nothing is posted until
/// "올리기" is pressed; a failure keeps the sheet open with everything in it.
struct GroupPostComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GroupComposerModel
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var isConfirmingOthers = false
    @State private var isConfirmingDiscard = false
    private let onPosted: (PostResponse) -> Void

    init(
        makeModel: @escaping @autoclosure () -> GroupComposerModel,
        onPosted: @escaping (PostResponse) -> Void = { _ in }
    ) {
        _model = StateObject(wrappedValue: makeModel())
        self.onPosted = onPosted
    }

    /// The entry point for every caller (the feed's "새 글", A4's entry and prayer-request
    /// sheets): opens the composer filled from `draft` for `groupID`, or with a group picker
    /// when `groupID` is nil and the user is in several groups.
    @MainActor
    static func compose(
        _ draft: GroupPostDraft,
        groups: GroupsController,
        groupID: UUID?,
        prepareImage: GroupImagePreparer? = nil,
        onPosted: @escaping (PostResponse) -> Void = { _ in }
    ) -> GroupPostComposerSheet {
        let api = groups.api
        let summaries = groups.groups
        let preparer = prepareImage ?? GroupImagePreparation.current
        return GroupPostComposerSheet(
            makeModel: GroupComposerModel(
                api: api, groups: summaries, groupID: groupID, draft: draft,
                prepareImage: preparer),
            onPosted: onPosted)
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.groups.count > 1 || model.groupID == nil {
                    groupSection
                }
                kindSection
                switch model.kind {
                case .prayer: prayerSections
                case .bookReport: bookReportSections
                case .testimony: testimonySections
                }
                photoSection
                statusSection
            }
            .formStyle(.grouped)
            .disabled(model.isSubmitting)
            .navigationTitle("그룹에 올리기")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        if model.hasContent { isConfirmingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSubmitting {
                        ProgressView()
                    } else {
                        Button("올리기") {
                            if model.needsOthersConfirmation {
                                isConfirmingOthers = true
                            } else {
                                Task { await post() }
                            }
                        }
                        .disabled(!model.canSubmit)
                    }
                }
            }
            .confirmationDialog(
                "다른 사람의 사정이 담겨 있어요", isPresented: $isConfirmingOthers,
                titleVisibility: .visible
            ) {
                Button("확인했어요, 올리기") { Task { await post() } }
                Button("다시 보기", role: .cancel) {}
            } message: {
                Text("그 사람이 나눠도 괜찮다고 했는지 한 번 더 확인해 주세요.")
            }
            .confirmationDialog(
                "작성한 글을 버릴까요?", isPresented: $isConfirmingDiscard, titleVisibility: .visible
            ) {
                Button("버리기", role: .destructive) { dismiss() }
                Button("계속 쓰기", role: .cancel) {}
            }
            .onChange(of: pickerSelection) { _, items in
                guard !items.isEmpty else { return }
                Task { await importPhotos(items) }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 600)
        #endif
        .interactiveDismissDisabled(model.hasContent || model.isSubmitting)
    }

    // MARK: Sections

    private var groupSection: some View {
        Section {
            Picker("그룹", selection: $model.groupID) {
                Text("고르기").tag(UUID?.none)
                ForEach(model.groups) { group in
                    Text(group.name).tag(UUID?.some(group.id))
                }
            }
        }
    }

    private var kindSection: some View {
        Section {
            Picker("종류", selection: $model.kind) {
                ForEach(PostKind.allCases, id: \.self) { kind in
                    Label(kind.groupLabel, systemImage: kind.groupSymbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var prayerSections: some View {
        Section {
            TextField("제목 (선택)", text: $model.title)
        }
        Section {
            ForEach($model.items) { $item in
                VStack(alignment: .leading, spacing: 4) {
                    TextField("기도제목", text: $item.text, axis: .vertical)
                        .lineLimit(1...4)
                    TextField("누구를 위해 (선택)", text: $item.who)
                        .font(.caption)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
            }
            .onDelete { offsets in
                for id in offsets.map({ model.items[$0].id }) { model.removeItem(id) }
            }
            if model.items.count < GroupComposerModel.maxItems {
                Button {
                    model.addItem()
                } label: {
                    Label("기도제목 줄 추가", systemImage: "plus")
                }
            }
        } header: {
            Text("기도제목 \(model.filledItems.count)/\(GroupComposerModel.maxItems)")
        }
        Section {
            TextField("덧붙이는 말 (선택)", text: $model.body, axis: .vertical)
                .lineLimit(3...10)
        }
        Section {
            Toggle("데드라인 정하기", isOn: $model.usesDeadline)
            if model.usesDeadline {
                DatePicker(
                    "데드라인", selection: $model.deadlineDate, in: model.deadlineRange,
                    displayedComponents: .date)
            } else {
                Picker("공개 기간", selection: $model.visibleDays) {
                    ForEach(PostExpiryPolicy.allowedVisibleDays, id: \.self) { days in
                        Text("\(days)일").tag(days)
                    }
                }
            }
        } header: {
            Text("공개 기간")
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                expiryPreview
                if model.usesDeadline {
                    Text("데드라인이 지나고 3일 뒤에 사라져요.")
                } else {
                    Text("올린 때부터 고른 기간이 지나면 사라져요.")
                }
            }
        }
    }

    @ViewBuilder
    private var bookReportSections: some View {
        Section {
            TextField("책 제목", text: $model.bookTitle)
            TextField("저자 (선택)", text: $model.bookAuthor)
        } header: {
            Text("책")
        }
        Section {
            TextField("제목 (선택)", text: $model.title)
            TextField("인상 깊은 구절 (선택)", text: $model.quote, axis: .vertical)
                .lineLimit(2...6)
            TextField("나누고 싶은 이야기", text: $model.body, axis: .vertical)
                .lineLimit(5...14)
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                expiryPreview
                Text("독후감은 7일 동안 보이고, 멤버 누구나 토론을 일주일씩 연장할 수 있어요.")
            }
        }
    }

    @ViewBuilder
    private var testimonySections: some View {
        Section {
            TextField("제목 (선택)", text: $model.title)
            TextField("간증", text: $model.body, axis: .vertical)
                .lineLimit(5...14)
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                expiryPreview
                Text("간증은 7일 동안 보여요.")
            }
        }
    }

    @ViewBuilder
    private var expiryPreview: some View {
        if let text = model.expiryPreviewText {
            Text("사라지는 날: \(text)")
                .fontWeight(.semibold)
        }
    }

    private var photoSection: some View {
        Section {
            if !model.photos.isEmpty {
                GroupLocalPhotoStrip(photos: model.photos) { model.removePhoto($0) }
            }
            PhotosPicker(
                selection: $pickerSelection,
                maxSelectionCount: max(1, GroupComposerModel.maxPhotos - model.photos.count),
                matching: .images
            ) {
                Label("사진 붙이기", systemImage: "photo.on.rectangle")
            }
            .disabled(!model.canAddPhotos)
        } header: {
            Text("사진 \(model.photos.count)/\(GroupComposerModel.maxPhotos)")
        } footer: {
            Text("사진은 기기에서 줄이고 위치 정보 같은 메타데이터를 지운 뒤 올려요.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if model.errorMessage != nil || model.notice != nil || !visibleIssues.isEmpty {
            Section {
                if let message = model.errorMessage {
                    Label(message, systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.red)
                }
                if let notice = model.notice {
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                ForEach(visibleIssues, id: \.message) { issue in
                    Text(issue.message)
                        .font(.footnote)
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
            }
        }
    }

    /// Limits that are already broken (not "still empty"), so the form does not nag while the
    /// user is starting to type.
    private var visibleIssues: [GroupComposerIssue] {
        model.issues.filter { issue in
            switch issue {
            case .bodyRequired, .itemsRequired, .bookTitleRequired, .noGroup: false
            default: true
            }
        }
    }

    // MARK: Actions

    private func post() async {
        guard let post = await model.submit() else { return }
        onPosted(post)
        dismiss()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        var data: [Data] = []
        for item in items {
            if let photo = try? await item.loadTransferable(type: Data.self) {
                data.append(photo)
            }
        }
        pickerSelection = []
        model.addPhotos(data)
    }
}
