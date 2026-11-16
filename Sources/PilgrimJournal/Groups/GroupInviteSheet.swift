import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The invite sheet on its own (from the sidebar's group menu).
struct GroupInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var groups: GroupsController
    let groupID: UUID

    var body: some View {
        NavigationStack {
            GroupInvitesView(groups: groups, groupID: groupID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 420, minHeight: 560)
    }
}

/// Admin: make an invite (1–100 people, 3 days), show it as a link and a QR code, and list or
/// revoke the live ones.
struct GroupInvitesView: View {
    @StateObject private var model: GroupInviteModel
    @State private var pendingRevoke: InviteResponse?

    init(groups: GroupsController, groupID: UUID) {
        _model = StateObject(wrappedValue: GroupInviteModel(groups: groups, groupID: groupID))
    }

    private var canCreate: Bool { model.capabilities?.canCreateInvites ?? false }

    var body: some View {
        Form {
            if canCreate {
                Section {
                    Stepper(value: $model.maxUses, in: GroupInviteRules.maxUsesRange) {
                        HStack {
                            Text("최대 인원")
                            Spacer()
                            TextField(
                                "인원", value: $model.maxUses, format: .number
                            )
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                            Text("명")
                                .foregroundStyle(JournalTheme.inkSecondary)
                        }
                    }
                    .onChange(of: model.maxUses) { _, value in
                        let clamped = GroupInviteRules.clamped(value)
                        if clamped != value { model.maxUses = clamped }
                    }
                    Button {
                        Task { await model.create() }
                    } label: {
                        Label("초대 만들기", systemImage: "link.badge.plus")
                    }
                    .disabled(model.isWorking)
                } header: {
                    Text("새 초대")
                } footer: {
                    Text(
                        "초대는 만든 때부터 \(GroupInviteRules.lifetimeDays)일 동안 쓸 수 있고, 정한 인원이 다 차면 더 받지 않아요."
                    )
                }
            } else if model.capabilities?.isVoting == true {
                Section {
                    Text("새 관리자를 뽑는 동안에는 초대할 수 없어요.")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
            } else if model.capabilities?.isPendingDeletion == true {
                Section {
                    Text("삭제 예정인 그룹이라 새 초대를 만들 수 없어요.")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
            }

            if let created = model.created {
                Section("방금 만든 초대") {
                    GroupInviteCard(invite: created)
                }
            }

            Section {
                if model.invites.isEmpty {
                    Text("살아 있는 초대가 없어요.")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
                ForEach(model.invites, id: \.code) { invite in
                    GroupInviteRow(invite: invite) {
                        pendingRevoke = invite
                    }
                }
            } header: {
                Text("살아 있는 초대")
            }

            if let message = model.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("다시 불러오기") { Task { await model.load() } }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(JournalTheme.canvas)
        .navigationTitle("초대")
        .task { await model.load() }
        .confirmationDialog(
            "이 초대를 취소할까요?",
            isPresented: Binding(
                get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible,
            presenting: pendingRevoke
        ) { invite in
            Button("초대 취소", role: .destructive) {
                Task { await model.revoke(invite) }
            }
            Button("닫기", role: .cancel) {}
        } message: { _ in
            Text("이 링크와 QR 코드로는 더 이상 참여할 수 없어요. 이미 참여한 멤버는 그대로예요.")
        }
    }
}

/// A new invite: QR code, link, code, and the ways to pass it on.
struct GroupInviteCard: View {
    let invite: InviteResponse
    @State private var didCopy = false

    private var groupedCode: String {
        InviteCode(normalizing: invite.code)?.grouped ?? invite.code
    }

    var body: some View {
        VStack(spacing: JournalTheme.Spacing.medium) {
            if let qr = GroupInviteQRCode.image(for: invite.url) {
                Image(decorative: qr, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .padding(JournalTheme.Spacing.small)
                    .background(
                        Color.white, in: RoundedRectangle(cornerRadius: JournalTheme.Radius.small)
                    )
                    .accessibilityLabel("초대 QR 코드")
            }
            Text(groupedCode)
                .font(.title3.monospaced().weight(.semibold))
                .foregroundStyle(JournalTheme.ink)
                .textSelection(.enabled)
            Text(invite.url.absoluteString)
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)
            Text(
                "\(GroupDateText.dayAndTime(invite.expiresAt))에 만료 · \(invite.useCount)/\(invite.maxUses)명 참여"
            )
            .font(.caption)
            .foregroundStyle(JournalTheme.inkSecondary)
            HStack(spacing: JournalTheme.Spacing.medium) {
                Button {
                    GroupInvitePasteboard.copy(invite.url.absoluteString)
                    didCopy = true
                } label: {
                    Label(
                        didCopy ? "복사했어요" : "링크 복사",
                        systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                ShareLink(
                    item: invite.url,
                    subject: Text("Pilgrim 그룹 초대"),
                    message: Text(
                        "Pilgrim Journal 그룹에 초대합니다. 앱에서 링크를 열거나 초대 코드 \(groupedCode)를 입력해 주세요.")
                ) {
                    Label("공유", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, JournalTheme.Spacing.small)
    }
}

private struct GroupInviteRow: View {
    let invite: InviteResponse
    let revoke: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(InviteCode(normalizing: invite.code)?.grouped ?? invite.code)
                    .font(.body.monospaced())
                    .foregroundStyle(JournalTheme.ink)
                Text(
                    "\(invite.useCount)/\(invite.maxUses)명 · \(GroupDateText.dayAndTime(invite.expiresAt))에 만료"
                )
                .font(.caption)
                .foregroundStyle(JournalTheme.inkSecondary)
            }
            Spacer()
            ShareLink(item: invite.url) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("초대 공유")
            Button(role: .destructive, action: revoke) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("초대 취소")
        }
    }
}

/// QR codes for invite links (`CIQRCodeGenerator`, medium error correction), scaled up with
/// whole pixels so they stay sharp.
enum GroupInviteQRCode {
    static func image(for url: URL, scale: CGFloat = 10) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext(options: [.useSoftwareRenderer: false])
            .createCGImage(scaled, from: scaled.extent)
    }
}

enum GroupInvitePasteboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
