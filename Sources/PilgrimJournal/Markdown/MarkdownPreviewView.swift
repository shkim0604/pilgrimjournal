import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct MarkdownPreviewView: View {
    @EnvironmentObject private var model: AppModel
    /// Read so a Dynamic Type change re-renders and `bodyCapHeight` follows it.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let markdown: String

    /// Cap height of the body text style, which list items render in.
    private var bodyCapHeight: CGFloat {
        #if os(iOS)
        UIFont.preferredFont(forTextStyle: .body).capHeight
        #else
        NSFont.preferredFont(forTextStyle: .body).capHeight
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(
                Array(MarkdownDocumentParser.parse(markdown).enumerated()),
                id: \.offset
            ) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case let .heading(level):
            inlineText(block.content)
                .font(headingFont(level: level))
        case .paragraph:
            inlineText(block.content)
                .font(.body)
        case let .bullet(indentation):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The same 6pt dot the editor draws, centred on the first
                // line's capital letters like there. A "•" glyph sits right
                // but renders noticeably smaller than the editor's dot.
                Circle()
                    .fill(JournalTheme.ink)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions.height / 2 + bodyCapHeight / 2
                    }
                    .accessibilityHidden(true)
                inlineText(block.content)
            }
            .padding(.leading, CGFloat(indentation) * 18)
        case let .numbered(marker, indentation):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .monospacedDigit()
                inlineText(block.content)
            }
            .padding(.leading, CGFloat(indentation) * 18)
        case let .checklist(checked, indentation):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .accessibilityLabel(checked ? "완료" : "미완료")
                inlineText(block.content)
                    .foregroundStyle(checked ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(indentation) * 18)
        case .quote:
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(JournalTheme.brandPrimary.opacity(0.65))
                    .frame(width: 3)
                inlineText(block.content)
                    .font(.body.italic())
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .padding(.vertical, 2)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(JournalTheme.brandPrimary.opacity(0.055))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.small,
                    style: .continuous
                ))
        case let .code(language):
            ScrollView(.horizontal) {
                Text(highlightedCode(block.content, language: language))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(codeBlockForeground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(codeBlockBackground)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.small,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.small,
                    style: .continuous
                )
                .stroke(codeBlockBorder, lineWidth: 1)
            }
        case .divider:
            Divider()
        case let .image(attachmentID):
            AttachmentImageView(attachmentID: attachmentID)
        }
    }

    private func inlineText(_ source: String) -> Text {
        let sourceString = source as NSString
        let fullRange = NSRange(location: 0, length: sourceString.length)
        let matches = MarkdownPatterns.highlight.matches(in: source, range: fullRange)
        guard !matches.isEmpty else { return markdownText(source) }

        var result = Text("")
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result =
                    result
                    + markdownText(
                        sourceString.substring(
                            with: NSRange(
                                location: cursor,
                                length: match.range.location - cursor
                            )))
            }
            var highlighted = inlineAttributedString(
                sourceString.substring(with: match.range(at: 1))
            )
            highlighted.backgroundColor = Color.yellow.opacity(0.28)
            result = result + Text(highlighted)
            cursor = NSMaxRange(match.range)
        }
        if cursor < sourceString.length {
            result = result + markdownText(sourceString.substring(from: cursor))
        }
        return result
    }

    private var codeBlockBackground: Color {
        #if os(macOS)
        Color(nsColor: EditorPalette.codeBackground)
        #else
        Color(uiColor: EditorPalette.codeBackground)
        #endif
    }

    private var codeBlockForeground: Color {
        #if os(macOS)
        Color(nsColor: EditorPalette.codeForeground)
        #else
        Color(uiColor: EditorPalette.codeForeground)
        #endif
    }

    private var codeBlockBorder: Color {
        #if os(macOS)
        Color(nsColor: EditorPalette.codeBorder)
        #else
        Color(uiColor: EditorPalette.codeBorder)
        #endif
    }

    private func highlightedCode(
        _ source: String,
        language: String?
    ) -> AttributedString {
        let value = NSMutableAttributedString(string: source)
        let range = NSRange(location: 0, length: source.utf16.count)
        value.addAttribute(
            .foregroundColor,
            value: EditorPalette.codeForeground,
            range: range
        )
        CodeSyntaxHighlighter.apply(
            to: value,
            range: range,
            language: language
        )
        #if os(macOS)
        return (try? AttributedString(value, including: \.appKit))
            ?? AttributedString(source)
        #else
        return (try? AttributedString(value, including: \.uiKit))
            ?? AttributedString(source)
        #endif
    }

    private func markdownText(_ source: String) -> Text {
        Text(inlineAttributedString(source))
    }

    private func inlineAttributedString(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(
            markdown: source,
            options: options
        ) {
            return attributed
        }
        return AttributedString(source)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .largeTitle.bold()
        case 2: .title.bold()
        case 3: .title2.bold()
        case 4: .title3.bold()
        case 5: .headline
        default: .subheadline.bold()
        }
    }
}

/// Loads and decodes its attachment off `body` — the previous
/// `MarkdownPreviewView.attachmentImageView` did both
/// `model.attachmentData(for:)` (disk I/O) and full-resolution image
/// decoding directly inside a `@ViewBuilder`, which reruns on every render
/// of the enclosing view, not just when the attachment actually changes.
/// `.task(id:)` here only redoes the load when the attachment id changes or
/// `attachmentRevision` bumps (e.g. a background CloudKit download
/// finishes) — mirrors the pattern already used by
/// `AttachmentDownloadStatusView` in EntryViews.swift.
private struct AttachmentImageView: View {
    @EnvironmentObject private var model: AppModel
    let attachmentID: UUID
    @State private var image: Image?
    @State private var hasLocalBinary = false

    var body: some View {
        Group {
            if let image {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: JournalTheme.Radius.small,
                            style: .continuous
                        ))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                    Text(
                        hasLocalBinary
                            ? "이미지를 표시할 수 없습니다"
                            : "이미지를 아직 사용할 수 없음 · 동기화 대기 중"
                    )
                    .font(.caption)
                }
                .foregroundStyle(JournalTheme.inkSecondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(JournalTheme.brandPrimary.opacity(0.055))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: JournalTheme.Radius.small,
                        style: .continuous
                    ))
            }
        }
        .task(id: "\(attachmentID)#\(model.attachmentRevision)") {
            image = nil
            guard let data = model.attachmentData(for: attachmentID) else {
                hasLocalBinary = model.hasLocalBinary(for: attachmentID)
                return
            }
            hasLocalBinary = true
            guard
                let decoded = await AttachmentImageCache.shared.loadAndCache(
                    id: attachmentID, data: data
                )
            else { return }
            guard !Task.isCancelled else { return }
            #if os(macOS)
            image = Image(nsImage: decoded)
            #elseif os(iOS)
            image = Image(uiImage: decoded)
            #endif
        }
    }
}
