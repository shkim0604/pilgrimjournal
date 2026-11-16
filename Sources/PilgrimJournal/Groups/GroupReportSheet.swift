import Combine
import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// What is being reported.
enum GroupReportTarget: Equatable, Identifiable {
    case post(UUID)
    case comment(UUID)
    case sticker(UUID)
    case user(UserSummary)

    var id: String { "\(type.rawValue)-\(targetID.pilgrimString)" }

    var type: ReportTargetType {
        switch self {
        case .post: .post
        case .comment: .comment
        case .sticker: .sticker
        case .user: .user
        }
    }

    var targetID: UUID {
        switch self {
        case .post(let id), .comment(let id), .sticker(let id): id
        case .user(let user): user.id
        }
    }

    var title: String {
        switch self {
        case .post: String(localized: "글 신고")
        case .comment: String(localized: "댓글 신고")
        case .sticker: String(localized: "스티커 신고")
        case .user: String(localized: "사람 신고")
        }
    }
}

extension ReportReason {
    var groupLabel: String {
        switch self {
        case .spam: String(localized: "스팸·광고")
        case .harassment: String(localized: "괴롭힘·혐오")
        case .inappropriate: String(localized: "부적절한 내용")
        case .selfHarm: String(localized: "자해·자살 위험")
        case .other: String(localized: "기타")
        }
    }
}

/// Sends one report. The `clientId` is fixed for the sheet, so pressing again after a lost
/// response files one report, not two.
@MainActor
final class GroupReportModel: ObservableObject {
    @Published var reason: ReportReason?
    @Published var note = ""
    @Published private(set) var isSubmitting = false
    @Published private(set) var receipt: ReportReceipt?
    @Published var errorMessage: String?

    let target: GroupReportTarget
    let groupID: UUID
    private let api: any GroupAPI
    let clientID = UUID()

    init(api: any GroupAPI, target: GroupReportTarget, groupID: UUID) {
        self.api = api
        self.target = target
        self.groupID = groupID
    }

    var canSubmit: Bool {
        reason != nil && note.count <= APILimits.reportNoteMax && !isSubmitting && receipt == nil
    }

    var request: CreateReportRequest? {
        guard let reason else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return CreateReportRequest(
            clientId: clientID, targetType: target.type, targetId: target.targetID,
            groupId: groupID, reason: reason, note: trimmed.isEmpty ? nil : trimmed)
    }

    @discardableResult
    func submit() async -> Bool {
        guard canSubmit, let request else { return false }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            receipt = try await api.report(request)
            return true
        } catch {
            errorMessage = GroupContentError.message(for: error)
            return false
        }
    }
}

/// Reason, optional note, then — once the report is in — the offer to hide the post or block
/// the person right away.
struct GroupReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: GroupReportModel
    /// The person behind the reported thing, for "이 사람 차단하기".
    let author: UserSummary?
    let onHidePost: (() async -> Void)?
    let onBlock: ((UserSummary) async -> Void)?

    init(
        api: any GroupAPI, target: GroupReportTarget, groupID: UUID, author: UserSummary?,
        onHidePost: (() async -> Void)? = nil, onBlock: ((UserSummary) async -> Void)? = nil
    ) {
        _model = StateObject(
            wrappedValue: GroupReportModel(api: api, target: target, groupID: groupID))
        self.author = author
        self.onHidePost = onHidePost
        self.onBlock = onBlock
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.receipt == nil {
                    reasonSection
                    noteSection
                    if let message = model.errorMessage {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                } else {
                    followUpSection
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.target.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        model.receipt == nil ? LocalizedStringKey("취소") : LocalizedStringKey("닫기")
                    ) { dismiss() }
                }
                if model.receipt == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("신고하기") {
                            Task { await model.submit() }
                        }
                        .disabled(!model.canSubmit)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 440)
        #endif
    }

    private var reasonSection: some View {
        Section {
            ForEach(ReportReason.allCases, id: \.self) { reason in
                Button {
                    model.reason = reason
                } label: {
                    HStack {
                        Text(reason.groupLabel).foregroundStyle(JournalTheme.ink)
                        Spacer()
                        if model.reason == reason {
                            Image(systemName: "checkmark")
                                .foregroundStyle(JournalTheme.brandPrimary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.reason == reason ? .isSelected : [])
            }
        } header: {
            Text("사유")
        } footer: {
            if model.reason == .selfHarm {
                Text("위급한 상황이라면 109(자살예방 상담전화)나 112·119에 바로 연락해 주세요.")
            }
        }
    }

    private var noteSection: some View {
        Section {
            TextField("설명 (선택)", text: $model.note, axis: .vertical)
                .lineLimit(3...6)
        } header: {
            Text("설명")
        } footer: {
            Text("\(model.note.count)/\(APILimits.reportNoteMax)")
                .foregroundStyle(
                    model.note.count > APILimits.reportNoteMax ? Color.red : .secondary)
        }
    }

    private var followUpSection: some View {
        Section {
            Label("신고가 접수되었어요", systemImage: "checkmark.seal")
                .foregroundStyle(JournalTheme.brandPrimary)
            Text("운영자가 확인할게요. 더 보고 싶지 않다면 바로 숨기거나 차단할 수 있어요.")
                .font(.callout)
                .foregroundStyle(JournalTheme.inkSecondary)
            if let onHidePost, model.target.type == .post {
                Button("이 글 숨기기") {
                    Task {
                        await onHidePost()
                        dismiss()
                    }
                }
            }
            if let onBlock, let author {
                Button("이 사람 차단하기", role: .destructive) {
                    Task {
                        await onBlock(author)
                        dismiss()
                    }
                }
            }
        }
    }
}
