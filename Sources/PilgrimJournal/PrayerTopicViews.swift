import JournalDomain
import SwiftUI

/// Editable 기도제목 checklist shown above the body in both entry editors.
///
/// Lives inside `typeSpecificFields`, so the markdown body editor keeps its
/// structural position in the view tree (see docs/known-issues.md on editor
/// input dropping).
struct PrayerTopicChecklistEditor: View {
    @Binding var topics: [PrayerTopic]
    @FocusState private var focusedTopicID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("기도제목")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach($topics) { $topic in
                PrayerTopicEditorRow(
                    topic: $topic,
                    focusedTopicID: $focusedTopicID,
                    onDelete: { topics.removeAll { $0.id == topic.id } }
                )
            }
            Button {
                let topic = PrayerTopic(text: "", createdAt: .now)
                topics.append(topic)
                focusedTopicID = topic.id
            } label: {
                Label("기도제목 추가", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("prayer-topic-add")
        }
    }
}

private struct PrayerTopicEditorRow: View {
    @Binding var topic: PrayerTopic
    var focusedTopicID: FocusState<UUID?>.Binding
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PrayerTopicCheckbox(
                status: topic.status,
                accessibilityLabel: topic.text
            ) {
                if topic.status == .answered {
                    topic.status = .ongoing
                    topic.answeredAt = nil
                } else {
                    topic.status = .answered
                    topic.answeredAt = .now
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                TextField("기도제목", text: $topic.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused(focusedTopicID, equals: topic.id)
                    .strikethrough(topic.status == .answered)
                    .foregroundStyle(topic.status == .answered ? .secondary : .primary)
                if let answeredAt = topic.answeredAt, topic.status == .answered {
                    Text("응답 \(answeredAt, format: .dateTime.year().month().day())")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                TextField("메모", text: memoBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "기도제목 삭제"))
        }
    }

    private var memoBinding: Binding<String> {
        Binding(
            get: { topic.memo ?? "" },
            set: { topic.memo = $0.isEmpty ? nil : $0 }
        )
    }
}

/// Read-only 기도제목 list for the iOS detail screen.
struct PrayerTopicReadOnlyList: View {
    let topics: [PrayerTopic]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(topics) { topic in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(
                        systemName: topic.status == .answered
                            ? "checkmark.square.fill" : "square"
                    )
                    .foregroundStyle(topic.status == .answered ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(topic.text)
                            .strikethrough(topic.status == .answered)
                            .foregroundStyle(topic.status == .answered ? .secondary : .primary)
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
                accessibilityLabel: item.topic.text,
                action: onToggle
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.topic.text)
                    .strikethrough(item.topic.status == .answered)
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
                Text(
                    "\(noteTitle) · \(item.entryOccurredAt, format: .dateTime.year().month().day())"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Shared checkbox button that flips a topic between 기도중 and 응답.
private struct PrayerTopicCheckbox: View {
    let status: PrayerStatus
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
