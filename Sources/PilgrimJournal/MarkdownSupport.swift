import Foundation
import SwiftUI
#if os(macOS)
import AppKit
private typealias PlatformFont = NSFont
private typealias PlatformColor = NSColor
#elseif os(iOS)
import UIKit
private typealias PlatformFont = UIFont
private typealias PlatformColor = UIColor
#endif

private enum EditorPalette {
#if os(macOS)
    static let label = PlatformColor.labelColor
    static let secondaryLabel = PlatformColor.secondaryLabelColor
    static let tertiaryLabel = PlatformColor.tertiaryLabelColor
    static let link = PlatformColor.linkColor
    static let separator = PlatformColor.separatorColor
#else
    static let label = PlatformColor.label
    static let secondaryLabel = PlatformColor.secondaryLabel
    static let tertiaryLabel = PlatformColor.tertiaryLabel
    static let link = PlatformColor.link
    static let separator = PlatformColor.separator
#endif
}

enum MarkdownSlashCommand: String, CaseIterable, Identifiable {
    case h1
    case h2
    case h3
    case today
    case line

    var id: String { rawValue }
    var trigger: String { "/\(rawValue)" }

    var title: String {
        switch self {
        case .h1: "제목 1"
        case .h2: "제목 2"
        case .h3: "제목 3"
        case .today: "오늘 날짜"
        case .line: "구분선"
        }
    }

    var systemImage: String {
        switch self {
        case .h1: "1.square"
        case .h2: "2.square"
        case .h3: "3.square"
        case .today: "calendar"
        case .line: "minus"
        }
    }

    func insertion(today: Date, timeZone: TimeZone) -> String {
        switch self {
        case .h1: "# "
        case .h2: "## "
        case .h3: "### "
        case .today: MarkdownCommandProcessor.dateString(today, timeZone: timeZone)
        case .line: "---\n"
        }
    }
}

enum MarkdownCommandProcessor {
    struct ExpansionResult: Equatable {
        var text: String
        var cursorUTF16Offset: Int
    }

    static func expandTrailingCommand(
        in text: String,
        today: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        expandCommand(
            in: text,
            cursorUTF16Offset: text.utf16.count,
            today: today,
            timeZone: timeZone
        ).text
    }

    static func expandCommand(
        in text: String,
        cursorUTF16Offset: Int,
        today: Date = .now,
        timeZone: TimeZone = .current
    ) -> ExpansionResult {
        let source = text as NSString
        let cursor = min(max(0, cursorUTF16Offset), source.length)
        let searchRange = NSRange(location: 0, length: cursor)
        let previousNewline = source.range(
            of: "\n",
            options: .backwards,
            range: searchRange
        )
        let lineStart = previousNewline.location == NSNotFound
            ? 0
            : NSMaxRange(previousNewline)
        let lineRange = NSRange(
            location: lineStart,
            length: cursor - lineStart
        )
        let currentLine = source.substring(with: lineRange)

        for command in MarkdownSlashCommand.allCases {
            let token = command.trigger + " "
            guard currentLine == token else { continue }
            let insertion = command.insertion(today: today, timeZone: timeZone)
            let expanded = source.replacingCharacters(
                in: lineRange,
                with: insertion
            )
            return ExpansionResult(
                text: expanded,
                cursorUTF16Offset: lineStart + insertion.utf16.count
            )
        }
        return ExpansionResult(text: text, cursorUTF16Offset: cursor)
    }

    static func applying(
        _ command: MarkdownSlashCommand,
        to text: String,
        today: Date = .now,
        timeZone: TimeZone = .current
    ) -> String {
        let linePrefix = text.isEmpty || text.hasSuffix("\n") ? "" : "\n"
        return text
            + linePrefix
            + command.insertion(today: today, timeZone: timeZone)
    }

    static func dateString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private enum MarkdownBlockKind: Equatable {
    case heading1
    case heading2
    case heading3
    case paragraph
    case bullet
    case numbered(String)
    case quote
    case code
    case divider
}

private struct MarkdownBlock: Equatable {
    var kind: MarkdownBlockKind
    var content: String
}

private enum MarkdownDocumentParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeBlock = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(MarkdownBlock(
                kind: .paragraph,
                content: paragraphLines.joined(separator: "\n")
            ))
            paragraphLines.removeAll()
        }

        func flushCode() {
            blocks.append(MarkdownBlock(
                kind: .code,
                content: codeLines.joined(separator: "\n")
            ))
            codeLines.removeAll()
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "```" {
                if isInsideCodeBlock {
                    flushCode()
                } else {
                    flushParagraph()
                }
                isInsideCodeBlock.toggle()
                continue
            }
            if isInsideCodeBlock {
                codeLines.append(line)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if ["---", "***", "___"].contains(line) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .divider, content: ""))
            } else if line.hasPrefix("### ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .heading3,
                    content: String(line.dropFirst(4))
                ))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .heading2,
                    content: String(line.dropFirst(3))
                ))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .heading1,
                    content: String(line.dropFirst(2))
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .bullet,
                    content: String(line.dropFirst(2))
                ))
            } else if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .quote,
                    content: String(line.dropFirst(2))
                ))
            } else if let numbered = numberedListItem(from: line) {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .numbered(numbered.marker),
                    content: numbered.content
                ))
            } else {
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        if isInsideCodeBlock || !codeLines.isEmpty {
            flushCode()
        }
        return blocks
    }

    private static func numberedListItem(
        from line: String
    ) -> (marker: String, content: String)? {
        guard let period = line.firstIndex(of: "."),
              period != line.startIndex else { return nil }
        let number = line[..<period]
        guard number.allSatisfy(\.isNumber) else { return nil }
        let afterPeriod = line.index(after: period)
        guard afterPeriod < line.endIndex, line[afterPeriod] == " " else {
            return nil
        }
        let contentStart = line.index(after: afterPeriod)
        return ("\(number).", String(line[contentStart...]))
    }
}

struct MarkdownBodyEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 240
    var autoFocus = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(MarkdownSlashCommand.allCases) { command in
                        Button {
                            text = MarkdownCommandProcessor.applying(
                                command,
                                to: text
                            )
                        } label: {
                            Label(
                                "\(command.trigger)  \(command.title)",
                                systemImage: command.systemImage
                            )
                        }
                    }
                } label: {
                    Label("Markdown", systemImage: "textformat")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Label("입력 즉시 서식 표시", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LiveMarkdownTextEditor(text: $text, autoFocus: autoFocus)
                .frame(
                    maxWidth: .infinity,
                    minHeight: minHeight,
                    maxHeight: .infinity
                )
                .accessibilityLabel("Markdown 본문")

            Text("/h1, /h2, /h3, /today, /line 또는 줄 시작에서 * + 스페이스")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private enum LiveMarkdownStyler {
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: EditorPalette.label,
            .paragraphStyle: bodyParagraphStyle,
        ]
    }

    static func apply(to storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)

        applyInlineStyle(
            pattern: #"\*\*([^*\n]+)\*\*"#,
            trait: .bold,
            storage: storage
        )
        applyInlineStyle(
            pattern: #"(?<!\*)\*([^*\n]+)\*(?!\*)"#,
            trait: .italic,
            storage: storage
        )
        applyRegex(#"`([^`\n]+)`"#, to: storage) { match in
            storage.addAttributes([
                .font: monospacedFont,
                .backgroundColor: EditorPalette.secondaryLabel
                    .withAlphaComponent(0.12),
            ], range: match.range(at: 1))
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }
        applyRegex(#"\[([^\]\n]+)\]\(([^)\n]+)\)"#, to: storage) { match in
            storage.addAttributes([
                .foregroundColor: EditorPalette.link,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: match.range(at: 1))
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }

        applyRegex(#"(?m)^(#{1,3})[ \t]+(.*)$"#, to: storage) { match in
            let marker = (storage.string as NSString).substring(
                with: match.range(at: 1)
            )
            let contentRange = match.range(at: 2)
            let hiddenPrefixRange = NSRange(
                location: match.range.location,
                length: contentRange.location - match.range.location
            )
            let font: PlatformFont
            switch marker.count {
            case 1: font = heading1Font
            case 2: font = heading2Font
            default: font = heading3Font
            }
            storage.addAttribute(.font, value: font, range: contentRange)
            storage.addAttributes([
                .font: hiddenMarkerFont,
                .foregroundColor: PlatformColor.clear,
            ], range: hiddenPrefixRange)
        }
        applyRegex(#"(?m)^([\-*]) (.*)$"#, to: storage) { match in
            let markerAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: EditorPalette.label,
                .font: bodyFont,
                .attachment: bulletAttachment,
            ]
            storage.addAttributes(
                markerAttributes,
                range: match.range(at: 1)
            )
            storage.addAttribute(
                .paragraphStyle,
                value: bulletParagraphStyle,
                range: match.range
            )
        }
        applyRegex(#"(?m)^(\d+\.) (.*)$"#, to: storage) { match in
            storage.addAttribute(
                .foregroundColor,
                value: EditorPalette.secondaryLabel,
                range: match.range(at: 1)
            )
        }
        applyRegex(#"(?m)^(>) (.*)$"#, to: storage) { match in
            storage.addAttribute(
                .foregroundColor,
                value: EditorPalette.tertiaryLabel,
                range: match.range(at: 1)
            )
            storage.addAttribute(
                .foregroundColor,
                value: EditorPalette.secondaryLabel,
                range: match.range(at: 2)
            )
        }
        applyRegex(#"(?m)^(---|\*\*\*|___)$"#, to: storage) { match in
            storage.addAttributes([
                .foregroundColor: EditorPalette.separator,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ], range: match.range)
        }
        applyRegex(#"(?s)```(.*?)```"#, to: storage) { match in
            storage.addAttributes([
                .font: monospacedFont,
                .backgroundColor: EditorPalette.secondaryLabel
                    .withAlphaComponent(0.10),
            ], range: match.range)
        }
        storage.endEditing()
    }

    private enum FontTrait {
        case bold
        case italic
    }

    private static func applyInlineStyle(
        pattern: String,
        trait: FontTrait,
        storage: NSTextStorage
    ) {
        applyRegex(pattern, to: storage) { match in
            let contentRange = match.range(at: 1)
            let currentFont = storage.attribute(
                .font,
                at: contentRange.location,
                effectiveRange: nil
            ) as? PlatformFont ?? bodyFont
            storage.addAttribute(
                .font,
                value: font(currentFont, adding: trait),
                range: contentRange
            )
            fadeMarkers(
                in: match,
                groups: [0],
                excluding: [1],
                storage: storage
            )
        }
    }

    private static func fadeMarkers(
        in match: NSTextCheckingResult,
        groups: [Int],
        excluding: [Int],
        storage: NSTextStorage
    ) {
        for group in groups {
            var markerRanges = [match.range(at: group)]
            for excludedGroup in excluding {
                let excluded = match.range(at: excludedGroup)
                markerRanges = markerRanges.flatMap {
                    subtract(excluded, from: $0)
                }
            }
            for range in markerRanges where range.length > 0 {
                storage.addAttribute(
                    .foregroundColor,
                    value: EditorPalette.tertiaryLabel,
                    range: range
                )
            }
        }
    }

    private static func subtract(
        _ excluded: NSRange,
        from range: NSRange
    ) -> [NSRange] {
        let intersection = NSIntersectionRange(range, excluded)
        guard intersection.length > 0 else { return [range] }
        var results: [NSRange] = []
        if intersection.location > range.location {
            results.append(NSRange(
                location: range.location,
                length: intersection.location - range.location
            ))
        }
        let intersectionEnd = NSMaxRange(intersection)
        if intersectionEnd < NSMaxRange(range) {
            results.append(NSRange(
                location: intersectionEnd,
                length: NSMaxRange(range) - intersectionEnd
            ))
        }
        return results
    }

    private static func applyRegex(
        _ pattern: String,
        to storage: NSTextStorage,
        body: (NSTextCheckingResult) -> Void
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return
        }
        let range = NSRange(location: 0, length: storage.length)
        regex.matches(in: storage.string, range: range).forEach(body)
    }

    #if os(macOS)
    private static var bodyFont: NSFont {
        .preferredFont(forTextStyle: .body)
    }
    private static var heading1Font: NSFont {
        .systemFont(ofSize: 30, weight: .bold)
    }
    private static var heading2Font: NSFont {
        .systemFont(ofSize: 24, weight: .bold)
    }
    private static var heading3Font: NSFont {
        .systemFont(ofSize: 20, weight: .semibold)
    }
    private static var monospacedFont: NSFont {
        .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
    }
    private static var hiddenMarkerFont: NSFont {
        .systemFont(ofSize: 0.1)
    }
    private static func font(_ font: NSFont, adding trait: FontTrait) -> NSFont {
        NSFontManager.shared.convert(
            font,
            toHaveTrait: trait == .bold ? .boldFontMask : .italicFontMask
        )
    }
    #else
    private static var bodyFont: UIFont {
        .preferredFont(forTextStyle: .body)
    }
    private static var heading1Font: UIFont {
        .preferredFont(forTextStyle: .largeTitle).withTraits(.traitBold)
    }
    private static var heading2Font: UIFont {
        .preferredFont(forTextStyle: .title1).withTraits(.traitBold)
    }
    private static var heading3Font: UIFont {
        .preferredFont(forTextStyle: .title2).withTraits(.traitBold)
    }
    private static var monospacedFont: UIFont {
        .monospacedSystemFont(ofSize: bodyFont.pointSize, weight: .regular)
    }
    private static var hiddenMarkerFont: UIFont {
        .systemFont(ofSize: 0.1)
    }
    private static func font(_ font: UIFont, adding trait: FontTrait) -> UIFont {
        font.withTraits(trait == .bold ? .traitBold : .traitItalic)
    }
    #endif

    private static var bodyParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.paragraphSpacing = 6
        return style
    }

    private static var bulletParagraphStyle: NSParagraphStyle {
        let style = bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = 2
        style.headIndent = 20
        return style
    }

    private static var bulletAttachment: NSTextAttachment {
        let attachment = NSTextAttachment()
#if os(macOS)
        attachment.image = NSImage(
            systemSymbolName: "circle.fill",
            accessibilityDescription: "불릿"
        )
        attachment.bounds = NSRect(x: 0, y: 2, width: 6, height: 6)
#else
        attachment.image = UIImage(systemName: "circle.fill")?
            .withTintColor(EditorPalette.label, renderingMode: .alwaysOriginal)
        attachment.bounds = CGRect(x: 0, y: 2, width: 6, height: 6)
#endif
        return attachment
    }
}

#if os(macOS)
private struct LiveMarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var autoFocus: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        LiveMarkdownStyler.apply(to: textView.textStorage!)
        textView.typingAttributes = LiveMarkdownStyler.baseAttributes
        scrollView.documentView = textView

        if autoFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView,
              !context.coordinator.isUpdating else { return }
        if textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            LiveMarkdownStyler.apply(to: textView.textStorage!)
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            context.coordinator.isUpdating = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveMarkdownTextEditor
        var isUpdating = false

        init(parent: LiveMarkdownTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating,
                  let textView = notification.object as? NSTextView else {
                return
            }
            isUpdating = true
            let selection = textView.selectedRange()
            let expanded = MarkdownCommandProcessor.expandCommand(
                in: textView.string,
                cursorUTF16Offset: NSMaxRange(selection)
            )
            if expanded.text != textView.string {
                textView.string = expanded.text
                textView.setSelectedRange(NSRange(
                    location: expanded.cursorUTF16Offset,
                    length: 0
                ))
            }
            parent.text = expanded.text
            let preservedSelection = textView.selectedRange()
            LiveMarkdownStyler.apply(to: textView.textStorage!)
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.setSelectedRange(preservedSelection)
            isUpdating = false
        }
    }
}
#elseif os(iOS)
private struct LiveMarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    var autoFocus: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(
            top: 8,
            left: 0,
            bottom: 8,
            right: 0
        )
        textView.text = text
        LiveMarkdownStyler.apply(to: textView.textStorage)
        textView.typingAttributes = LiveMarkdownStyler.baseAttributes
        if autoFocus {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        guard !context.coordinator.isUpdating else { return }
        if textView.text != text {
            context.coordinator.isUpdating = true
            textView.text = text
            LiveMarkdownStyler.apply(to: textView.textStorage)
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            context.coordinator.isUpdating = false
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveMarkdownTextEditor
        var isUpdating = false

        init(parent: LiveMarkdownTextEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            isUpdating = true
            let selection = textView.selectedRange
            let expanded = MarkdownCommandProcessor.expandCommand(
                in: textView.text,
                cursorUTF16Offset: NSMaxRange(selection)
            )
            if expanded.text != textView.text {
                textView.text = expanded.text
                textView.selectedRange = NSRange(
                    location: expanded.cursorUTF16Offset,
                    length: 0
                )
            }
            parent.text = expanded.text
            let preservedSelection = textView.selectedRange
            LiveMarkdownStyler.apply(to: textView.textStorage)
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.selectedRange = preservedSelection
            isUpdating = false
        }
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif

struct MarkdownPreviewView: View {
    let markdown: String

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
        case .heading1:
            inlineText(block.content)
                .font(.largeTitle.bold())
        case .heading2:
            inlineText(block.content)
                .font(.title.bold())
        case .heading3:
            inlineText(block.content)
                .font(.title2.bold())
        case .paragraph:
            inlineText(block.content)
                .font(.body)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                inlineText(block.content)
            }
        case let .numbered(marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .monospacedDigit()
                inlineText(block.content)
            }
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(.secondary)
                    .frame(width: 3)
                inlineText(block.content)
                    .foregroundStyle(.secondary)
            }
        case .code:
            ScrollView(.horizontal) {
                Text(block.content)
                    .font(.system(.body, design: .monospaced))
                    .padding(10)
            }
            .background(.quaternary.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(
            markdown: source,
            options: options
        ) {
            return Text(attributed)
        }
        return Text(source)
    }
}
