import Foundation
import JournalDomain
import SwiftUI

#if os(macOS)
import AppKit
private typealias JournalPlatformColor = NSColor
#elseif os(iOS)
import UIKit
private typealias JournalPlatformColor = UIColor
#endif

enum JournalTheme {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }

    static let editorMaxWidth: CGFloat = 720
    static let sidebarWidth: ClosedRange<CGFloat> = 220...260
    static let timelineWidth: ClosedRange<CGFloat> = 300...360
    /// Below this, the editor's compact toolbar (kind/notebook chips + the
    /// history menu + save status) has nowhere left to shrink and its icons
    /// start overlapping instead.
    static let detailMinWidth: CGFloat = 420

    static let brandPrimary = Color(
        lightHex: 0x2F5D50,
        darkHex: 0x7EBAA5
    )
    static let accentWarm = Color(lightHex: 0xD9A24A, darkHex: 0xF0BD68)
    static let canvas = Color(lightHex: 0xF6F3EC, darkHex: 0x111714)
    static let paper = Color(lightHex: 0xFBF8F1, darkHex: 0x18211D)
    static let surfaceMuted = Color(lightHex: 0xEEF3ED, darkHex: 0x151D1A)
    static let ink = Color(lightHex: 0x252A27, darkHex: 0xF3F1EA)
    static let inkSecondary = Color(lightHex: 0x66706A, darkHex: 0xAEB8B1)
    static let separator = Color(lightHex: 0xDCE3DD, darkHex: 0x34413B)
    static let selection = Color(lightHex: 0xDDEBE5, darkHex: 0x29483F)

    static func categoryColor(for kind: JournalKind) -> Color {
        switch kind.builtIn {
        case .prayer?: Color(lightHex: 0x9B6B25, darkHex: 0xE1B869)
        case .bibleStudy?: Color(lightHex: 0x56745B, darkHex: 0x90B895)
        case .reading?: Color(lightHex: 0x55758C, darkHex: 0x8DB4CE)
        case .diary?: Color(lightHex: 0x9B5E54, darkHex: 0xD89A90)
        case .memo?: Color(lightHex: 0x6B668C, darkHex: 0xAAA4CE)
        case .unclassified?: Color(lightHex: 0x68716C, darkHex: 0xAAB3AE)
        case nil: Color(lightHex: 0x6B668C, darkHex: 0xAAA4CE)
        }
    }
}

extension Color {
    fileprivate init(lightHex: UInt32, darkHex: UInt32) {
        #if os(macOS)
        self.init(
            nsColor: NSColor(name: nil) { appearance in
                let best = appearance.bestMatch(from: [.darkAqua, .aqua])
                return JournalPlatformColor(
                    hex: best == .darkAqua ? darkHex : lightHex
                )
            })
        #else
        self.init(
            uiColor: UIColor { traits in
                JournalPlatformColor(
                    hex: traits.userInterfaceStyle == .dark ? darkHex : lightHex
                )
            })
        #endif
    }
}

private extension JournalPlatformColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: 1
        )
    }
}

struct JournalSidebarItem: View {
    let title: String
    let systemImage: String
    let accent: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: JournalTheme.Spacing.medium) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(JournalTheme.ink)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer(minLength: JournalTheme.Spacing.small)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(JournalTheme.brandPrimary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, JournalTheme.Spacing.medium)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.medium,
                    style: .continuous
                )
                .fill(isSelected ? JournalTheme.selection : .clear)
            }
        }
        .buttonStyle(.plain)
        .journalFocusStyle(cornerRadius: JournalTheme.Radius.medium)
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
        .listRowBackground(Color.clear)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct JournalFocusStyle: ViewModifier {
    @Environment(\.isFocused) private var isFocused
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    isFocused ? JournalTheme.brandPrimary : .clear,
                    lineWidth: isFocused ? 2 : 0
                )
                .padding(1)
        }
    }
}

extension View {
    func journalFocusStyle(
        cornerRadius: CGFloat = JournalTheme.Radius.small
    ) -> some View {
        modifier(JournalFocusStyle(cornerRadius: cornerRadius))
    }

    func journalMetadataField() -> some View {
        textFieldStyle(.plain)
            .foregroundStyle(JournalTheme.ink)
            .padding(.horizontal, JournalTheme.Spacing.medium)
            .padding(.vertical, 9)
            .background(
                JournalTheme.surfaceMuted,
                in: RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.small,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.small,
                    style: .continuous
                )
                .stroke(JournalTheme.separator.opacity(0.7), lineWidth: 1)
            }
    }
}

struct MetadataChip<Label: View>: View {
    private let label: Label

    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    var body: some View {
        label
            .font(.callout.weight(.medium))
            .foregroundStyle(JournalTheme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(JournalTheme.surfaceMuted, in: Capsule())
    }
}

enum EditorSaveState: Equatable {
    case saved
    case saving
    case failed(String)

    var label: String {
        switch self {
        case .saved: "저장됨"
        case .saving: "저장 중"
        case .failed: "저장 오류"
        }
    }

    var systemImage: String {
        switch self {
        case .saved: "checkmark.circle"
        case .saving: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        }
    }
}

struct StatusPill: View {
    let state: EditorSaveState

    var body: some View {
        Label(state.label, systemImage: state.systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(stateColor.opacity(0.10), in: Capsule())
            .accessibilityLabel(state.label)
    }

    private var stateColor: Color {
        switch state {
        case .saved: JournalTheme.brandPrimary
        case .saving: JournalTheme.inkSecondary
        case .failed: .red
        }
    }
}

struct PaperEditorSurface<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: JournalTheme.editorMaxWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(.horizontal, JournalTheme.Spacing.xLarge)
            .padding(.vertical, JournalTheme.Spacing.large)
            .background(JournalTheme.paper)
    }
}

struct JournalEmptyState<Actions: View>: View {
    let title: String
    let description: String
    let systemImage: String
    @ViewBuilder let actions: Actions

    init(
        title: String,
        description: String,
        systemImage: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.description = description
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .foregroundStyle(JournalTheme.brandPrimary)
        } description: {
            Text(description)
                .foregroundStyle(JournalTheme.inkSecondary)
        } actions: {
            actions
        }
    }
}

struct TagChip: View {
    let tag: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text("#\(tag)")
            if let remove {
                Button {
                    remove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tag) 태그 제거")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(JournalTheme.brandPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(JournalTheme.selection, in: Capsule())
    }
}

enum EntryListSummaryFormatter {
    static func title(
        explicitTitle: String,
        body: String,
        fallback: String
    ) -> String {
        let cleanedTitle = summary(from: explicitTitle)
        if !cleanedTitle.isEmpty { return cleanedTitle }

        let firstBodyLine =
            body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { summary(from: $0) } ?? ""
        return firstBodyLine.isEmpty ? fallback : firstBodyLine
    }

    static func summary(from markdown: String) -> String {
        let lines =
            markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let joined = lines.prefix(4).joined(separator: "\n")
        var output = joined
        for (regex, replacement) in EntrySummaryPatterns.replacements {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: replacement
            )
        }
        output = MarkdownEscaping.unescaped(output)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Markdown-to-plain-text rewrites for list row summaries, applied in order.
/// Compiled once: the summary is computed for every visible row.
enum EntrySummaryPatterns {
    static let replacements: [(NSRegularExpression, String)] = [
        (NSRegularExpression(literal: #"(?m)^[\s\p{Cf}]{0,8}#{1,6}\s+"#), ""),
        (NSRegularExpression(literal: #"(?m)^\s*[-*+]\s+\[[ xX]\]\s+"#), ""),
        (NSRegularExpression(literal: #"(?m)^\s*(?:[-*+]|\d+\.)\s+"#), ""),
        (NSRegularExpression(literal: #"(?m)^\s*>\s?"#), ""),
        (NSRegularExpression(literal: #"\*\*([^*]+)\*\*"#), "$1"),
        (NSRegularExpression(literal: #"(?<!\*)\*([^*]+)\*(?!\*)"#), "$1"),
        (NSRegularExpression(literal: #"__([^_]+)__"#), "$1"),
        (NSRegularExpression(literal: #"_([^_]+)_"#), "$1"),
        (NSRegularExpression(literal: #"~~([^~]+)~~"#), "$1"),
        (NSRegularExpression(literal: #"==([^=]+)=="#), "$1"),
        (NSRegularExpression(literal: #"`([^`]+)`"#), "$1"),
        (NSRegularExpression(literal: #"\[([^\]]+)\]\([^)]+\)"#), "$1"),
        (NSRegularExpression(literal: #"(?:---|\*\*\*|___)"#), " "),
        (NSRegularExpression(literal: #"\s+"#), " "),
    ]
}

#if DEBUG
private struct DesignSystemPreviewGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: JournalTheme.Spacing.regular) {
            Text("Quiet Morning")
                .font(.title.bold())
                .foregroundStyle(JournalTheme.ink)
            HStack {
                MetadataChip {
                    Label("기도노트", systemImage: "hands.sparkles")
                }
                StatusPill(state: .saved)
                TagChip(tag: "감사")
            }
            PaperEditorSurface {
                VStack(alignment: .leading, spacing: JournalTheme.Spacing.medium) {
                    Text("고요한 아침")
                        .font(.largeTitle.bold())
                    Text("오늘의 기록을 차분하게 이어서 작성합니다.")
                        .foregroundStyle(JournalTheme.inkSecondary)
                }
            }
            .frame(height: 180)
        }
        .padding(JournalTheme.Spacing.large)
        .background(JournalTheme.canvas)
    }
}

#Preview("Quiet Morning · Light") {
    DesignSystemPreviewGallery()
        .preferredColorScheme(.light)
        .frame(width: 680, height: 360)
}

#Preview("Quiet Morning · Dark") {
    DesignSystemPreviewGallery()
        .preferredColorScheme(.dark)
        .frame(width: 680, height: 360)
}
#endif
