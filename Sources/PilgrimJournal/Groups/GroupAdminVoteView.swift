import Foundation
import JournalGroups
import PilgrimAPI
import SwiftUI

/// The notice above a group that has no admin right now or is about to be deleted. Phase 2
/// puts it at the top of the feed (A3's `GroupFeedView`); the settings screen shows it too.
struct GroupStatusBanner: View {
    let group: GroupSummary
    /// Opens the ballot (voting only).
    var openVote: (() -> Void)?

    var body: some View {
        switch group.status {
        case .voting:
            banner(
                systemImage: "checkmark.seal",
                title: votingTitle,
                detail: String(localized: "투표가 끝날 때까지 초대, 강퇴, 삭제 같은 관리자 기능은 쉬어요.")
            ) {
                if let openVote {
                    Button("투표하기", action: openVote)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        case .pendingDeletion:
            banner(
                systemImage: "clock.badge.exclamationmark",
                title: deletionTitle,
                detail: String(localized: "그때까지 글을 읽고 내 기록장에 스크랩할 수 있지만, 새로 쓸 수는 없어요.")
            ) {}
        case .active:
            EmptyView()
        }
    }

    private var votingTitle: String {
        if let endsAt = group.voteEndsAt {
            return String(localized: "새 관리자를 뽑는 중이에요 · \(GroupDateText.dayAndTime(endsAt)) 마감")
        }
        return String(localized: "새 관리자를 뽑는 중이에요")
    }

    private var deletionTitle: String {
        if let deleteAt = group.deleteAt {
            return String(localized: "\(GroupDateText.dayAndTime(deleteAt))에 그룹이 삭제돼요")
        }
        return String(localized: "곧 그룹이 삭제돼요")
    }

    private func banner<Actions: View>(
        systemImage: String, title: String, detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: JournalTheme.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(JournalTheme.accentWarm)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(JournalTheme.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(JournalTheme.inkSecondary)
                actions()
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(JournalTheme.Spacing.medium)
        .background(
            JournalTheme.accentWarm.opacity(0.12),
            in: RoundedRectangle(cornerRadius: JournalTheme.Radius.medium, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The admin election ballot. Every member is a candidate (myself included), the first round
/// runs three days and a tie goes to a one-day runoff between the tied members. Ballots are
/// secret: only turnout is shown, and my choice can change until the round closes.
struct GroupAdminVoteView: View {
    @StateObject private var model: GroupVoteModel

    init(groups: GroupsController, groupID: UUID) {
        _model = StateObject(wrappedValue: GroupVoteModel(groups: groups, groupID: groupID))
    }

    var body: some View {
        Form {
            if let vote = model.vote {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.isRunoff ? "재투표" : "새 관리자 투표")
                            .font(.headline)
                            .foregroundStyle(JournalTheme.ink)
                        Text("\(GroupDateText.dayAndTime(vote.endsAt))에 마감돼요")
                            .foregroundStyle(JournalTheme.inkSecondary)
                        Text("\(vote.eligibleCount)명 중 \(vote.ballotCount)명이 투표했어요")
                            .foregroundStyle(JournalTheme.inkSecondary)
                    }
                    .font(.callout)
                } footer: {
                    Text(
                        model.isRunoff
                            ? "1차 투표가 동률이라 동률인 사람끼리 하루 동안 다시 뽑아요. 또 동률이면 그중 한 명이 무작위로 정해져요."
                            : "누가 누구에게 투표했는지, 몇 표인지는 아무에게도 보이지 않아요. 마감 전까지 바꿀 수 있어요."
                    )
                }

                Section("후보") {
                    ForEach(vote.candidates, id: \.id) { candidate in
                        Button {
                            model.selection = candidate.id
                        } label: {
                            HStack {
                                Text(candidate.displayName)
                                    .foregroundStyle(JournalTheme.ink)
                                if model.isMe(candidate) {
                                    Text("나")
                                        .font(.caption)
                                        .foregroundStyle(JournalTheme.inkSecondary)
                                }
                                Spacer()
                                if vote.myBallot == candidate.id {
                                    Text("내 투표")
                                        .font(.caption)
                                        .foregroundStyle(JournalTheme.brandPrimary)
                                }
                                Image(
                                    systemName: model.selection == candidate.id
                                        ? "largecircle.fill.circle" : "circle"
                                )
                                .foregroundStyle(JournalTheme.brandPrimary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.selection == candidate.id ? .isSelected : [])
                    }
                }

                Section {
                    Button {
                        Task { await model.cast() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.isWorking {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(model.isChangingBallot ? "투표 바꾸기" : "투표하기")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!model.canCast || model.isWorking)
                }
            } else if model.isClosed {
                Section {
                    Text("투표가 끝났어요. 그룹 상태를 새로 불러왔어요.")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
            } else if model.message == nil {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                }
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
        .navigationTitle("관리자 투표")
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

/// The ballot as its own sheet (from the sidebar or a vote notification).
struct GroupAdminVoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var groups: GroupsController
    let groupID: UUID

    var body: some View {
        NavigationStack {
            GroupAdminVoteView(groups: groups, groupID: groupID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
        }
        .frame(minWidth: 400, minHeight: 480)
    }
}
