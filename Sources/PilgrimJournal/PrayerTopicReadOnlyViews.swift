import JournalDomain
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// Read-only 기도제목 list (sections included) for the iOS detail screen.
struct PrayerTopicReadOnlyList: View {
    let topics: [PrayerTopic]
    let categories: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            rows(for: nil)
            ForEach(categories, id: \.self) { category in
                if category != categories.first || topics.contains(where: { $0.category == nil }) {
                    Divider()
                }
                Text(category)
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)
                rows(for: category)
            }
        }
    }

    @ViewBuilder
    private func rows(for category: String?) -> some View {
        ForEach(topics.filter { $0.category == category }) { topic in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(
                    systemName: topic.status == .answered
                        ? "checkmark.square.fill" : "square"
                )
                .foregroundStyle(topic.status == .answered ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(topic.text)
                            .strikethrough(topic.status == .answered)
                            .foregroundStyle(
                                topic.status == .answered ? .secondary : .primary)
                        if topic.status == .answered, let outcome = topic.answerOutcome {
                            PrayerOutcomeBadge(outcome: outcome)
                        }
                    }
                    if let answeredAt = topic.answeredAt, topic.status == .answered {
                        Text("응답 \(answeredAt, format: .dateTime.year().month().day())")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let memo = topic.memo {
                        Text(memo)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if topic.status == .answered, let note = topic.answerNote {
                        Text("응답 메모: \(note)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One row of the aggregated 기도중/응답 lists in the content column.
struct PrayerTopicItemRow: View {
    let item: PrayerTopicItem
    let noteTitle: String
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            PrayerTopicCheckbox(
                status: item.topic.status,
                outcome: item.topic.answerOutcome,
                accessibilityLabel: item.topic.text,
                action: onToggle
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.topic.text)
                        .strikethrough(item.topic.status == .answered)
                    if item.topic.status == .answered, let outcome = item.topic.answerOutcome {
                        PrayerOutcomeBadge(outcome: outcome)
                    }
                }
                if item.topic.status == .answered, let answeredAt = item.topic.answeredAt {
                    Text("응답 \(answeredAt, format: .dateTime.year().month().day())")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let memo = item.topic.memo {
                    Text(memo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if item.topic.status == .answered, let note = item.topic.answerNote {
                    Text("응답 메모: \(note)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var sourceLine: String {
        var parts = [noteTitle]
        if let category = item.topic.category { parts.append(category) }
        parts.append(
            item.entryOccurredAt.formatted(.dateTime.year().month().day()))
        return parts.joined(separator: " · ")
    }
}

/// Yes / No / Wait capsule shown next to answered topics.
struct PrayerOutcomeBadge: View {
    let outcome: PrayerAnswerOutcome

    var body: some View {
        Text(verbatim: outcome.carryOverLabel)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch outcome {
        case .yes: return .green
        case .no: return .secondary
        case .wait: return .orange
        }
    }
}

/// Shared checkbox button that flips a topic between 기도중 and 응답.
struct PrayerTopicCheckbox: View {
    let status: PrayerStatus
    var outcome: PrayerAnswerOutcome?
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: status == .answered ? "checkmark.square.fill" : "square")
                .foregroundStyle(status == .answered ? Color.green : Color.secondary)
                .imageScale(.large)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            status == .answered
                ? String(localized: "기도중으로 되돌리기: \(accessibilityLabel)")
                : String(localized: "응답으로 표시: \(accessibilityLabel)"))
    }
}
