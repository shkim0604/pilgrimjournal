import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let applyMarkdownKeyboardCommand = Notification.Name(
        "PilgrimJournal.applyMarkdownKeyboardCommand"
    )
}

enum EditorTextScale {
    /// `@AppStorage` key shared by the menu, the editor and the app scene.
    static let storageKey = "editor-text-scale"
    static let defaultValue = 1.15
    static let minimum = 0.7
    static let maximum = 1.6
}

enum EditorTiming {
    /// Pause in typing before a draft is saved.
    static let autosaveDelay: Duration = .milliseconds(650)
    /// Pause in typing before the whole document is restyled.
    static let stylingDebounce: Duration = .milliseconds(250)
}
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#elseif os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

extension NSRegularExpression {
    /// Compiles a pattern written as a literal in this module. An invalid
    /// literal is a programming error, caught by `testEveryEditorPatternCompiles`.
    convenience init(literal pattern: String) {
        try! self.init(pattern: pattern)
    }
}

/// Every Markdown pattern the editor, preview and code highlighter use,
/// compiled once. Styling reruns on every pause in typing, so compiling the
/// same literals on each pass was wasted work.
enum MarkdownPatterns {
    static let boldAsterisks = NSRegularExpression(literal: #"(?<!\\)\*\*([^*\n]+)(?<!\\)\*\*"#)
    static let boldUnderscores = NSRegularExpression(literal: #"(?<!\\)__([^_\n]+)(?<!\\)__"#)
    static let italicAsterisk = NSRegularExpression(
        literal: #"(?<![\\*])\*([^*\n]+)(?<!\\)\*(?!\*)"#)
    static let italicUnderscore = NSRegularExpression(
        literal: #"(?<![\\_])_([^_\n]+)(?<!\\)_(?!_)"#)
    static let strikethrough = NSRegularExpression(literal: #"(?<!\\)~~([^~\n]+)(?<!\\)~~"#)
    static let highlight = NSRegularExpression(literal: #"(?<!\\)==([^=\n]+)(?<!\\)=="#)
    static let inlineCode = NSRegularExpression(literal: #"`([^`\n]+)`"#)
    static let link = NSRegularExpression(literal: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#)
    static let heading = NSRegularExpression(literal: #"(?m)^(#{1,6})[ \t]+(.*)$"#)
    static let bulletItem = NSRegularExpression(literal: #"(?m)^([ \t]*)([\-*]) (.*)$"#)
    static let orderedItem = NSRegularExpression(literal: #"(?m)^(\d+\.) (.*)$"#)
    static let checklistItem = NSRegularExpression(
        literal: #"(?m)^([ \t]*)([-*]) (\[([ xX])\]) (.*)$"#)
    static let quote = NSRegularExpression(literal: #"(?m)^(>) (.*)$"#)
    static let horizontalRule = NSRegularExpression(literal: #"(?m)^(---|\*\*\*|___)$"#)
    static let codeFence = NSRegularExpression(literal: #"(?s)(```[^\n]*\n?)(.*?)(\n?```)"#)
    static let listLine = NSRegularExpression(
        literal: #"^([ \t]*)(?:(\*|-)|(\d+)\.)(?: (\[[ xX]\]))? (.*)$"#)
    static let escapedPunctuation = NSRegularExpression(
        literal: #"\\([\u0021-\u002F\u003A-\u0040\u005B-\u0060\u007B-\u007E])"#)

    static let codeKeyword = NSRegularExpression(
        literal:
            #"\b(?:actor|and|any|as|async|await|break|case|catch|class|const|continue|def|default|do|else|enum|extension|false|final|for|from|func|function|guard|if|import|in|is|let|new|nil|not|null|or|private|protocol|public|return|self|some|static|struct|switch|this|throw|throws|true|try|typealias|var|where|while)\b"#
    )
    static let codeNumber = NSRegularExpression(literal: #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#)
    static let codeString = NSRegularExpression(literal: #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#)
    static let hashComment = NSRegularExpression(literal: #"(?m)#.*$"#)
    static let lineComment = NSRegularExpression(literal: #"(?m)//.*$"#)
    static let blockComment = NSRegularExpression(literal: #"(?s)/\*.*?\*/"#)

    static var all: [NSRegularExpression] {
        [
            boldAsterisks,
            boldUnderscores,
            italicAsterisk,
            italicUnderscore,
            strikethrough,
            highlight,
            inlineCode,
            link,
            heading,
            bulletItem,
            orderedItem,
            checklistItem,
            quote,
            horizontalRule,
            codeFence,
            listLine,
            escapedPunctuation,
            codeKeyword,
            codeNumber,
            codeString,
            hashComment,
            lineComment,
            blockComment,
        ]
    }
}

/// List nesting depth from a line's leading whitespace: two spaces or one
/// tab per level, matching what the editor's Tab key inserts.
enum MarkdownIndentation {
    static func level(of indentation: some StringProtocol) -> Int {
        let spaces = indentation.reduce(into: 0) { count, character in
            count += character == "\t" ? 2 : 1
        }
        return spaces / 2
    }
}

private enum EditorPalette {
    #if os(macOS)
    static let label = PlatformColor.labelColor
    static let secondaryLabel = PlatformColor.secondaryLabelColor
    static let tertiaryLabel = PlatformColor.tertiaryLabelColor
    static let link = PlatformColor.linkColor
    static let separator = PlatformColor.separatorColor
    static let highlight = PlatformColor.systemYellow.withAlphaComponent(0.28)
    static let codeBackground = PlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor(
                calibratedRed: 0.082,
                green: 0.114,
                blue: 0.102,
                alpha: 1
            )
            : PlatformColor(
                calibratedRed: 0.933,
                green: 0.953,
                blue: 0.929,
                alpha: 1
            )
    }
    static let codeForeground = PlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor(
                calibratedRed: 0.902,
                green: 0.929,
                blue: 0.910,
                alpha: 1
            )
            : PlatformColor(
                calibratedRed: 0.141,
                green: 0.200,
                blue: 0.180,
                alpha: 1
            )
    }
    static let codeBorder = PlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor(
                calibratedRed: 0.204,
                green: 0.255,
                blue: 0.231,
                alpha: 1
            )
            : PlatformColor(
                calibratedRed: 0.796,
                green: 0.847,
                blue: 0.816,
                alpha: 1
            )
    }
    static let codeKeyword = PlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor(calibratedRed: 0.502, green: 0.749, blue: 0.682, alpha: 1)
            : PlatformColor(calibratedRed: 0.184, green: 0.420, blue: 0.384, alpha: 1)
    }
    static let codeString = PlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor(calibratedRed: 0.851, green: 0.631, blue: 0.494, alpha: 1)
            : PlatformColor(calibratedRed: 0.604, green: 0.357, blue: 0.271, alpha: 1)
    }
    static let codeNumber = PlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor(calibratedRed: 0.714, green: 0.643, blue: 0.831, alpha: 1)
            : PlatformColor(calibratedRed: 0.427, green: 0.353, blue: 0.541, alpha: 1)
    }
    static let codeComment = PlatformColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor(calibratedRed: 0.498, green: 0.569, blue: 0.529, alpha: 1)
            : PlatformColor(calibratedRed: 0.459, green: 0.510, blue: 0.482, alpha: 1)
    }
    static let quoteBar = PlatformColor.controlAccentColor.withAlphaComponent(0.7)
    #else
    static let label = PlatformColor.label
    static let secondaryLabel = PlatformColor.secondaryLabel
    static let tertiaryLabel = PlatformColor.tertiaryLabel
    static let link = PlatformColor.link
    static let separator = PlatformColor.separator
    static let highlight = PlatformColor.systemYellow.withAlphaComponent(0.28)
    static let codeBackground = PlatformColor { traits in
        traits.userInterfaceStyle == .dark
            ? PlatformColor(red: 0.082, green: 0.114, blue: 0.102, alpha: 1)
            : PlatformColor(red: 0.933, green: 0.953, blue: 0.929, alpha: 1)
    }
    static let codeForeground = PlatformColor { traits in
        traits.userInterfaceStyle == .dark
            ? PlatformColor(red: 0.902, green: 0.929, blue: 0.910, alpha: 1)
            : PlatformColor(red: 0.141, green: 0.200, blue: 0.180, alpha: 1)
    }
    static let codeBorder = PlatformColor { traits in
        traits.userInterfaceStyle == .dark
            ? PlatformColor(red: 0.204, green: 0.255, blue: 0.231, alpha: 1)
            : PlatformColor(red: 0.796, green: 0.847, blue: 0.816, alpha: 1)
    }
    static let codeKeyword = PlatformColor { traits in
        traits.userInterfaceStyle == .dark
            ? PlatformColor(red: 0.502, green: 0.749, blue: 0.682, alpha: 1)
            : PlatformColor(red: 0.184, green: 0.420, blue: 0.384, alpha: 1)
    }
    static let codeString = PlatformColor { traits in
        traits.userInterfaceStyle == .dark
            ? PlatformColor(red: 0.851, green: 0.631, blue: 0.494, alpha: 1)
            : PlatformColor(red: 0.604, green: 0.357, blue: 0.271, alpha: 1)
    }
    static let codeNumber = PlatformColor { traits in
        traits.userInterfaceStyle == .dark
            ? PlatformColor(red: 0.714, green: 0.643, blue: 0.831, alpha: 1)
            : PlatformColor(red: 0.427, green: 0.353, blue: 0.541, alpha: 1)
    }
    static let codeComment = PlatformColor { traits in
        traits.userInterfaceStyle == .dark
            ? PlatformColor(red: 0.498, green: 0.569, blue: 0.529, alpha: 1)
            : PlatformColor(red: 0.459, green: 0.510, blue: 0.482, alpha: 1)
    }
    static let quoteBar = PlatformColor.tintColor.withAlphaComponent(0.7)
    #endif
}

enum MarkdownSlashCommand: String, CaseIterable, Identifiable {
    case h1
    case h2
    case h3
    case h4
    case h5
    case h6
    case bullet
    case numbered
    case checklist
    case quote
    case code
    case today
    case line

    var id: String { rawValue }
    var trigger: String { "/\(rawValue)" }

    var title: String {
        switch self {
        case .h1: "제목 1"
        case .h2: "제목 2"
        case .h3: "제목 3"
        case .h4: "제목 4"
        case .h5: "제목 5"
        case .h6: "제목 6"
        case .bullet: "불릿 목록"
        case .numbered: "번호 목록"
        case .checklist: "체크리스트"
        case .quote: "인용문"
        case .code: "코드 블록"
        case .today: "오늘 날짜"
        case .line: "구분선"
        }
    }

    /// `title` for display. `title` itself stays the Korean source text
    /// because the slash-command palette also matches typed queries against
    /// it; this is only what the menu and palette show.
    var displayTitle: String {
        switch self {
        case .h1: String(localized: "제목 1")
        case .h2: String(localized: "제목 2")
        case .h3: String(localized: "제목 3")
        case .h4: String(localized: "제목 4")
        case .h5: String(localized: "제목 5")
        case .h6: String(localized: "제목 6")
        case .bullet: String(localized: "불릿 목록")
        case .numbered: String(localized: "번호 목록")
        case .checklist: String(localized: "체크리스트")
        case .quote: String(localized: "인용문")
        case .code: String(localized: "코드 블록")
        case .today: String(localized: "오늘 날짜")
        case .line: String(localized: "구분선")
        }
    }

    var systemImage: String {
        switch self {
        case .h1: "1.square"
        case .h2: "2.square"
        case .h3: "3.square"
        case .h4, .h5, .h6: "textformat.size"
        case .bullet: "list.bullet"
        case .numbered: "list.number"
        case .checklist: "checklist"
        case .quote: "text.quote"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .today: "calendar"
        case .line: "minus"
        }
    }

    func insertion(today: Date, timeZone: TimeZone) -> String {
        switch self {
        case .h1: "# "
        case .h2: "## "
        case .h3: "### "
        case .h4: "#### "
        case .h5: "##### "
        case .h6: "###### "
        case .bullet: "* "
        case .numbered: "1. "
        case .checklist: "- [ ] "
        case .quote: "> "
        case .code: "```\n\n```\n"
        case .today: MarkdownCommandProcessor.dateString(today, timeZone: timeZone)
        case .line: "---\n"
        }
    }
}

enum MarkdownInlineFormat: String, CaseIterable, Identifiable {
    case bold
    case italic
    case strikethrough
    case highlight
    case code
    case heading
    case bullet
    case quote
    case link

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bold: String(localized: "굵게")
        case .italic: String(localized: "기울임")
        case .strikethrough: String(localized: "취소선")
        case .highlight: String(localized: "하이라이트")
        case .code: String(localized: "인라인 코드")
        case .heading:
            String(
                localized: "editor.heading", defaultValue: "제목", comment: "Markdown heading command"
            )
        case .bullet: String(localized: "불릿")
        case .quote: String(localized: "인용")
        case .link: String(localized: "링크")
        }
    }

    var systemImage: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .heading: "textformat.size"
        case .bullet: "list.bullet"
        case .quote: "text.quote"
        case .link: "link"
        }
    }

    static let contextualCases: [MarkdownInlineFormat] = [
        .bold, .italic, .heading, .bullet, .quote, .link,
    ]
}

enum MarkdownKeyboardCommand: String {
    case bold
    case italic
    case link
    case numberedList
    case bulletList
    case quote
    case heading1
    case heading2
    case heading3
    case indentList
    case outdentList
}

enum MarkdownListIndentDirection {
    case indent
    case outdent
}

enum MarkdownImageMoveDirection {
    case up
    case down
}

enum MarkdownCommandProcessor {
    struct ExpansionResult: Equatable {
        var text: String
        var cursorUTF16Offset: Int
        var selectionUTF16Range: NSRange? = nil
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
        let lineStart =
            previousNewline.location == NSNotFound
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

    static func trailingSlashQuery(in text: String) -> String? {
        // `split(separator:)` builds an array of every line in the whole
        // document just to take the last one — called from
        // `MarkdownBodyEditor.body` on every render. A backwards search for
        // the last newline finds the last line directly, in time
        // proportional to that line's length (typically short — the cursor
        // is on it), not the whole document.
        let line =
            text.range(of: "\n", options: .backwards).map { text[$0.upperBound...] }
            ?? text[...]
        guard line.hasPrefix("/"), !line.contains(" ") else { return nil }
        return String(line.dropFirst()).lowercased()
    }

    static func replacingTrailingSlashCommand(
        _ command: MarkdownSlashCommand,
        in text: String,
        today: Date = .now,
        timeZone: TimeZone = .current
    ) -> ExpansionResult {
        let source = text as NSString
        let previousNewline = source.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: source.length)
        )
        let lineStart =
            previousNewline.location == NSNotFound
            ? 0
            : NSMaxRange(previousNewline)
        let range = NSRange(location: lineStart, length: source.length - lineStart)
        let insertion = command.insertion(today: today, timeZone: timeZone)
        return ExpansionResult(
            text: source.replacingCharacters(in: range, with: insertion),
            cursorUTF16Offset: lineStart + insertion.utf16.count
        )
    }

    static func applying(
        _ format: MarkdownInlineFormat,
        to text: String,
        selection: NSRange
    ) -> ExpansionResult {
        let source = text as NSString
        let safeLocation = min(max(0, selection.location), source.length)
        let safeLength = min(max(0, selection.length), source.length - safeLocation)
        let safeSelection = NSRange(location: safeLocation, length: safeLength)
        let selected = source.substring(with: safeSelection)

        let surroundingMarker: String? =
            switch format {
            case .bold: "**"
            case .italic: "*"
            case .strikethrough: "~~"
            case .highlight: "=="
            case .code: "`"
            case .heading, .bullet, .quote, .link: nil
            }
        if let marker = surroundingMarker {
            let markerLength = marker.utf16.count
            if safeLength >= markerLength * 2,
                selected.hasPrefix(marker),
                selected.hasSuffix(marker)
            {
                return ExpansionResult(
                    text: text,
                    cursorUTF16Offset: NSMaxRange(safeSelection),
                    selectionUTF16Range: safeSelection
                )
            }
            let leadingRange = NSRange(
                location: safeLocation - markerLength,
                length: markerLength
            )
            let trailingRange = NSRange(
                location: NSMaxRange(safeSelection),
                length: markerLength
            )
            if leadingRange.location >= 0,
                NSMaxRange(trailingRange) <= source.length,
                source.substring(with: leadingRange) == marker,
                source.substring(with: trailingRange) == marker
            {
                return ExpansionResult(
                    text: text,
                    cursorUTF16Offset: NSMaxRange(safeSelection),
                    selectionUTF16Range: safeSelection
                )
            }
        }

        let replacement: String
        let cursor: Int
        switch format {
        case .bold:
            replacement = "**\(selected)**"
            cursor = safeLocation + replacement.utf16.count
        case .italic:
            replacement = "*\(selected)*"
            cursor = safeLocation + replacement.utf16.count
        case .strikethrough:
            replacement = "~~\(selected)~~"
            cursor = safeLocation + replacement.utf16.count
        case .highlight:
            replacement = "==\(selected)=="
            cursor = safeLocation + replacement.utf16.count
        case .code:
            replacement = "`\(selected)`"
            cursor = safeLocation + replacement.utf16.count
        case .link:
            replacement = "[\(selected)](https://)"
            cursor = safeLocation + replacement.utf16.count - 1
        case .heading, .bullet, .quote:
            let lineRange = source.lineRange(for: safeSelection)
            let lines = source.substring(with: lineRange)
            let prefix =
                switch format {
                case .heading: "## "
                case .bullet: "* "
                case .quote: "> "
                default: ""
                }
            replacement =
                lines
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    let value = String(line)
                    return value.isEmpty ? value : prefix + value
                }
                .joined(separator: "\n")
            let changed = source.replacingCharacters(in: lineRange, with: replacement)
            return ExpansionResult(
                text: changed,
                cursorUTF16Offset: lineRange.location + replacement.utf16.count,
                selectionUTF16Range: NSRange(
                    location: lineRange.location,
                    length: replacement.utf16.count
                )
            )
        }
        let preservedSelection: NSRange =
            switch format {
            case .bold, .strikethrough, .highlight:
                NSRange(location: safeLocation + 2, length: safeLength)
            case .italic, .code, .link:
                NSRange(location: safeLocation + 1, length: safeLength)
            case .heading, .bullet, .quote:
                safeSelection
            }
        return ExpansionResult(
            text: source.replacingCharacters(in: safeSelection, with: replacement),
            cursorUTF16Offset: cursor,
            selectionUTF16Range: preservedSelection
        )
    }

    /// Inserts an `attachment:` image reference at the cursor, forcing
    /// newlines around it so it always occupies its own line — the parser
    /// classifies blocks line-by-line, and a marker sharing a line with
    /// other text would render as literal paragraph text everywhere,
    /// including in the preview surface that renders it as an image.
    static func insertingAttachmentImage(
        id: UUID,
        displaySize: CGSize? = nil,
        into text: String,
        selection: NSRange
    ) -> ExpansionResult {
        let source = text as NSString
        let safeLocation = min(max(0, selection.location), source.length)
        let safeLength = min(max(0, selection.length), source.length - safeLocation)
        let safeSelection = NSRange(location: safeLocation, length: safeLength)
        let before = source.substring(to: safeSelection.location)
        let after = source.substring(from: NSMaxRange(safeSelection))
        let leadingNewline = before.isEmpty || before.hasSuffix("\n") ? "" : "\n"
        let trailingNewline = after.isEmpty || after.hasPrefix("\n") ? "" : "\n"
        let sizeSuffix =
            displaySize.map {
                " =\(Int($0.width.rounded()))x\(Int($0.height.rounded()))"
            } ?? ""
        let insertion =
            "\(leadingNewline)![](attachment:\(id.uuidString)\(sizeSuffix))\(trailingNewline)"
        let expanded = source.replacingCharacters(in: safeSelection, with: insertion)
        let cursor = safeSelection.location + insertion.utf16.count
        return ExpansionResult(text: expanded, cursorUTF16Offset: cursor)
    }

    /// Where an image added from outside the text view (photo picker, camera,
    /// 파일, the keyboard bar) goes: the caret the body last had, or the end
    /// of the body when it was never focused and so has no caret yet.
    ///
    /// Unlike a paste, a photo arriving from a sheet never replaces a
    /// selection — it goes after it — and never splits another image's marker,
    /// which would turn that picture back into raw markdown.
    static func attachmentInsertionSelection(lastCaret: NSRange?, in text: String) -> NSRange {
        let length = (text as NSString).length
        guard let lastCaret else { return NSRange(location: length, length: 0) }
        var location = min(max(0, NSMaxRange(lastCaret)), length)
        if let marker = MarkdownAttachmentImageDecoration.matches(in: text).first(where: {
            location > $0.markerRange.location && location < NSMaxRange($0.markerRange)
        }) {
            location = NSMaxRange(marker.markerRange)
        }
        return NSRange(location: location, length: 0)
    }

    /// Moves the image whose line contains `offset` past the nearest line
    /// with content in `direction`, by swapping the two lines. Blank lines
    /// stay where they are, so the spacing between paragraphs survives. The
    /// caret follows the image to the start of its new line, so ▲/▼ can be
    /// pressed again straight away. `nil` when there is no image there or
    /// nothing to move past.
    static func movingAttachmentImage(
        at offset: Int,
        direction: MarkdownImageMoveDirection,
        in text: String
    ) -> ExpansionResult? {
        guard
            let match = MarkdownAttachmentImageDecoration.matches(in: text).first(where: {
                offset >= $0.markerRange.location && offset <= NSMaxRange($0.markerRange)
            })
        else { return nil }
        var lines = text.components(separatedBy: "\n")
        // The marker is the whole line, so the newlines before it number its line.
        let imageLine =
            (text as NSString).substring(to: match.markerRange.location)
            .components(separatedBy: "\n").count - 1
        let step = direction == .up ? -1 : 1
        var target = imageLine + step
        while lines.indices.contains(target), lines[target].allSatisfy(\.isWhitespace) {
            target += step
        }
        guard lines.indices.contains(target) else { return nil }
        lines.swapAt(imageLine, target)
        let caret = lines[..<target].reduce(0) { $0 + ($1 as NSString).length + 1 }
        return ExpansionResult(text: lines.joined(separator: "\n"), cursorUTF16Offset: caret)
    }

    static func applyingKeyboardCommand(
        _ command: MarkdownKeyboardCommand,
        to text: String,
        selection: NSRange
    ) -> ExpansionResult {
        switch command {
        case .bold:
            return applying(MarkdownInlineFormat.bold, to: text, selection: selection)
        case .italic:
            return applying(MarkdownInlineFormat.italic, to: text, selection: selection)
        case .link:
            return applying(MarkdownInlineFormat.link, to: text, selection: selection)
        case .bulletList:
            return applying(MarkdownInlineFormat.bullet, to: text, selection: selection)
        case .quote:
            return applying(MarkdownInlineFormat.quote, to: text, selection: selection)
        case .numberedList:
            return applyingLinePrefix(
                to: text,
                selection: selection,
                prefix: { index in "\(index + 1). " }
            )
        case .heading1:
            return applyingHeading(level: 1, to: text, selection: selection)
        case .heading2:
            return applyingHeading(level: 2, to: text, selection: selection)
        case .heading3:
            return applyingHeading(level: 3, to: text, selection: selection)
        case .indentList:
            return adjustingListIndentation(
                in: text,
                selection: selection,
                direction: .indent
            )
        case .outdentList:
            return adjustingListIndentation(
                in: text,
                selection: selection,
                direction: .outdent
            )
        }
    }

    static func adjustingListIndentation(
        in text: String,
        selection: NSRange,
        direction: MarkdownListIndentDirection
    ) -> ExpansionResult {
        let source = text as NSString
        let safeSelection = clamped(selection, to: source.length)
        let lineRange = source.lineRange(for: safeSelection)
        let lines = source.substring(with: lineRange)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var changed = false
        let replacement = lines.map { substring -> String in
            let line = String(substring)
            guard listItem(from: line) != nil else { return line }
            switch direction {
            case .indent:
                changed = true
                return "  " + line
            case .outdent:
                if line.hasPrefix("\t") {
                    changed = true
                    return String(line.dropFirst())
                }
                let removableSpaces = min(
                    2,
                    line.prefix(while: { $0 == " " }).count
                )
                guard removableSpaces > 0 else { return line }
                changed = true
                return String(line.dropFirst(removableSpaces))
            }
        }
        .joined(separator: "\n")
        guard changed else {
            return ExpansionResult(
                text: text,
                cursorUTF16Offset: NSMaxRange(safeSelection),
                selectionUTF16Range: safeSelection
            )
        }

        let result = source.replacingCharacters(in: lineRange, with: replacement)
        if safeSelection.length == 0 {
            let delta = replacement.utf16.count - lineRange.length
            let cursor = max(lineRange.location, safeSelection.location + delta)
            return ExpansionResult(
                text: result,
                cursorUTF16Offset: cursor,
                selectionUTF16Range: NSRange(location: cursor, length: 0)
            )
        }
        let changedRange = NSRange(
            location: lineRange.location,
            length: replacement.utf16.count
        )
        return ExpansionResult(
            text: result,
            cursorUTF16Offset: NSMaxRange(changedRange),
            selectionUTF16Range: changedRange
        )
    }

    private static func applyingHeading(
        level: Int,
        to text: String,
        selection: NSRange
    ) -> ExpansionResult {
        applyingLinePrefix(
            to: text,
            selection: selection,
            prefix: { _ in String(repeating: "#", count: level) + " " },
            stripping: { line in
                line.replacingOccurrences(
                    of: #"^#{1,6}[ \t]+"#,
                    with: "",
                    options: .regularExpression
                )
            }
        )
    }

    private static func applyingLinePrefix(
        to text: String,
        selection: NSRange,
        prefix: (Int) -> String,
        stripping: (String) -> String = { $0 }
    ) -> ExpansionResult {
        let source = text as NSString
        let safeLocation = min(max(0, selection.location), source.length)
        let safeLength = min(
            max(0, selection.length),
            source.length - safeLocation
        )
        let lineRange = source.lineRange(
            for: NSRange(
                location: safeLocation,
                length: safeLength
            ))
        let lines = source.substring(with: lineRange)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var itemIndex = 0
        let replacement = lines.map { substring -> String in
            let line = stripping(String(substring))
            guard !line.isEmpty else { return line }
            defer { itemIndex += 1 }
            return prefix(itemIndex) + line
        }
        .joined(separator: "\n")
        let changed = source.replacingCharacters(in: lineRange, with: replacement)
        let changedRange = NSRange(
            location: lineRange.location,
            length: replacement.utf16.count
        )
        return ExpansionResult(
            text: changed,
            cursorUTF16Offset: NSMaxRange(changedRange),
            selectionUTF16Range: changedRange
        )
    }

    static func continuingBullet(
        in text: String,
        cursorUTF16Offset: Int
    ) -> ExpansionResult {
        continuingList(in: text, cursorUTF16Offset: cursorUTF16Offset)
    }

    static func continuingList(
        in text: String,
        cursorUTF16Offset: Int
    ) -> ExpansionResult {
        let source = text as NSString
        let cursor = min(max(0, cursorUTF16Offset), source.length)
        guard cursor > 0,
            source.substring(with: NSRange(location: cursor - 1, length: 1)) == "\n"
        else { return ExpansionResult(text: text, cursorUTF16Offset: cursor) }
        let beforeNewline = NSRange(location: 0, length: cursor - 1)
        let priorNewline = source.range(
            of: "\n",
            options: .backwards,
            range: beforeNewline
        )
        let lineStart =
            priorNewline.location == NSNotFound
            ? 0
            : NSMaxRange(priorNewline)
        let previousLine = source.substring(
            with: NSRange(
                location: lineStart,
                length: cursor - lineStart - 1
            ))
        guard let item = listItem(from: previousLine) else {
            return ExpansionResult(text: text, cursorUTF16Offset: cursor)
        }
        if item.content.isEmpty {
            let removeRange = NSRange(
                location: lineStart,
                length: previousLine.utf16.count
            )
            return ExpansionResult(
                text: source.replacingCharacters(in: removeRange, with: ""),
                cursorUTF16Offset: cursor - removeRange.length
            )
        }
        let marker: String
        if let number = item.number {
            marker = "\(number + 1)."
        } else {
            marker = item.bullet ?? "-"
        }
        let checklist = item.isChecklist ? " [ ]" : ""
        let insertion = "\(item.indentation)\(marker)\(checklist) "
        let expanded = source.replacingCharacters(
            in: NSRange(location: cursor, length: 0),
            with: insertion
        )
        return ExpansionResult(
            text: expanded,
            cursorUTF16Offset: cursor + insertion.utf16.count
        )
    }

    /// Removes a list marker (indentation + bullet/number/checklist + the
    /// following space) when the cursor sits exactly at the start of that
    /// item's content, i.e. nothing but the marker itself precedes the
    /// cursor on the current line. Returns nil when the cursor isn't at a
    /// marker boundary, so a plain single-character backspace is what the
    /// caller should fall back to.
    ///
    /// The marker character is rendered invisible by `LiveMarkdownStyler`
    /// (color: clear) so it can still be styled as a list, which makes
    /// deleting it one character at a time via the default backspace feel
    /// broken — nothing visibly changes on the press that removes the
    /// invisible marker glyph itself. Removing the whole marker in one
    /// press, mirroring the empty-item removal already done on Return
    /// (`continuingList`), fixes that.
    static func removingListMarkerBeforeCursor(
        in text: String,
        cursorUTF16Offset: Int
    ) -> ExpansionResult? {
        let source = text as NSString
        let cursor = min(max(0, cursorUTF16Offset), source.length)
        guard cursor > 0 else { return nil }
        let beforeCursor = NSRange(location: 0, length: cursor)
        let priorNewline = source.range(
            of: "\n",
            options: .backwards,
            range: beforeCursor
        )
        let lineStart =
            priorNewline.location == NSNotFound
            ? 0
            : NSMaxRange(priorNewline)
        guard lineStart < cursor else { return nil }
        let prefix = source.substring(
            with: NSRange(
                location: lineStart,
                length: cursor - lineStart
            ))
        // Matching with an empty `content` group means `prefix` is exactly
        // the marker (whatever comes after the cursor on this line, if
        // anything, is untouched by the removal below).
        guard let item = listItem(from: prefix), item.content.isEmpty else {
            return nil
        }
        let removeRange = NSRange(
            location: lineStart,
            length: prefix.utf16.count
        )
        return ExpansionResult(
            text: source.replacingCharacters(in: removeRange, with: ""),
            cursorUTF16Offset: lineStart,
            selectionUTF16Range: NSRange(location: lineStart, length: 0)
        )
    }

    private static func listItem(
        from line: String
    ) -> (
        indentation: String,
        bullet: String?,
        number: Int?,
        isChecklist: Bool,
        content: String
    )? {
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        guard let match = MarkdownPatterns.listLine.firstMatch(in: line, range: range) else {
            return nil
        }
        func value(at index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return source.substring(with: range)
        }
        return (
            value(at: 1) ?? "",
            value(at: 2),
            value(at: 3).flatMap(Int.init),
            value(at: 4) != nil,
            value(at: 5) ?? ""
        )
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

enum MarkdownBlockKind: Equatable {
    case heading(Int)
    case paragraph
    case bullet(Int)
    case numbered(String, Int)
    case checklist(Bool, Int)
    case quote
    case code(String?)
    case divider
    case image(UUID)
}

struct MarkdownBlock: Equatable {
    var kind: MarkdownBlockKind
    var content: String
}

enum MarkdownDocumentParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var blocks: [MarkdownBlock] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var isInsideCodeBlock = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(
                MarkdownBlock(
                    kind: .paragraph,
                    content: paragraphLines.joined(separator: "\n")
                ))
            paragraphLines.removeAll()
        }

        func flushCode() {
            blocks.append(
                MarkdownBlock(
                    kind: .code(codeLanguage),
                    content: codeLines.joined(separator: "\n")
                ))
            codeLines.removeAll()
            codeLanguage = nil
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if isInsideCodeBlock {
                    flushCode()
                } else {
                    flushParagraph()
                    let fence = line.trimmingCharacters(in: .whitespaces)
                    let language = String(fence.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
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
            let indentation = indentationLevel(in: line)
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            let contentLine = String(stripped)
            if ["---", "***", "___"].contains(contentLine) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .divider, content: ""))
            } else if let heading = heading(from: contentLine) {
                flushParagraph()
                blocks.append(
                    MarkdownBlock(
                        kind: .heading(heading.level),
                        content: heading.content
                    ))
            } else if let checklist = checklistItem(from: contentLine) {
                flushParagraph()
                blocks.append(
                    MarkdownBlock(
                        kind: .checklist(checklist.checked, indentation),
                        content: checklist.content
                    ))
            } else if contentLine.hasPrefix("- ")
                || contentLine.hasPrefix("* ")
            {
                flushParagraph()
                blocks.append(
                    MarkdownBlock(
                        kind: .bullet(indentation),
                        content: String(contentLine.dropFirst(2))
                    ))
            } else if contentLine.hasPrefix("> ") {
                flushParagraph()
                blocks.append(
                    MarkdownBlock(
                        kind: .quote,
                        content: String(contentLine.dropFirst(2))
                    ))
            } else if let numbered = numberedListItem(from: contentLine) {
                flushParagraph()
                blocks.append(
                    MarkdownBlock(
                        kind: .numbered(numbered.marker, indentation),
                        content: numbered.content
                    ))
            } else if let attachmentID = attachmentImageID(from: contentLine) {
                flushParagraph()
                blocks.append(MarkdownBlock(kind: .image(attachmentID), content: ""))
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

    private static func indentationLevel(in line: String) -> Int {
        MarkdownIndentation.level(of: line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    private static func heading(
        from line: String
    ) -> (level: Int, content: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count),
            line.dropFirst(hashes.count).hasPrefix(" ")
        else {
            return nil
        }
        return (hashes.count, String(line.dropFirst(hashes.count + 1)))
    }

    private static func checklistItem(
        from line: String
    ) -> (checked: Bool, content: String)? {
        guard line.hasPrefix("- [") || line.hasPrefix("* ["),
            line.count >= 6
        else { return nil }
        let source = line as NSString
        let marker = source.substring(with: NSRange(location: 2, length: 3))
        guard ["[ ]", "[x]", "[X]"].contains(marker),
            source.substring(with: NSRange(location: 5, length: 1)) == " "
        else {
            return nil
        }
        return (marker.lowercased() == "[x]", source.substring(from: 6))
    }

    /// Same rule as the live editor, so the preview never shows an image the
    /// editor would leave as text, or the other way round.
    private static func attachmentImageID(from line: String) -> UUID? {
        guard let match = MarkdownAttachmentImageDecoration.matches(in: line).first,
            match.markerRange.length == (line as NSString).length
        else { return nil }
        return match.attachmentID
    }

    private static func numberedListItem(
        from line: String
    ) -> (marker: String, content: String)? {
        guard let period = line.firstIndex(of: "."),
            period != line.startIndex
        else { return nil }
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

/// The buttons shown above the keyboard while the iPhone body is edited.
///
/// SwiftUI's `.toolbar(placement: .keyboard)` only attaches to SwiftUI text
/// inputs, so the body's UIKit text view never showed it. The iPhone editor
/// passes the same items down through the environment
/// (`markdownKeyboardAccessory`) and the text view shows them in a
/// `UIToolbar` of its own.
struct MarkdownKeyboardAccessory {
    struct Item {
        var title: String
        /// `nil` shows `title` as a text button.
        var systemImage: String?
        var action: () -> Void
    }

    var leading: [Item]
    /// Placed after a flexible space.
    var trailing: [Item]

    var items: [Item] { leading + trailing }

    /// What is on screen. The editor rebuilds this value (closures included)
    /// on every render, so the toolbar is only rebuilt when this changes.
    var signature: [String] {
        leading.map(Self.key) + ["|"] + trailing.map(Self.key)
    }

    private static func key(_ item: Item) -> String {
        "\(item.title)\u{1F}\(item.systemImage ?? "")"
    }
}

private struct MarkdownKeyboardAccessoryKey: EnvironmentKey {
    static var defaultValue: MarkdownKeyboardAccessory? { nil }
}

extension EnvironmentValues {
    var markdownKeyboardAccessory: MarkdownKeyboardAccessory? {
        get { self[MarkdownKeyboardAccessoryKey.self] }
        set { self[MarkdownKeyboardAccessoryKey.self] = newValue }
    }
}

/// Where a photo the person asked to put into the body comes from.
enum AttachmentPhotoSource {
    case library
    case camera
}

/// Lets views outside the body editor — the 첨부 section — put an image they
/// just stored into the body. The editor's coordinator does the insertion,
/// through the same `replaceExternalText` path as a pasted image, so it
/// undoes and is recorded as the editor's own text like every other
/// programmatic edit (see docs/known-issues.md, 편집기 입력이 씹힌다). Only the
/// iPhone editor connects one; elsewhere `insertImage` reports `false`.
@MainActor
final class MarkdownImageInserter {
    var handler: ((UUID, Data) -> Bool)?

    @discardableResult
    func insertImage(id: UUID, data: Data) -> Bool {
        handler?(id, data) ?? false
    }
}

struct MarkdownBodyEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 240
    var autoFocus = false
    var storeImageAttachment: ((Data, String, String) async -> UUID?)?
    var attachmentImage: ((UUID) async -> Data?)?
    /// Bumped whenever any attachment's state changes (e.g. a background
    /// CloudKit download finishes). Lets the editor retry attachments it
    /// previously failed to load, without needing to reopen the entry.
    var attachmentRevision = 0
    /// The Markdown menu row and the slash-command hint. The iPhone's focus
    /// mode turns them off; the text editor itself never depends on this.
    var showsChrome = true
    /// iPhone only: see `MarkdownImageInserter`.
    var imageInserter: MarkdownImageInserter?
    /// iPhone only: the edit menu's 사진 삽입 asks for a photo through this.
    var requestImageInsertion: ((AttachmentPhotoSource) -> Void)?
    @State private var selection = NSRange(location: 0, length: 0)
    @AppStorage(EditorTextScale.storageKey) private var editorTextScale =
        EditorTextScale.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Conditional siblings keep `LiveMarkdownTextEditor` at the same
            // structural position, so toggling the chrome never re-creates
            // the text view (and never drops keystrokes in flight).
            if showsChrome {
                markdownMenuRow
            }

            liveEditor
                .frame(
                    maxWidth: .infinity,
                    minHeight: minHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .accessibilityLabel("Markdown 본문")

            Color.clear
                .frame(width: 0, height: 0)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .applyMarkdownKeyboardCommand
                    )
                ) { notification in
                    guard let rawValue = notification.object as? String,
                        let command = MarkdownKeyboardCommand(rawValue: rawValue)
                    else { return }
                    #if os(macOS)
                    guard MacMarkdownEditorFocus.isFocused else { return }
                    #endif
                    apply(command)
                }

            if let query = MarkdownCommandProcessor.trailingSlashQuery(in: text) {
                commandPalette(query: query)
            }

            if showsChrome {
                Text("/ 입력으로 제목, 목록, 체크리스트, 인용, 코드와 날짜 삽입")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var markdownMenuRow: some View {
        HStack(spacing: 10) {
            Menu {
                Section("블록") {
                    ForEach(MarkdownSlashCommand.allCases) { command in
                        Button {
                            text = MarkdownCommandProcessor.applying(
                                command,
                                to: text
                            )
                        } label: {
                            Label(
                                "\(command.trigger)  \(command.displayTitle)",
                                systemImage: command.systemImage
                            )
                        }
                    }
                }
                if selection.length > 0 {
                    Section("선택 영역") {
                        ForEach(MarkdownInlineFormat.allCases) { format in
                            Button {
                                apply(format)
                            } label: {
                                Label(format.title, systemImage: format.systemImage)
                            }
                        }
                    }
                }
            } label: {
                Label("Markdown", systemImage: "textformat")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if selection.length > 0 {
                Divider().frame(height: 18)
                ForEach(MarkdownInlineFormat.contextualCases) { format in
                    Button {
                        apply(format)
                    } label: {
                        Image(systemName: format.systemImage)
                    }
                    .buttonStyle(.plain)
                    .help(format.title)
                    .accessibilityLabel(format.title)
                }
            }

            Spacer()

            Label("입력 즉시 서식 표시", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var liveEditor: LiveMarkdownTextEditor {
        var editor = LiveMarkdownTextEditor(
            text: $text,
            selection: $selection,
            autoFocus: autoFocus,
            textScale: editorTextScale,
            storeImageAttachment: storeImageAttachment,
            attachmentImage: attachmentImage,
            attachmentRevision: attachmentRevision
        )
        editor.minimumHeight = minHeight
        #if os(iOS)
        editor.imageInserter = imageInserter
        editor.requestImageInsertion = requestImageInsertion
        #endif
        return editor
    }

    private func apply(_ format: MarkdownInlineFormat) {
        let result = MarkdownCommandProcessor.applying(
            format,
            to: text,
            selection: selection
        )
        text = result.text
        selection =
            result.selectionUTF16Range
            ?? NSRange(location: result.cursorUTF16Offset, length: 0)
    }

    private func apply(_ command: MarkdownKeyboardCommand) {
        let result = MarkdownCommandProcessor.applyingKeyboardCommand(
            command,
            to: text,
            selection: selection
        )
        text = result.text
        selection =
            result.selectionUTF16Range
            ?? NSRange(location: result.cursorUTF16Offset, length: 0)
    }

    @ViewBuilder
    private func commandPalette(query: String) -> some View {
        let matches = MarkdownSlashCommand.allCases.filter {
            query.isEmpty
                || $0.rawValue.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("명령")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                ForEach(matches) { command in
                    Button {
                        let result =
                            MarkdownCommandProcessor
                            .replacingTrailingSlashCommand(command, in: text)
                        text = result.text
                        selection = NSRange(
                            location: result.cursorUTF16Offset,
                            length: 0
                        )
                    } label: {
                        HStack {
                            Image(systemName: command.systemImage)
                                .frame(width: 22)
                            Text(command.displayTitle)
                            Spacer()
                            Text(command.trigger)
                                .font(.caption.monospaced())
                                .foregroundStyle(JournalTheme.inkSecondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(JournalTheme.ink)
            .background(JournalTheme.surfaceMuted)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.medium,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: JournalTheme.Radius.medium)
                    .stroke(JournalTheme.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Markdown 명령")
        }
    }
}

enum MarkdownEscaping {
    private static var regex: NSRegularExpression { MarkdownPatterns.escapedPunctuation }

    static func markerRanges(in markdown: String) -> [NSRange] {
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).map {
            NSRange(location: $0.range.location, length: 1)
        }
    }

    static func unescaped(_ markdown: String) -> String {
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.stringByReplacingMatches(
            in: markdown,
            range: range,
            withTemplate: "$1"
        )
    }
}

private enum CodeSyntaxHighlighter {
    static func apply(
        to value: NSMutableAttributedString,
        range: NSRange,
        language: String?
    ) {
        color(
            MarkdownPatterns.codeKeyword, with: EditorPalette.codeKeyword, in: value, range: range)
        color(MarkdownPatterns.codeNumber, with: EditorPalette.codeNumber, in: value, range: range)

        let stringRanges = matches(MarkdownPatterns.codeString, in: value.string, range: range)
            .map(\.range)
        stringRanges.forEach {
            value.addAttribute(.foregroundColor, value: EditorPalette.codeString, range: $0)
        }

        let normalizedLanguage = language?.lowercased() ?? ""
        let commentPatterns: [NSRegularExpression]
        if ["python", "py", "shell", "sh", "bash", "zsh", "ruby", "rb"]
            .contains(normalizedLanguage)
        {
            commentPatterns = [MarkdownPatterns.hashComment]
        } else if ["json"].contains(normalizedLanguage) {
            commentPatterns = []
        } else {
            commentPatterns = [MarkdownPatterns.lineComment, MarkdownPatterns.blockComment]
        }
        for pattern in commentPatterns {
            for match in matches(pattern, in: value.string, range: range) {
                guard
                    !stringRanges.contains(where: {
                        NSIntersectionRange($0, match.range).length > 0
                    })
                else { continue }
                value.addAttribute(
                    .foregroundColor,
                    value: EditorPalette.codeComment,
                    range: match.range
                )
            }
        }
    }

    private static func color(
        _ regex: NSRegularExpression,
        with color: PlatformColor,
        in value: NSMutableAttributedString,
        range: NSRange
    ) {
        matches(regex, in: value.string, range: range).forEach {
            value.addAttribute(.foregroundColor, value: color, range: $0.range)
        }
    }

    private static func matches(
        _ regex: NSRegularExpression,
        in source: String,
        range: NSRange
    ) -> [NSTextCheckingResult] {
        regex.matches(in: source, range: range)
    }
}

enum LiveMarkdownStyler {
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: EditorPalette.label,
            .paragraphStyle: bodyParagraphStyle,
        ]
    }

    static func apply(
        to storage: NSTextStorage,
        revealing selection: NSRange? = nil,
        containerWidth: CGFloat = 600
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)

        applyInlineStyle(
            regex: MarkdownPatterns.boldAsterisks,
            trait: .bold,
            storage: storage
        )
        applyInlineStyle(
            regex: MarkdownPatterns.boldUnderscores,
            trait: .bold,
            storage: storage
        )
        applyInlineStyle(
            regex: MarkdownPatterns.italicAsterisk,
            trait: .italic,
            storage: storage
        )
        applyInlineStyle(
            regex: MarkdownPatterns.italicUnderscore,
            trait: .italic,
            storage: storage
        )
        applyRegex(MarkdownPatterns.strikethrough, to: storage) { match in
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: match.range(at: 1)
            )
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }
        applyRegex(MarkdownPatterns.highlight, to: storage) { match in
            storage.addAttribute(
                .backgroundColor,
                value: EditorPalette.highlight,
                range: match.range(at: 1)
            )
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }
        applyRegex(MarkdownPatterns.inlineCode, to: storage) { match in
            storage.addAttributes(
                [
                    .font: monospacedFont,
                    .backgroundColor: EditorPalette.secondaryLabel
                        .withAlphaComponent(0.12),
                ], range: match.range(at: 1))
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }
        applyRegex(MarkdownPatterns.link, to: storage) { match in
            storage.addAttributes(
                [
                    .foregroundColor: EditorPalette.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: match.range(at: 1))
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }

        applyRegex(MarkdownPatterns.heading, to: storage) { match in
            let marker = (storage.string as NSString).substring(
                with: match.range(at: 1)
            )
            let contentRange = match.range(at: 2)
            let hiddenPrefixRange = NSRange(
                location: match.range.location,
                length: contentRange.location - match.range.location
            )
            let font = headingFont(level: marker.count)
            storage.addAttribute(.font, value: font, range: contentRange)
            storage.addAttributes(
                [
                    .font: hiddenMarkerFont,
                    .foregroundColor: PlatformColor.clear,
                ], range: hiddenPrefixRange)
        }
        applyRegex(MarkdownPatterns.bulletItem, to: storage) { match in
            storage.addAttributes(
                [
                    .foregroundColor: PlatformColor.clear,
                    .font: bodyFont,
                    // The marker glyph is invisible but still occupies its own
                    // width; the drawn dot replaces it. This kern widens the
                    // gap between the dot and the following content — without
                    // it, only a single space's width separates them.
                    // `bulletParagraphStyle`'s headIndent measures using this
                    // exact same value, so the gap and the wrap-alignment never
                    // drift apart.
                    .kern: bulletMarkerKern,
                ], range: match.range(at: 2))
            storage.addAttribute(
                .paragraphStyle,
                value: bulletParagraphStyle(
                    indentationLevel: indentationLevel(
                        of: match.range(at: 1),
                        in: storage.string
                    )
                ),
                range: match.range
            )
        }
        applyRegex(MarkdownPatterns.orderedItem, to: storage) { match in
            storage.addAttribute(
                .foregroundColor,
                value: EditorPalette.secondaryLabel,
                range: match.range(at: 1)
            )
        }
        applyRegex(MarkdownPatterns.checklistItem, to: storage) { match in
            let state = (storage.string as NSString).substring(
                with: match.range(at: 4)
            )
            let checked = state.lowercased() == "x"
            // The checkbox itself is drawn by MarkdownChecklistDecoration
            // (same technique as the bullet dot) rather than an
            // NSTextAttachment: an attachment only renders when it replaces
            // a character with the U+FFFC placeholder, but this editor
            // never mutates the underlying markdown characters — doing so
            // would corrupt the saved source text. Setting `.attachment` as
            // a bare attribute on the existing "-" character is a no-op;
            // AppKit/UIKit's glyph generator ignores it for ordinary
            // characters, so it silently fell back to showing "-".
            storage.addAttributes(
                [
                    .foregroundColor: PlatformColor.clear,
                    .font: bodyFont,
                    .kern: bulletMarkerKern,
                ], range: match.range(at: 2))
            storage.addAttributes(
                [
                    .font: hiddenMarkerFont,
                    .foregroundColor: PlatformColor.clear,
                ], range: match.range(at: 3))
            storage.addAttribute(
                .paragraphStyle,
                value: bulletParagraphStyle(
                    indentationLevel: indentationLevel(
                        of: match.range(at: 1),
                        in: storage.string
                    )
                ),
                range: match.range
            )
            if checked {
                storage.addAttributes(
                    [
                        .foregroundColor: EditorPalette.secondaryLabel,
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    ], range: match.range(at: 5))
            }
        }
        for imageMatch in MarkdownAttachmentImageDecoration.matches(in: storage.string) {
            // Hidden the same way checklist/bullet markers are — draw(_:)
            // renders the actual decoded image over this reserved space
            // instead. Never an NSTextAttachment (see the checklist comment
            // above): the saved characters must stay exactly
            // `![](attachment:id ...)`.
            storage.addAttributes(
                [
                    .foregroundColor: PlatformColor.clear,
                    .font: hiddenMarkerFont,
                ], range: imageMatch.markerRange)
            storage.addAttribute(
                .paragraphStyle,
                value: attachmentImageParagraphStyle(
                    storedWidth: imageMatch.storedWidth,
                    storedHeight: imageMatch.storedHeight,
                    containerWidth: containerWidth
                ),
                range: imageMatch.markerRange
            )
        }
        applyRegex(MarkdownPatterns.quote, to: storage) { match in
            #if os(macOS)
            storage.addAttributes(
                [
                    .font: hiddenMarkerFont,
                    .foregroundColor: PlatformColor.clear,
                ], range: match.range(at: 1))
            #else
            storage.addAttributes(
                [
                    .font: bodyFont,
                    .foregroundColor: EditorPalette.quoteBar,
                ], range: match.range(at: 1))
            #endif
            storage.addAttributes(
                [
                    .foregroundColor: EditorPalette.secondaryLabel,
                    .paragraphStyle: quoteParagraphStyle(),
                ], range: match.range)
        }
        applyRegex(MarkdownPatterns.horizontalRule, to: storage) { match in
            storage.addAttributes(
                [
                    .font: hiddenMarkerFont,
                    .foregroundColor: PlatformColor.clear,
                    .paragraphStyle: separatorParagraphStyle,
                ], range: match.range)
        }
        applyRegex(MarkdownPatterns.codeFence, to: storage) { match in
            storage.addAttributes(
                [
                    .font: monospacedFont,
                    .foregroundColor: EditorPalette.codeForeground,
                    .backgroundColor: EditorPalette.codeBackground,
                    .paragraphStyle: codeParagraphStyle(),
                ], range: match.range)
            let opening = (storage.string as NSString).substring(
                with: match.range(at: 1)
            )
            let language = String(opening.dropFirst(3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            CodeSyntaxHighlighter.apply(
                to: storage,
                range: match.range(at: 2),
                language: language.isEmpty ? nil : language
            )
            [match.range(at: 1), match.range(at: 3)].forEach { markerRange in
                storage.addAttributes(
                    [
                        .font: hiddenMarkerFont,
                        .foregroundColor: PlatformColor.clear,
                    ], range: markerRange)
            }
        }
        styleEscapedMarkers(in: storage, revealing: selection)
        storage.endEditing()
    }

    private static func styleEscapedMarkers(
        in storage: NSTextStorage,
        revealing selection: NSRange?
    ) {
        for markerRange in MarkdownEscaping.markerRanges(in: storage.string) {
            let tokenRange = NSRange(location: markerRange.location, length: 2)
            let isActive: Bool
            if let selection {
                if selection.length == 0 {
                    isActive =
                        selection.location >= tokenRange.location
                        && selection.location <= NSMaxRange(tokenRange)
                } else {
                    isActive = NSIntersectionRange(selection, tokenRange).length > 0
                }
            } else {
                isActive = false
            }
            storage.addAttributes(
                isActive
                    ? [
                        .font: bodyFont,
                        .foregroundColor: EditorPalette.tertiaryLabel,
                    ]
                    : [
                        .font: hiddenMarkerFont,
                        .foregroundColor: PlatformColor.clear,
                    ],
                range: markerRange
            )
        }
    }

    private enum FontTrait {
        case bold
        case italic
    }

    private static func applyInlineStyle(
        regex: NSRegularExpression,
        trait: FontTrait,
        storage: NSTextStorage
    ) {
        applyRegex(regex, to: storage) { match in
            let contentRange = match.range(at: 1)
            let currentFont =
                storage.attribute(
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
            results.append(
                NSRange(
                    location: range.location,
                    length: intersection.location - range.location
                ))
        }
        let intersectionEnd = NSMaxRange(intersection)
        if intersectionEnd < NSMaxRange(range) {
            results.append(
                NSRange(
                    location: intersectionEnd,
                    length: NSMaxRange(range) - intersectionEnd
                ))
        }
        return results
    }

    private static func applyRegex(
        _ regex: NSRegularExpression,
        to storage: NSTextStorage,
        body: (NSTextCheckingResult) -> Void
    ) {
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
    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1: heading1Font
        case 2: heading2Font
        case 3: heading3Font
        case 4: .systemFont(ofSize: 18, weight: .semibold)
        case 5: .systemFont(ofSize: 16, weight: .semibold)
        default: .systemFont(ofSize: 15, weight: .semibold)
        }
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
    private static func headingFont(level: Int) -> UIFont {
        switch level {
        case 1: heading1Font
        case 2: heading2Font
        case 3: heading3Font
        case 4: .preferredFont(forTextStyle: .title3).withTraits(.traitBold)
        case 5: .preferredFont(forTextStyle: .headline)
        default: .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        }
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

    /// Gap between the drawn bullet dot and the following text — applied as
    /// `.kern` on the hidden marker character, so it also occupies real
    /// glyph advance width (unlike `hiddenMarkerFont`-hidden markers, which
    /// are sized to ~0 width on purpose).
    private static let bulletMarkerKern: CGFloat = 6
    /// Additional per-level indent for nested bullets, layered *on top of*
    /// the 2-space-per-level the source text already carries (inserted by
    /// `adjustingListIndentation`) — the natural 2-space width alone reads
    /// as too subtle to distinguish nesting visually.
    private static let bulletExtraIndentPerLevel: CGFloat = 14

    /// `headIndent` controls where a *wrapped* continuation line lands, and
    /// must match exactly where the marker-hidden first line's visible text
    /// begins — not an approximation. The marker ("-"/"*") is hidden via
    /// `.foregroundColor: clear`, not a near-zero font size, so it (plus
    /// `bulletMarkerKern` and the literal trailing space) still occupies
    /// real `bodyFont` glyph width that a wrapped line must account for, on
    /// top of one level's worth of leading whitespace repeated
    /// `indentationLevel` times (those characters are real, un-hidden text).
    private static func bulletParagraphStyle(indentationLevel: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(bodyParagraphStyle)
        let base: CGFloat = 4 + CGFloat(indentationLevel) * bulletExtraIndentPerLevel
        let markerWidth = measuredWidth("-", kern: bulletMarkerKern) + measuredWidth(" ")
        let levelWhitespaceWidth = CGFloat(indentationLevel) * measuredWidth("  ")
        style.firstLineHeadIndent = base
        style.headIndent = base + levelWhitespaceWidth + markerWidth
        return style
    }

    private static func measuredWidth(_ text: String, kern: CGFloat = 0) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: bodyFont, .kern: kern]).width
    }

    private static func indentationLevel(of range: NSRange, in text: String) -> Int {
        MarkdownIndentation.level(of: (text as NSString).substring(with: range))
    }

    private static func quoteParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(bodyParagraphStyle)
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        style.tailIndent = -12
        style.paragraphSpacingBefore = 4
        style.paragraphSpacing = 8
        #if os(macOS)
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let block = NSTextTableBlock(
            table: table,
            startingRow: 0,
            rowSpan: 1,
            startingColumn: 0,
            columnSpan: 1
        )
        block.backgroundColor = EditorPalette.quoteBar.withAlphaComponent(0.06)
        block.setBorderColor(nil)
        block.setBorderColor(EditorPalette.quoteBar, for: .minX)
        block.setWidth(
            3,
            type: .absoluteValueType,
            for: .border,
            edge: .minX
        )
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin)
        style.textBlocks = [block]
        #endif
        return style
    }

    private static func codeParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(bodyParagraphStyle)
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        style.tailIndent = -12
        style.lineSpacing = 3
        style.paragraphSpacingBefore = 8
        style.paragraphSpacing = 8
        #if os(macOS)
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        let block = NSTextTableBlock(
            table: table,
            startingRow: 0,
            rowSpan: 1,
            startingColumn: 0,
            columnSpan: 1
        )
        block.backgroundColor = EditorPalette.codeBackground
        block.setBorderColor(EditorPalette.codeBorder)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(4, type: .absoluteValueType, for: .margin)
        style.textBlocks = [block]
        #endif
        return style
    }

    private static var separatorParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(bodyParagraphStyle)
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 6
        return style
    }

    /// The displayed height of an inline attachment image, clamped to fit
    /// `containerWidth` while preserving aspect ratio, reserved as fixed
    /// line height so TextKit1 lays the surrounding text out around the
    /// space `draw(_:)` later paints the decoded image into. Mirrors
    /// `separatorParagraphStyle`'s min/max-line-height technique.
    static func attachmentImageDisplaySize(
        storedWidth: CGFloat?,
        storedHeight: CGFloat?,
        containerWidth: CGFloat
    ) -> CGSize {
        let maxWidth = max(containerWidth, 40)
        let rawWidth = storedWidth ?? maxWidth
        let rawHeight = storedHeight ?? (rawWidth * 0.6)
        guard rawWidth > 0, rawHeight > 0 else {
            return CGSize(width: maxWidth, height: maxWidth * 0.6)
        }
        guard rawWidth > maxWidth else { return CGSize(width: rawWidth, height: rawHeight) }
        let scale = maxWidth / rawWidth
        return CGSize(width: maxWidth, height: rawHeight * scale)
    }

    private static let headingPrefixRegex = try! NSRegularExpression(
        pattern: #"^(#{1,6})[ \t]+"#
    )

    /// The attributes text typed at the end of `linePrefix` should carry.
    ///
    /// Styling is derived by `apply` from the whole document on a debounce,
    /// and that debounce is cancelled by every non-whitespace keystroke, so
    /// text typed into a heading would sit at body size until something else
    /// triggered a restyle — the heading only snapped to its real size once
    /// Return was pressed. Typing attributes carry the block's own size
    /// instead, so it looks like a heading from the first character.
    static func typingAttributes(
        forLinePrefix linePrefix: String
    ) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        let range = NSRange(location: 0, length: (linePrefix as NSString).length)
        guard
            let match = headingPrefixRegex.firstMatch(
                in: linePrefix, range: range
            )
        else { return attributes }
        attributes[.font] = headingFont(level: match.range(at: 1).length)
        return attributes
    }

    /// Shared with the resize-drag and window-resize recompute paths in the
    /// Coordinators below, so all three ways an image's reserved height can
    /// change build that height the exact same way.
    static func attachmentImageParagraphStyle(
        storedWidth: CGFloat?,
        storedHeight: CGFloat?,
        containerWidth: CGFloat
    ) -> NSParagraphStyle {
        let size = attachmentImageDisplaySize(
            storedWidth: storedWidth, storedHeight: storedHeight, containerWidth: containerWidth
        )
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(bodyParagraphStyle)
        style.minimumLineHeight = size.height
        style.maximumLineHeight = size.height
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 6
        return style
    }

}

enum MarkdownBulletDecoration {
    struct Match {
        var markerRange: NSRange
        /// 0 = top level (filled dot); 1+ = nested (hollow ring). Computed
        /// the same way as `MarkdownDocumentParser.indentationLevel` — two
        /// spaces or one tab per level.
        var indentationLevel: Int
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"(?m)^([ \t]*)([\-*]) (?!\[[ xX]\] )"#
    )

    static func matches(in text: String) -> [Match] {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.matches(in: text, range: range).map { result in
            Match(
                markerRange: result.range(at: 2),
                indentationLevel: MarkdownIndentation.level(
                    of: source.substring(with: result.range(at: 1))
                )
            )
        }
    }
}

/// Locates checklist markers so the editor can draw an actual checkbox over
/// the (hidden) "-"/"*" character — see the comment in
/// `LiveMarkdownStyler`'s checklist regex for why this can't be an
/// `NSTextAttachment` in a source-preserving live editor.
enum MarkdownChecklistDecoration {
    struct Match {
        var markerRange: NSRange
        /// The single character between the brackets — what a toggle rewrites.
        var stateRange: NSRange
        var checked: Bool

        /// The character a toggle writes into `stateRange`.
        ///
        /// The saved characters are the only source of truth for the state — the
        /// checkbox is painted from them — so toggling is a text edit, which also
        /// means it lands in the undo stack and syncs like any other edit.
        var toggledState: String { checked ? " " : "x" }
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*([\-*]) \[([ xX])\] "#
    )

    static func matches(in text: String) -> [Match] {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.matches(in: text, range: range).map { result in
            let state = source.substring(with: result.range(at: 2))
            return Match(
                markerRange: result.range(at: 1),
                stateRange: result.range(at: 2),
                checked: state.lowercased() == "x"
            )
        }
    }

    /// The box drawn over the (hidden) list marker. Shared between `draw(_:)`
    /// and the tap/click hit test so what is clicked is always what was
    /// painted — the same discipline `imageRect` follows for attachments.
    static let boxSize: CGFloat = 15

    static func boxRect(origin: CGPoint, markerBounds: CGRect) -> CGRect {
        CGRect(
            x: origin.x + markerBounds.minX,
            y: origin.y + markerBounds.midY - boxSize / 2,
            width: boxSize,
            height: boxSize
        )
    }
}

/// Locates `![](attachment:<uuid>)` (optionally ` =WIDTHxHEIGHT`) marker
/// lines so the live editor can reserve line height for and draw the actual
/// image in place of the (hidden) raw syntax — same "find it, draw over it,
/// never touch the saved characters" technique as bullets/checklists above.
enum MarkdownAttachmentImageDecoration {
    struct Match {
        /// The whole marker line — this is what gets hidden (colored clear)
        /// and given the paragraph style that reserves the image's height.
        var markerRange: NSRange
        var attachmentID: UUID
        var storedWidth: CGFloat?
        var storedHeight: CGFloat?
    }

    private static let regex = try! NSRegularExpression(
        pattern: #"(?m)^!\[\]\(attachment:([0-9A-Fa-f-]{36})(?:[ \t]+=(\d+)x(\d+))?\)$"#
    )

    static func matches(in text: String) -> [Match] {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        return regex.matches(in: text, range: range).compactMap { result in
            let idRange = result.range(at: 1)
            guard let attachmentID = UUID(uuidString: source.substring(with: idRange))
            else { return nil }
            let widthRange = result.range(at: 2)
            let heightRange = result.range(at: 3)
            let storedWidth =
                widthRange.location != NSNotFound
                ? CGFloat(Int(source.substring(with: widthRange)) ?? 0)
                : nil
            let storedHeight =
                heightRange.location != NSNotFound
                ? CGFloat(Int(source.substring(with: heightRange)) ?? 0)
                : nil
            return Match(
                markerRange: result.range,
                attachmentID: attachmentID,
                storedWidth: storedWidth,
                storedHeight: storedHeight
            )
        }
    }

    /// Where a keystroke should go when the caret is sitting on an image
    /// line, or `nil` when it isn't and the keystroke can be taken as-is.
    ///
    /// An image line is atomic: the saved characters have to stay exactly
    /// `![](attachment:id …)` for the marker to be recognised, so a single
    /// character typed into it stops it matching and the picture is replaced
    /// by its raw markdown. Editors that model images as blocks (Notion,
    /// Bear) never let text be typed into the image itself — it goes to a
    /// line of its own, above the image if the caret was at its start and
    /// below otherwise. That's what this computes.
    static func insertionRelocation(
        in text: String,
        cursorUTF16Offset: Int
    ) -> InsertionRelocation? {
        guard
            let match = matches(in: text).first(where: {
                cursorUTF16Offset >= $0.markerRange.location
                    && cursorUTF16Offset <= NSMaxRange($0.markerRange)
            })
        else { return nil }
        let atStart = cursorUTF16Offset == match.markerRange.location
        let newlineOffset =
            atStart
            ? match.markerRange.location
            : NSMaxRange(match.markerRange)
        return InsertionRelocation(
            newlineOffset: newlineOffset,
            // Above the image the caret stays put and the image moves down;
            // below it, the caret follows the newline it just created.
            caretOffset: atStart ? newlineOffset : newlineOffset + 1
        )
    }

    struct InsertionRelocation: Equatable {
        /// Where the newline separating text from the image belongs.
        var newlineOffset: Int
        /// Where the caret ends up once that newline exists.
        var caretOffset: Int
    }

    /// The on-screen rect an image marker line occupies, anchored at its
    /// line fragment's origin. Shared between `draw(_:)` and the resize
    /// handlers so hit-testing always agrees with what was painted.
    static func imageRect(origin: CGPoint, fragment: CGRect, displaySize: CGSize) -> CGRect {
        CGRect(
            x: origin.x + fragment.minX,
            y: origin.y + fragment.minY,
            width: displaySize.width,
            height: displaySize.height
        )
    }

    /// The resize-drag hit target, anchored to an image rect's bottom-right
    /// corner. Shared between `draw(_:)` (visual) and the mouse/pan-gesture
    /// handlers (hit-testing) so they never disagree about where it is.
    static func handleRect(for imageRect: CGRect) -> CGRect {
        let size: CGFloat = 14
        return CGRect(
            x: imageRect.maxX - size - 4,
            y: imageRect.maxY - size - 4,
            width: size,
            height: size
        )
    }

    /// The ▲/▼ buttons shown while the caret is on an image's line, side by
    /// side inside its top-right corner — the opposite end from the resize
    /// handle. Shared between `draw(_:)` and the tap hit test like
    /// `handleRect`.
    static func moveButtonRects(for imageRect: CGRect) -> (up: CGRect, down: CGRect) {
        let size: CGFloat = 28
        let inset: CGFloat = 6
        let down = CGRect(
            x: imageRect.maxX - inset - size,
            y: imageRect.minY + inset,
            width: size,
            height: size
        )
        return (down.offsetBy(dx: -(size + inset), dy: 0), down)
    }
}

#if os(macOS)
@MainActor
private enum MacMarkdownEditorFocus {
    static let identifier = NSUserInterfaceItemIdentifier(
        "PilgrimJournal.MarkdownEditor"
    )

    static var isFocused: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.identifier
            == identifier
    }
}

private enum MarkdownSeparatorDecoration {
    private static let regex = try! NSRegularExpression(
        pattern: #"(?m)^(---|\*\*\*|___)$"#
    )

    static func ranges(in text: String) -> [NSRange] {
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: range).map(\.range)
    }
}

@MainActor
/// Keeps the text view exactly as wide as the visible area, so lines wrap at
/// the editor's edge.
///
/// The editor is magnified to apply the text-size setting, which makes the
/// visible width the frame width divided by the zoom. AppKit's autoresizing
/// only passes frame-size *changes* on to the text view, so after the first
/// sizing from zero, or after a zoom change, the text view kept a stale width:
/// wider than the visible area (text ran off the right edge and did not wrap
/// when the window shrank) or narrower (a gap on the right).
final class MarkdownEditorScrollView: NSScrollView {
    override var magnification: CGFloat {
        didSet { fitDocumentWidthToVisibleArea() }
    }

    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        super.setMagnification(magnification, centeredAt: point)
        fitDocumentWidthToVisibleArea()
    }

    override func tile() {
        super.tile()
        fitDocumentWidthToVisibleArea()
    }

    private func fitDocumentWidthToVisibleArea() {
        guard let documentView else { return }
        // While the text view was too wide, the clip view could scroll
        // sideways; there is nothing to the right once widths match.
        if abs(contentView.bounds.origin.x) > 0.5 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
        let visibleWidth = contentView.bounds.width
        guard visibleWidth > 0, abs(documentView.frame.width - visibleWidth) > 0.5 else { return }
        documentView.setFrameSize(NSSize(width: visibleWidth, height: documentView.frame.height))
        // The correction happens inside layout, after the old, wider lines
        // were drawn; without this the stale, clipped lines stay on screen.
        documentView.needsDisplay = true
    }
}

final class MarkdownNSTextView: NSTextView {
    /// Returns whether the direction was actually applied to a list line;
    /// `false` means the current line isn't a list item, so the caller
    /// should fall through to the normal Tab/Shift+Tab behavior.
    var adjustListIndentation: ((MarkdownListIndentDirection) -> Bool)?
    /// Returns whether a list marker was removed at the cursor; `false`
    /// means the caller should fall through to the normal single-character
    /// backspace.
    var removeListMarkerBeforeCursor: (() -> Bool)?
    /// Returns whether the pasteboard held an image and it was handled as an
    /// attachment insertion; `false` means the caller should fall through to
    /// the normal paste behavior (plain text, etc).
    var handleImagePaste: (() -> Bool)?
    /// Synchronous cache lookup — nil means not yet decoded, and as a side
    /// effect kicks off an async load (see `Coordinator.cachedAttachmentImage`).
    /// Never call anything async directly from `draw(_:)`.
    var attachmentImage: ((UUID) -> PlatformImage?)?
    /// Toggles the checklist item whose box is under the point; returns
    /// whether one was hit and the click therefore consumed.
    var toggleChecklistItem: ((NSPoint) -> Bool)?
    /// Moves the image under the caret if the point hits its ▲/▼; returns
    /// whether one was hit and the click therefore consumed.
    var moveAttachmentImage: ((NSPoint) -> Bool)?
    /// The size an image is being dragged to, while the drag is in progress.
    /// The marker text — and with it `storedWidth`/`storedHeight` — is only
    /// rewritten when the drag ends, so without this the reserved space
    /// resized live while the picture inside it stayed at its old size.
    var attachmentResizePreview: (id: UUID, size: CGSize)?
    /// Begins/continues/ends a resize drag if the point hits an image's
    /// resize handle; `begin` returns whether it was consumed.
    var beginAttachmentResize: ((NSPoint) -> Bool)?
    var continueAttachmentResize: ((NSPoint) -> Void)?
    var endAttachmentResize: ((NSPoint) -> Void)?
    private var isResizingAttachment = false
    /// Called when the text container's width changes meaningfully (window
    /// resize) so images sized as a fraction of it can be recomputed.
    var containerWidthChanged: ((CGFloat) -> Void)?
    private var lastKnownContainerWidth: CGFloat = 0

    /// Pins the width to the visible area so lines wrap at the editor's edge.
    ///
    /// SwiftUI hosts the editor with Auto Layout, and the layout engine sizes
    /// this view to the clip view's frame. With the text-size magnification
    /// the visible width is that frame divided by the zoom, so without this
    /// lines ran off the right edge (and the clip view scrolled sideways).
    /// Every resize path, the layout engine's included, ends here.
    override func setFrameSize(_ newSize: NSSize) {
        var size = newSize
        if let visibleWidth = enclosingScrollView?.contentView.bounds.width, visibleWidth > 0 {
            size.width = visibleWidth
        }
        super.setFrameSize(size)
    }

    override func layout() {
        super.layout()
        guard let width = textContainer?.size.width,
            abs(width - lastKnownContainerWidth) > 1
        else { return }
        lastKnownContainerWidth = width
        containerWidthChanged?(width)
    }

    override func paste(_ sender: Any?) {
        if handleImagePaste?() == true { return }
        super.paste(sender)
    }

    /// AppKit decides whether Edit ▸ Paste (and therefore ⌘V) is enabled
    /// *before* it would ever call `paste(_:)` above, by matching the
    /// pasteboard against `readablePasteboardTypes`. This view keeps
    /// `importsGraphics = false` on purpose — attachments live as markdown
    /// references, not as `NSTextAttachment`s in the text storage — so that
    /// list is text-only, and an image-only clipboard matches nothing:
    /// the menu item goes grey, ⌘V does nothing, and the image-paste
    /// override never runs. Enabling it here is what lets the override run.
    ///
    /// Only `paste:` is special-cased, and only to *enable* it; everything
    /// else falls through to `NSTextView`. `readablePasteboardTypes` is
    /// deliberately left alone so `super.paste(_:)` can never be handed an
    /// image type and insert a text attachment behind our back.
    override func validateUserInterfaceItem(
        _ item: NSValidatedUserInterfaceItem
    ) -> Bool {
        if item.action == #selector(paste(_:)),
            isEditable,
            Self.pasteboardHoldsImage(.general)
        {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Mirrors what `Coordinator.pasteboardImageData` will accept, but only
    /// inspects types and the file extension — menu validation runs on every
    /// menu open, so it must never read image bytes off disk.
    private static func pasteboardHoldsImage(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.data(forType: .png) != nil { return true }
        if pasteboard.data(forType: .tiff) != nil { return true }
        guard
            let url = pasteboard.readObjects(
                forClasses: [NSURL.self], options: nil
            )?.first as? URL
        else { return false }
        return UTType(filenameExtension: url.pathExtension)?
            .conforms(to: .image) ?? false
    }

    /// Guarantees typed text is never painted with a hidden marker's
    /// attributes. Both entry points matter: `setMarkedText` is where an IME
    /// composition (Korean) first shows up on screen, and `insertText` is
    /// where committed and non-IME input arrives.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        moveInsertionOffImageLine()
        restoreTypingAttributesIfHidden()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        moveInsertionOffImageLine()
        restoreTypingAttributesIfHidden()
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
    }

    /// Keeps an image line atomic by giving the keystroke a line of its own
    /// — see `MarkdownAttachmentImageDecoration.insertionRelocation`. A
    /// non-empty selection is left alone: replacing a selected image with
    /// typed text is a deliberate edit, not an accident.
    private func moveInsertionOffImageLine() {
        let selection = selectedRange()
        guard selection.length == 0,
            let relocation =
                MarkdownAttachmentImageDecoration
                .insertionRelocation(
                    in: string,
                    cursorUTF16Offset: selection.location
                )
        else { return }
        let insertionPoint = NSRange(
            location: relocation.newlineOffset, length: 0
        )
        setSelectedRange(insertionPoint)
        // `super`, not `self`: this must not recurse back through the guard.
        super.insertText("\n", replacementRange: insertionPoint)
        setSelectedRange(NSRange(location: relocation.caretOffset, length: 0))
    }

    /// Keeps typing attributes agreeing with the block the caret is in: the
    /// repair for inheriting a hidden marker's clear 0.1pt text, and the
    /// heading size a restyle would eventually apply anyway. Anything already
    /// correct is left untouched, so ordinary typing — IME composition above
    /// all — is never disturbed.
    private func restoreTypingAttributesIfHidden() {
        let desired = LiveMarkdownStyler.typingAttributes(
            forLinePrefix: MarkdownInputReconciliation.lineText(
                in: string, upTo: selectedRange().location
            )
        )
        let currentFont = typingAttributes[.font] as? NSFont
        let isHidden = MarkdownInputReconciliation.shouldRestoreTypingAttributes(
            fontPointSize: currentFont?.pointSize,
            foregroundAlpha: (typingAttributes[.foregroundColor] as? NSColor)?
                .usingColorSpace(.deviceRGB)?.alphaComponent
        )
        // Point size, not font equality: AppKit substitutes the concrete face
        // once Korean text is involved (system UI font → Apple SD Gothic Neo),
        // so comparing fonts would report a difference on every Korean
        // keystroke and rewrite the attributes needlessly mid-composition.
        let sizeDiffers =
            currentFont?.pointSize
            != (desired[.font] as? NSFont)?.pointSize
        guard isHidden || sizeDiffers else { return }
        typingAttributes = desired
    }

    override func insertTab(_ sender: Any?) {
        if adjustListIndentation?(.indent) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if adjustListIndentation?(.outdent) == true { return }
        super.insertBacktab(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if removeListMarkerBeforeCursor?() == true { return }
        super.deleteBackward(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        // Computed once per draw() call, not per match: lets every loop
        // below skip `lineFragmentRect`/`glyphRange`/`boundingRect` entirely
        // for matches outside the dirty rect, instead of paying for layout
        // on every match in the whole document on every keystroke.
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: dirtyRect, in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil
        )
        EditorPalette.separator.setStroke()
        for characterRange in MarkdownSeparatorDecoration.ranges(in: string) {
            guard NSIntersectionRange(characterRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else {
                continue
            }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let line = NSBezierPath()
            line.lineWidth = 1
            line.move(to: NSPoint(x: origin.x + 4, y: origin.y + fragment.midY))
            line.line(
                to: NSPoint(
                    x: origin.x + textContainer.size.width - 4,
                    y: origin.y + fragment.midY
                ))
            line.stroke()
        }
        for bulletMatch in MarkdownBulletDecoration.matches(in: string) {
            guard NSIntersectionRange(bulletMatch.markerRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: bulletMatch.markerRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else {
                continue
            }
            let marker = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            // Center on the marker glyph's own bounding box, not the line
            // fragment rect — the fragment includes the paragraph's line
            // spacing, which sits below the glyph, so using its midY pulls
            // the dot down off-center from the text.
            let dot = NSRect(
                x: origin.x + marker.midX - 3,
                y: origin.y + marker.midY - 3,
                width: 6,
                height: 6
            )
            if bulletMatch.indentationLevel == 0 {
                EditorPalette.label.setFill()
                NSBezierPath(ovalIn: dot).fill()
            } else {
                let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.2
                EditorPalette.label.setStroke()
                ring.stroke()
            }
        }
        for checklistMatch in MarkdownChecklistDecoration.matches(in: string) {
            guard NSIntersectionRange(checklistMatch.markerRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: checklistMatch.markerRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else {
                continue
            }
            let marker = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let rect = MarkdownChecklistDecoration.boxRect(
                origin: origin, markerBounds: marker
            )
            if checklistMatch.checked {
                EditorPalette.label.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                let check = NSBezierPath()
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(
                    to: NSPoint(
                        x: rect.minX + rect.width * 0.22,
                        y: rect.minY + rect.height * 0.52
                    ))
                check.line(
                    to: NSPoint(
                        x: rect.minX + rect.width * 0.42,
                        y: rect.minY + rect.height * 0.72
                    ))
                check.line(
                    to: NSPoint(
                        x: rect.minX + rect.width * 0.80,
                        y: rect.minY + rect.height * 0.28
                    ))
                // The box fill is EditorPalette.label (adapts light/dark),
                // so the checkmark needs the opposite of whatever that
                // resolved to, not a fixed color.
                let isDark =
                    effectiveAppearance.bestMatch(
                        from: [.darkAqua, .aqua]
                    ) == .darkAqua
                (isDark ? PlatformColor.black : PlatformColor.white).setStroke()
                check.stroke()
            } else {
                let outline = NSBezierPath(
                    roundedRect: rect.insetBy(dx: 0.75, dy: 0.75),
                    xRadius: 4,
                    yRadius: 4
                )
                outline.lineWidth = 1.5
                EditorPalette.secondaryLabel.setStroke()
                outline.stroke()
            }
        }
        let cursorLocation = selectedRange().location
        for imageMatch in MarkdownAttachmentImageDecoration.matches(in: string) {
            guard NSIntersectionRange(imageMatch.markerRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: imageMatch.markerRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let displaySize =
                attachmentResizePreview
                .flatMap { $0.id == imageMatch.attachmentID ? $0.size : nil }
                ?? LiveMarkdownStyler.attachmentImageDisplaySize(
                    storedWidth: imageMatch.storedWidth,
                    storedHeight: imageMatch.storedHeight,
                    containerWidth: textContainer.size.width
                )
            let imageRect = MarkdownAttachmentImageDecoration.imageRect(
                origin: origin, fragment: fragment, displaySize: displaySize
            )
            guard dirtyRect.intersects(imageRect) else { continue }
            if let image = attachmentImage?(imageMatch.attachmentID) {
                // NSImage's high-level draw(in:from:operation:fraction:) can
                // render upside down in a flipped, layer-backed NSTextView
                // (a known AppKit quirk — the ambient flip the text view
                // sets up and NSImage's own flip-awareness fight each
                // other). Drawing the CGImage directly with an explicit
                // counter-flip around the target rect sidesteps that
                // ambiguity entirely instead of depending on it.
                if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                    let context = NSGraphicsContext.current?.cgContext
                {
                    context.saveGState()
                    context.translateBy(x: 0, y: imageRect.minY + imageRect.maxY)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(cgImage, in: imageRect)
                    context.restoreGState()
                } else {
                    image.draw(
                        in: imageRect, from: .zero, operation: .sourceOver, fraction: 1
                    )
                }
            } else {
                EditorPalette.codeBackground.setFill()
                NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).fill()
                EditorPalette.secondaryLabel.setStroke()
                NSBezierPath(
                    roundedRect: imageRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6
                ).stroke()
            }
            let lineRange = (string as NSString).lineRange(for: imageMatch.markerRange)
            let cursorOnThisLine =
                cursorLocation >= lineRange.location
                && cursorLocation <= NSMaxRange(lineRange)
            if cursorOnThisLine {
                let handle = MarkdownAttachmentImageDecoration.handleRect(for: imageRect)
                let path = NSBezierPath(ovalIn: handle)
                EditorPalette.label.setFill()
                path.fill()
                (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? PlatformColor.black : PlatformColor.white).setStroke()
                path.lineWidth = 1.5
                path.stroke()
                drawMoveButtons(for: imageMatch, in: imageRect)
            }
        }
    }

    /// See the iOS view: ▲/▼ only where the image can actually go, and the
    /// click test (`Coordinator.attachmentMoveTarget`) asks the same question.
    private func drawMoveButtons(
        for imageMatch: MarkdownAttachmentImageDecoration.Match,
        in imageRect: CGRect
    ) {
        let buttons = MarkdownAttachmentImageDecoration.moveButtonRects(for: imageRect)
        let glyphColor =
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? PlatformColor.black : PlatformColor.white
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [glyphColor]))
        for (rect, direction, symbol) in [
            (buttons.up, MarkdownImageMoveDirection.up, "chevron.up"),
            (buttons.down, MarkdownImageMoveDirection.down, "chevron.down"),
        ] {
            guard
                MarkdownCommandProcessor.movingAttachmentImage(
                    at: imageMatch.markerRange.location, direction: direction, in: string
                ) != nil
            else { continue }
            EditorPalette.label.withAlphaComponent(0.75).setFill()
            NSBezierPath(ovalIn: rect).fill()
            guard
                let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            else { continue }
            let size = glyph.size
            glyph.draw(
                in: CGRect(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Before `super`, which would move the caret off the image and so
        // take its buttons away.
        if moveAttachmentImage?(point) == true { return }
        if beginAttachmentResize?(point) == true {
            isResizingAttachment = true
            return
        }
        // Before `super`, which would place the caret instead: a click on the
        // box toggles the item and leaves the text alone otherwise.
        if toggleChecklistItem?(point) == true { return }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizingAttachment else {
            super.mouseDragged(with: event)
            return
        }
        continueAttachmentResize?(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isResizingAttachment else {
            super.mouseUp(with: event)
            return
        }
        isResizingAttachment = false
        endAttachmentResize?(convert(event.locationInWindow, from: nil))
    }
}

struct LiveMarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var autoFocus: Bool
    var textScale: Double
    var storeImageAttachment: ((Data, String, String) async -> UUID?)?
    var attachmentImage: ((UUID) async -> Data?)?
    var attachmentRevision = 0
    /// Only the iOS editor needs this. Here the `NSScrollView` already fills
    /// the whole `minHeight` frame and its text view starts at the top.
    var minimumHeight: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// The scroll view and text view with every setting that affects layout,
    /// so tests exercise exactly what the editor runs.
    static func makeEditorViews(
        textScale: Double
    ) -> (MarkdownEditorScrollView, MarkdownNSTextView) {
        let scrollView = MarkdownEditorScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = EditorTextScale.minimum
        scrollView.maxMagnification = EditorTextScale.maximum
        scrollView.magnification = CGFloat(textScale)

        let textView = MarkdownNSTextView()
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return (scrollView, textView)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = Self.makeEditorViews(textScale: textScale)
        textView.identifier = MacMarkdownEditorFocus.identifier
        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.adjustListIndentation = { [weak coordinator = context.coordinator] direction in
            coordinator?.adjustListIndentation(direction) ?? false
        }
        textView.removeListMarkerBeforeCursor = { [weak coordinator = context.coordinator] in
            coordinator?.removeListMarkerBeforeCursor() ?? false
        }
        textView.handleImagePaste = { [weak coordinator = context.coordinator] in
            coordinator?.handleImagePaste() ?? false
        }
        textView.attachmentImage = { [weak coordinator = context.coordinator] id in
            coordinator?.cachedAttachmentImage(for: id)
        }
        textView.toggleChecklistItem = { [weak coordinator = context.coordinator] point in
            coordinator?.toggleChecklistItem(at: point) ?? false
        }
        textView.moveAttachmentImage = { [weak coordinator = context.coordinator] point in
            coordinator?.moveAttachmentImage(at: point) ?? false
        }
        textView.beginAttachmentResize = { [weak coordinator = context.coordinator] point in
            coordinator?.beginAttachmentResize(at: point) ?? false
        }
        textView.continueAttachmentResize = { [weak coordinator = context.coordinator] point in
            coordinator?.continueAttachmentResize(to: point)
        }
        textView.endAttachmentResize = { [weak coordinator = context.coordinator] point in
            coordinator?.endAttachmentResize(at: point)
        }
        textView.containerWidthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.recomputeAttachmentImageSizes(containerWidth: width)
        }
        textView.string = text
        if let storage = textView.textStorage {
            LiveMarkdownStyler.apply(
                to: storage,
                revealing: selection,
                containerWidth: textView.textContainer?.size.width ?? 600
            )
        }
        textView.typingAttributes = LiveMarkdownStyler.baseAttributes

        if autoFocus {
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachmentRevisionDidChange(to: attachmentRevision)
        guard let textView = scrollView.documentView as? NSTextView,
            !context.coordinator.isUpdating
        else { return }
        if abs(scrollView.magnification - CGFloat(textScale)) > 0.001 {
            scrollView.setMagnification(CGFloat(textScale), centeredAt: .zero)
        }
        guard
            MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.hasMarkedText()
            )
        else {
            context.coordinator.deferExternalText(text)
            return
        }
        if context.coordinator.applyDeferredExternalText(latest: text) { return }
        if MarkdownInputReconciliation.shouldApplyExternalText(
            incoming: text,
            current: textView.string,
            publishedHistory: context.coordinator.publishedHistory
        ) {
            context.coordinator.replaceExternalText(
                text,
                selection: selection,
                registersUndo: true
            )
            return
        }
        guard textView.string == text else { return }
        let safeSelection = clamped(selection, to: textView.string.utf16.count)
        if textView.selectedRange() != safeSelection {
            textView.setSelectedRange(safeSelection)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LiveMarkdownTextEditor
        var isUpdating = false
        weak var textView: NSTextView?
        private(set) var publishedHistory: [Int] = []
        private var stylingTask: Task<Void, Never>?
        private var imageCache: [UUID: PlatformImage] = [:]
        private var loadingAttachmentIDs: Set<UUID> = []
        /// Attachments whose data wasn't available (not yet downloaded from
        /// CloudKit, or undecodable) on the last attempt. Without this,
        /// `cachedAttachmentImage` re-queries the store on *every* redraw —
        /// including every keystroke — for as long as the attachment stays
        /// unavailable, which is indistinguishable from a permanent typing
        /// stall. Cleared on `attachmentRevisionChanged` so a completed
        /// download is picked up without needing to reopen the entry.
        private var missingAttachmentIDs: Set<UUID> = []
        private var lastSeenAttachmentRevision: Int?
        private var resizingAttachmentID: UUID?
        private var resizeStartPoint: NSPoint = .zero
        private var resizeStartSize: CGSize = .zero

        func attachmentRevisionDidChange(to revision: Int) {
            guard lastSeenAttachmentRevision != revision else { return }
            lastSeenAttachmentRevision = revision
            guard !missingAttachmentIDs.isEmpty else { return }
            missingAttachmentIDs.removeAll()
            textView?.setNeedsDisplay(textView?.bounds ?? .zero)
        }

        /// Every write to the binding must go through here so the editor can
        /// recognise its own value when SwiftUI echoes it back a render later.
        func publish(_ newText: String) {
            MarkdownInputReconciliation.recordPublishedText(
                newText,
                in: &publishedHistory
            )
            parent.text = newText
        }

        /// An external text (an entry reload) that arrived while the IME was
        /// composing, and the editor text it was meant to replace. Held until
        /// the composition ends — see `ExternalTextRebase`.
        private var deferredExternalText: (base: String, incoming: String)?

        /// Called instead of applying external text while text is marked.
        /// Echoes of the editor's own values are ignored as usual.
        func deferExternalText(_ incoming: String) {
            guard let textView,
                MarkdownInputReconciliation.shouldApplyExternalText(
                    incoming: incoming,
                    current: textView.string,
                    publishedHistory: publishedHistory
                )
            else { return }
            deferredExternalText = (deferredExternalText?.base ?? textView.string, incoming)
        }

        /// Once composition has ended, applies a deferred external text with
        /// the composed characters carried over. Returns false when nothing
        /// was deferred. `latest` is a newer binding value, if any.
        @discardableResult
        func applyDeferredExternalText(latest: String? = nil) -> Bool {
            guard let textView, var deferred = deferredExternalText else { return false }
            deferredExternalText = nil
            if let latest,
                MarkdownInputReconciliation.shouldApplyExternalText(
                    incoming: latest,
                    current: textView.string,
                    publishedHistory: publishedHistory
                )
            {
                deferred.incoming = latest
            }
            let rebased = ExternalTextRebase.rebase(
                local: textView.string,
                base: deferred.base,
                incoming: deferred.incoming,
                localCursorUTF16Offset: NSMaxRange(textView.selectedRange())
            )
            if rebased.text == textView.string {
                publish(rebased.text)
            } else {
                replaceExternalText(
                    rebased.text,
                    selection: NSRange(location: rebased.cursorUTF16Offset, length: 0),
                    registersUndo: true
                )
            }
            return true
        }

        init(parent: LiveMarkdownTextEditor) {
            self.parent = parent
        }

        /// Synchronous — returns the cached decoded image if present, and as
        /// a side effect starts (at most one) async load per attachment.
        /// Never call `parent.attachmentImage` (async) directly from
        /// `draw(_:)`; this is the only sanctioned entry point.
        fileprivate func cachedAttachmentImage(for id: UUID) -> PlatformImage? {
            if let image = imageCache[id] { return image }
            // Second synchronous check, still zero-cost: the shared cache
            // may already have this image decoded from a previous entry
            // (this Coordinator's own `imageCache` is thrown away whenever
            // the editor is recreated, e.g. switching entries).
            if let shared = AttachmentImageCache.shared.cachedImage(id: id) {
                imageCache[id] = shared
                return shared
            }
            guard !loadingAttachmentIDs.contains(id), !missingAttachmentIDs.contains(id),
                let provider = parent.attachmentImage
            else { return nil }
            loadingAttachmentIDs.insert(id)
            Task { @MainActor [weak self] in
                defer { self?.loadingAttachmentIDs.remove(id) }
                // Decodes downsampled (never at the source's full
                // resolution) — see AttachmentImageCache's doc comment.
                guard let self, let data = await provider(id),
                    let image = await AttachmentImageCache.shared.loadAndCache(
                        id: id, data: data
                    )
                else {
                    self?.missingAttachmentIDs.insert(id)
                    return
                }
                self.imageCache[id] = image
                self.textView?.setNeedsDisplay(self.textView?.bounds ?? .zero)
            }
            return nil
        }

        /// Toggling is a text edit rather than a display-only flag, so it
        /// registers undo, autosaves and syncs like anything else the user
        /// types. The caret is left where it was — clicking a box is not a
        /// request to move the insertion point.
        func toggleChecklistItem(at point: NSPoint) -> Bool {
            guard let textView, let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return false }
            let origin = textView.textContainerOrigin
            for match in MarkdownChecklistDecoration.matches(in: textView.string) {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: match.markerRange, actualCharacterRange: nil
                )
                guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
                let marker = layoutManager.boundingRect(
                    forGlyphRange: glyphRange, in: textContainer
                )
                let box = MarkdownChecklistDecoration.boxRect(
                    origin: origin, markerBounds: marker
                )
                guard box.contains(point) else { continue }
                // One character, edited in place. Rewriting the whole string
                // and restyling the whole document — what `replaceExternalText`
                // does — is far too much work for flipping a checkbox, and the
                // delay was plainly visible on a long entry. Nothing else about
                // the document changes, so nothing else needs recomputing.
                let replacement = match.toggledState
                guard
                    textView.shouldChangeText(
                        in: match.stateRange, replacementString: replacement
                    )
                else { return true }
                textView.textStorage?.replaceCharacters(
                    in: match.stateRange, with: replacement
                )
                // Registers undo and notifies the delegate, which publishes
                // the new text so it autosaves and syncs as usual.
                textView.didChangeText()
                textView.setNeedsDisplay(box)
                return true
            }
            return false
        }

        func beginAttachmentResize(at point: NSPoint) -> Bool {
            guard let textView, let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return false }
            let origin = textView.textContainerOrigin
            for match in MarkdownAttachmentImageDecoration.matches(in: textView.string) {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: match.markerRange, actualCharacterRange: nil
                )
                guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
                let fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location, effectiveRange: nil
                )
                let displaySize = LiveMarkdownStyler.attachmentImageDisplaySize(
                    storedWidth: match.storedWidth,
                    storedHeight: match.storedHeight,
                    containerWidth: textContainer.size.width
                )
                let imageRect = MarkdownAttachmentImageDecoration.imageRect(
                    origin: origin, fragment: fragment, displaySize: displaySize
                )
                let handle = MarkdownAttachmentImageDecoration.handleRect(for: imageRect)
                guard handle.contains(point) else { continue }
                resizingAttachmentID = match.attachmentID
                resizeStartPoint = point
                resizeStartSize = displaySize
                return true
            }
            return false
        }

        /// Live-drags the image's paragraph style height only — never runs a
        /// full restyle mid-drag. Attribute-only edits like this don't
        /// trigger `textDidChange` (see docs/known-issues.md), so there's no
        /// reentrancy risk running this on every mouse-moved event.
        func continueAttachmentResize(to point: NSPoint) {
            guard let id = resizingAttachmentID, let textView,
                let storage = textView.textStorage,
                let textContainer = textView.textContainer
            else { return }
            let size = draggedSize(to: point, containerWidth: textContainer.size.width)
            guard
                let match = MarkdownAttachmentImageDecoration.matches(in: textView.string)
                    .first(where: { $0.attachmentID == id })
            else { return }
            let style = LiveMarkdownStyler.attachmentImageParagraphStyle(
                storedWidth: size.width, storedHeight: size.height,
                containerWidth: textContainer.size.width
            )
            storage.addAttribute(.paragraphStyle, value: style, range: match.markerRange)
            // Scales the drawn picture with the space being reserved for it;
            // the marker text only catches up when the drag ends.
            (textView as? MarkdownNSTextView)?.attachmentResizePreview = (id, size)
            textView.setNeedsDisplay(textView.bounds)
        }

        /// Recomputes every image's reserved height for a new container
        /// width (window resize) without a full restyle pass. Attribute-only
        /// edits like this never trigger `textDidChange` (see
        /// docs/known-issues.md), so this is safe to call from `layout()`.
        func recomputeAttachmentImageSizes(containerWidth: CGFloat) {
            guard let textView, let storage = textView.textStorage else { return }
            for match in MarkdownAttachmentImageDecoration.matches(in: textView.string) {
                let style = LiveMarkdownStyler.attachmentImageParagraphStyle(
                    storedWidth: match.storedWidth, storedHeight: match.storedHeight,
                    containerWidth: containerWidth
                )
                storage.addAttribute(.paragraphStyle, value: style, range: match.markerRange)
            }
            textView.setNeedsDisplay(textView.bounds)
        }

        func endAttachmentResize(at point: NSPoint) {
            defer {
                resizingAttachmentID = nil
                (textView as? MarkdownNSTextView)?.attachmentResizePreview = nil
            }
            guard let id = resizingAttachmentID, let textView,
                let textContainer = textView.textContainer
            else { return }
            let size = draggedSize(to: point, containerWidth: textContainer.size.width)
            guard
                let match = MarkdownAttachmentImageDecoration.matches(in: textView.string)
                    .first(where: { $0.attachmentID == id })
            else { return }
            let replaced = (textView.string as NSString).replacingCharacters(
                in: match.markerRange,
                with:
                    "![](attachment:\(id.uuidString) =\(Int(size.width.rounded()))x\(Int(size.height.rounded())))"
            )
            let cursor = NSRange(location: match.markerRange.location, length: 0)
            replaceExternalText(replaced, selection: cursor, registersUndo: true)
        }

        /// Aspect-locked: only the horizontal drag distance drives the
        /// resize, height follows the original aspect ratio.
        private func draggedSize(to point: NSPoint, containerWidth: CGFloat) -> CGSize {
            let aspect = resizeStartSize.height / max(resizeStartSize.width, 1)
            let width = max(
                40, min(containerWidth, resizeStartSize.width + (point.x - resizeStartPoint.x)))
            return CGSize(width: width, height: width * aspect)
        }

        /// See the iOS coordinator: which ▲/▼ button is under `point`, for
        /// the image whose line holds the caret and only in a direction it
        /// can move — the same test `draw(_:)` uses, so a button that isn't
        /// drawn never takes a click.
        func attachmentMoveTarget(
            at point: NSPoint
        ) -> (markerOffset: Int, direction: MarkdownImageMoveDirection)? {
            guard let textView, let layoutManager = textView.layoutManager,
                let textContainer = textView.textContainer
            else { return nil }
            let text = textView.string
            let caret = textView.selectedRange().location
            let origin = textView.textContainerOrigin
            for match in MarkdownAttachmentImageDecoration.matches(in: text) {
                let lineRange = (text as NSString).lineRange(for: match.markerRange)
                guard caret >= lineRange.location, caret <= NSMaxRange(lineRange) else {
                    continue
                }
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: match.markerRange, actualCharacterRange: nil
                )
                guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
                let fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location, effectiveRange: nil
                )
                let imageRect = MarkdownAttachmentImageDecoration.imageRect(
                    origin: origin,
                    fragment: fragment,
                    displaySize: LiveMarkdownStyler.attachmentImageDisplaySize(
                        storedWidth: match.storedWidth,
                        storedHeight: match.storedHeight,
                        containerWidth: textContainer.size.width
                    )
                )
                let buttons = MarkdownAttachmentImageDecoration.moveButtonRects(for: imageRect)
                for (rect, direction) in [(buttons.up, .up), (buttons.down, .down)]
                    as [(CGRect, MarkdownImageMoveDirection)]
                {
                    guard rect.insetBy(dx: -2, dy: -2).contains(point),
                        MarkdownCommandProcessor.movingAttachmentImage(
                            at: match.markerRange.location, direction: direction, in: text
                        ) != nil
                    else { continue }
                    return (match.markerRange.location, direction)
                }
            }
            return nil
        }

        /// An ordinary text edit, so it undoes, autosaves and syncs like any
        /// other.
        func moveAttachmentImage(at point: NSPoint) -> Bool {
            guard let textView, !textView.hasMarkedText(),
                let target = attachmentMoveTarget(at: point),
                let result = MarkdownCommandProcessor.movingAttachmentImage(
                    at: target.markerOffset, direction: target.direction, in: textView.string
                )
            else { return false }
            replaceExternalText(
                result.text,
                selection: NSRange(location: result.cursorUTF16Offset, length: 0),
                registersUndo: true
            )
            return true
        }

        func replaceExternalText(
            _ replacement: String,
            selection replacementSelection: NSRange,
            registersUndo: Bool
        ) {
            guard let textView, textView.string != replacement else { return }
            stylingTask?.cancel()
            let previousText = textView.string
            let previousSelection = textView.selectedRange()
            if registersUndo, let undoManager = textView.undoManager {
                undoManager.registerUndo(withTarget: self) { target in
                    target.replaceExternalText(
                        previousText,
                        selection: previousSelection,
                        registersUndo: true
                    )
                }
                undoManager.setActionName(String(localized: "Markdown 서식"))
            }
            isUpdating = true
            textView.string = replacement
            let safeSelection = clamped(
                replacementSelection,
                to: replacement.utf16.count
            )
            if let storage = textView.textStorage {
                LiveMarkdownStyler.apply(
                    to: storage,
                    revealing: safeSelection,
                    containerWidth: textView.textContainer?.size.width ?? 600
                )
            }
            // Order matters: AppKit re-derives `typingAttributes` from the
            // character before the caret whenever the selection moves, so
            // resetting them *before* `setSelectedRange` would be undone
            // immediately. A caret landing after a hidden marker — `# ` from
            // a slash command, an image line — would then type clear 0.1pt
            // text. The caret-move guard in `textViewDidChangeSelection`
            // can't cover this either: `isUpdating` is true right here.
            textView.setSelectedRange(safeSelection)
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.scrollRangeToVisible(safeSelection)
            publish(replacement)
            parent.selection = safeSelection
            isUpdating = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating,
                let textView = notification.object as? NSTextView
            else {
                return
            }
            let currentSelection = textView.selectedRange()
            if !MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.hasMarkedText()
            ) {
                // A deferred reload owns the binding until composition ends;
                // publishing the pre-reload text here would autosave it over
                // the reload.
                if deferredExternalText == nil { publish(textView.string) }
                parent.selection = currentSelection
                return
            }
            if applyDeferredExternalText() { return }
            isUpdating = true
            let expanded = MarkdownCommandProcessor.expandCommand(
                in: textView.string,
                cursorUTF16Offset: NSMaxRange(currentSelection)
            )
            let continued = MarkdownCommandProcessor.continuingBullet(
                in: expanded.text,
                cursorUTF16Offset: expanded.cursorUTF16Offset
            )
            let transformedText = continued.text != textView.string
            if transformedText {
                stylingTask?.cancel()
                textView.string = continued.text
                let cursor = NSRange(
                    location: continued.cursorUTF16Offset,
                    length: 0
                )
                textView.setSelectedRange(cursor)
                textView.scrollRangeToVisible(cursor)
            }
            publish(continued.text)
            let preservedSelection = textView.selectedRange()
            parent.selection = preservedSelection
            // Full-document restyling is expensive (many regex passes over
            // the whole string) and was previously run synchronously on
            // every keystroke, which under rapid typing (e.g. holding
            // Return) could visibly stall/jank the scroll position. Commands
            // and syntax delimiters style immediately; other committed edits
            // always schedule a deferred pass, including deletion.
            if transformedText
                || MarkdownInputReconciliation.shouldStyleImmediately(
                    after: textView.string,
                    cursorUTF16Offset: NSMaxRange(preservedSelection)
                )
            {
                // Apply syntax on the completing keystroke, without requiring
                // an extra space or Return to make the formatting visible.
                stylingTask?.cancel()
                applyStyling(to: textView)
            } else {
                scheduleStyling(for: textView)
            }
            // Keep the caret in view on every change, not just list
            // continuation — otherwise newly typed lines near the bottom
            // edge can be left scrolled out of view.
            textView.scrollRangeToVisible(preservedSelection)
            isUpdating = false
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                !textView.hasMarkedText(), !isUpdating
            else { return }
            stylingTask?.cancel()
            isUpdating = true
            applyStyling(to: textView)
            isUpdating = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating,
                let textView = notification.object as? NSTextView
            else {
                return
            }
            let selection = textView.selectedRange()
            if !MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.hasMarkedText()
            ) {
                parent.selection = selection
                return
            }
            parent.selection = selection
            // Every visible style in this editor is derived by `apply` from
            // the text itself, so typing attributes must always be the plain
            // base — but AppKit resets them to the attributes of whatever
            // character precedes the caret. Hidden markers are drawn as clear
            // 0.1pt text (the image line is hidden *in its entirety*), so a
            // caret landing right after one makes the next keystrokes
            // invisible until the next styling pass. Restore before typing.
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.needsDisplay = true
        }

        @discardableResult
        func adjustListIndentation(_ direction: MarkdownListIndentDirection) -> Bool {
            guard let textView, !textView.hasMarkedText() else { return false }
            let result = MarkdownCommandProcessor.adjustingListIndentation(
                in: textView.string,
                selection: textView.selectedRange(),
                direction: direction
            )
            guard result.text != textView.string else { return false }
            replaceExternalText(
                result.text,
                selection: result.selectionUTF16Range
                    ?? NSRange(
                        location: result.cursorUTF16Offset,
                        length: 0
                    ),
                registersUndo: true
            )
            return true
        }

        @discardableResult
        func removeListMarkerBeforeCursor() -> Bool {
            guard let textView, !textView.hasMarkedText() else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0,
                let result = MarkdownCommandProcessor.removingListMarkerBeforeCursor(
                    in: textView.string,
                    cursorUTF16Offset: selection.location
                )
            else { return false }
            replaceExternalText(
                result.text,
                selection: result.selectionUTF16Range
                    ?? NSRange(
                        location: result.cursorUTF16Offset,
                        length: 0
                    ),
                registersUndo: true
            )
            return true
        }

        /// Returns false (letting `paste(_:)` fall through to the default
        /// behavior) whenever the pasteboard has no image or there's no
        /// entry to attach to yet — non-image paste (plain text, etc) is
        /// completely unaffected. Storage (hashing + disk write) is
        /// off-main-actor and can take a moment for a large image, so once
        /// this returns `true` the actual insertion happens asynchronously;
        /// the cursor position is captured now, not when storage finishes.
        @discardableResult
        func handleImagePaste() -> Bool {
            guard let textView, !textView.hasMarkedText() else { return false }
            guard let image = Self.pasteboardImageData(from: .general) else { return false }
            let selection = textView.selectedRange()
            Task { @MainActor [weak self] in
                guard let self,
                    let attachmentID = await self.parent.storeImageAttachment?(
                        image.data,
                        image.filename,
                        image.mimeType
                    ), let textView = self.textView
                else { return }
                let displaySize = NSImage(data: image.data).map {
                    LiveMarkdownStyler.attachmentImageDisplaySize(
                        storedWidth: $0.size.width,
                        storedHeight: $0.size.height,
                        containerWidth: textView.textContainer?.size.width ?? 600
                    )
                }
                let result = MarkdownCommandProcessor.insertingAttachmentImage(
                    id: attachmentID,
                    displaySize: displaySize,
                    into: textView.string,
                    selection: selection
                )
                self.replaceExternalText(
                    result.text,
                    selection: NSRange(location: result.cursorUTF16Offset, length: 0),
                    registersUndo: true
                )
            }
            return true
        }

        private static func pasteboardImageData(
            from pasteboard: NSPasteboard
        ) -> (data: Data, filename: String, mimeType: String)? {
            if let data = pasteboard.data(forType: .png) {
                return (data, "pasted.png", "image/png")
            }
            if let tiffData = pasteboard.data(forType: .tiff),
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:])
            {
                return (pngData, "pasted.png", "image/png")
            }
            // Copying a file (Finder "복사", or a browser's "이미지 복사" that
            // hands over a file reference instead of raw bytes) puts a file
            // URL on the pasteboard rather than `.png`/`.tiff` data — the two
            // checks above both miss it silently. Other apps (Notes, Day
            // One) resolve this case; without it, pasting a copied image
            // *file* here looked like paste wasn't working at all.
            if let url = pasteboard.readObjects(
                forClasses: [NSURL.self], options: nil
            )?.first as? URL,
                let contentType = UTType(filenameExtension: url.pathExtension),
                contentType.conforms(to: .image),
                let data = try? Data(contentsOf: url)
            {
                return (
                    data, url.lastPathComponent,
                    contentType.preferredMIMEType ?? "application/octet-stream"
                )
            }
            return nil
        }

        private func scheduleStyling(for textView: NSTextView) {
            stylingTask?.cancel()
            stylingTask = Task { @MainActor [weak self, weak textView] in
                do {
                    try await Task.sleep(for: EditorTiming.stylingDebounce)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                    let self,
                    let textView,
                    !textView.hasMarkedText(),
                    !self.isUpdating
                else { return }
                self.isUpdating = true
                self.applyStyling(to: textView)
                self.isUpdating = false
            }
        }

        private func applyStyling(to textView: NSTextView) {
            let selection = textView.selectedRange()
            if let storage = textView.textStorage {
                LiveMarkdownStyler.apply(
                    to: storage,
                    revealing: selection,
                    containerWidth: textView.textContainer?.size.width ?? 600
                )
            }
            let safeSelection = clamped(selection, to: textView.string.utf16.count)
            // Must follow the caret move — see `replaceExternalText`.
            textView.setSelectedRange(safeSelection)
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
        }
    }
}
#elseif os(iOS)
private enum MarkdownSeparatorDecoration {
    private static let regex = try! NSRegularExpression(
        pattern: #"(?m)^(---|\*\*\*|___)$"#
    )

    static func ranges(in text: String) -> [NSRange] {
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: range).map(\.range)
    }
}

@MainActor
private final class MarkdownUITextView: UITextView, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        let point = touch.location(in: self)
        if gestureRecognizer === checklistTapGesture {
            return isPointOnChecklistBox?(point) ?? false
        }
        if gestureRecognizer === attachmentMoveTapGesture {
            return isPointOnAttachmentMoveButton?(point) ?? false
        }
        return isPointOnAttachmentResizeHandle?(point) ?? false
    }

    var adjustListIndentation: ((MarkdownListIndentDirection) -> Void)?
    /// Returns whether a list marker was removed at the cursor; `false`
    /// means the caller should fall through to the normal single-character
    /// backspace.
    var removeListMarkerBeforeCursor: (() -> Bool)?
    /// Returns whether the pasteboard held an image and it was handled as an
    /// attachment insertion; `false` means the caller should fall through to
    /// the normal paste behavior (plain text, etc).
    var handleImagePaste: (() -> Bool)?
    /// Synchronous cache lookup — nil means not yet decoded, and as a side
    /// effect kicks off an async load (see `Coordinator.cachedAttachmentImage`).
    /// Never call anything async directly from `draw(_:)`.
    var attachmentImage: ((UUID) -> PlatformImage?)?
    /// The size an image is being dragged to, while the drag is in progress
    /// — see the macOS view for why the marker text can't supply it yet.
    var attachmentResizePreview: (id: UUID, size: CGSize)?
    /// Pure hit test used by the pan gesture's delegate to decide whether to
    /// even claim the touch — must not mutate state (see `shouldReceive`).
    var isPointOnAttachmentResizeHandle: ((CGPoint) -> Bool)?
    /// The same split for the checklist tap: a pure hit test that decides
    /// whether the tap is ours at all, then the toggle itself.
    var isPointOnChecklistBox: ((CGPoint) -> Bool)?
    var toggleChecklistItem: ((CGPoint) -> Bool)?
    private weak var checklistTapGesture: UITapGestureRecognizer?
    /// The same split for the ▲/▼ buttons on the image under the caret.
    var isPointOnAttachmentMoveButton: ((CGPoint) -> Bool)?
    var moveAttachmentImage: ((CGPoint) -> Bool)?
    private weak var attachmentMoveTapGesture: UITapGestureRecognizer?
    var beginAttachmentResize: ((CGPoint) -> Bool)?
    var continueAttachmentResize: ((CGPoint) -> Void)?
    var endAttachmentResize: ((CGPoint) -> Void)?
    /// Called when the text container's width changes meaningfully (device
    /// rotation, split-view resize) so images sized as a fraction of it can
    /// be recomputed.
    var containerWidthChanged: ((CGFloat) -> Void)?
    private var lastKnownContainerWidth: CGFloat = 0

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configureAttachmentResizeGesture()
        configureChecklistTapGesture()
        configureAttachmentMoveTapGesture()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAttachmentResizeGesture()
        configureChecklistTapGesture()
        configureAttachmentMoveTapGesture()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = textContainer.size.width
        guard abs(width - lastKnownContainerWidth) > 1 else { return }
        lastKnownContainerWidth = width
        containerWidthChanged?(width)
    }

    // Deliberately NOT overriding touchesBegan/touchesMoved: UITextView's
    // own text selection/loupe/drag gestures are built from private
    // gesture-recognizer internals that are easy to break by intercepting
    // touches directly. A separate UIPanGestureRecognizer + delegate
    // hit-test keeps this fully decoupled from UITextView's own handling.
    private func configureAttachmentResizeGesture() {
        let gesture = UIPanGestureRecognizer(
            target: self, action: #selector(handleAttachmentResizePan(_:))
        )
        gesture.delegate = self
        addGestureRecognizer(gesture)
    }

    /// Same decoupling as the resize pan: the delegate's hit test means this
    /// recognizer only ever receives touches that land on a checkbox, so
    /// UITextView's own selection handling is untouched everywhere else.
    private func configureChecklistTapGesture() {
        let gesture = UITapGestureRecognizer(
            target: self, action: #selector(handleChecklistTap(_:))
        )
        gesture.delegate = self
        addGestureRecognizer(gesture)
        checklistTapGesture = gesture
    }

    @objc private func handleChecklistTap(_ gesture: UITapGestureRecognizer) {
        _ = toggleChecklistItem?(gesture.location(in: self))
    }

    /// Same decoupling as the checklist tap: only touches on a ▲/▼ button
    /// that is actually drawn ever reach this recognizer.
    private func configureAttachmentMoveTapGesture() {
        let gesture = UITapGestureRecognizer(
            target: self, action: #selector(handleAttachmentMoveTap(_:))
        )
        gesture.delegate = self
        addGestureRecognizer(gesture)
        attachmentMoveTapGesture = gesture
    }

    @objc private func handleAttachmentMoveTap(_ gesture: UITapGestureRecognizer) {
        _ = moveAttachmentImage?(gesture.location(in: self))
    }

    @objc private func handleAttachmentResizePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            if beginAttachmentResize?(point) != true {
                gesture.state = .cancelled
            }
        case .changed:
            continueAttachmentResize?(point)
        case .ended, .cancelled, .failed:
            endAttachmentResize?(point)
        default:
            break
        }
    }

    override func paste(_ sender: Any?) {
        if handleImagePaste?() == true { return }
        super.paste(sender)
    }

    /// Same gate as the macOS view: UIKit decides whether "붙여넣기" appears in
    /// the edit menu before it would ever call `paste(_:)`, and a plain-text
    /// `UITextView` bases that on the pasteboard holding *strings*. An
    /// image-only clipboard offers none, so the menu item is absent and the
    /// override above never runs. `hasImages` is the detection-only API —
    /// unlike reading `.image` it does not trip the paste notification.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    /// See the macOS view: typed text must never inherit a hidden marker's
    /// clear 0.1pt attributes. `setMarkedText` covers IME composition.
    override func insertText(_ text: String) {
        moveInsertionOffImageLine()
        restoreTypingAttributesIfHidden()
        super.insertText(text)
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        moveInsertionOffImageLine()
        restoreTypingAttributesIfHidden()
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    /// See the macOS view: an image line is atomic, so a keystroke landing on
    /// it gets a line of its own rather than breaking the marker.
    private func moveInsertionOffImageLine() {
        let selection = selectedRange
        guard selection.length == 0,
            let relocation =
                MarkdownAttachmentImageDecoration
                .insertionRelocation(
                    in: text,
                    cursorUTF16Offset: selection.location
                )
        else { return }
        selectedRange = NSRange(location: relocation.newlineOffset, length: 0)
        // `super`, not `self`: this must not recurse back through the guard.
        super.insertText("\n")
        selectedRange = NSRange(location: relocation.caretOffset, length: 0)
    }

    /// See the macOS view: typing attributes follow the block the caret is
    /// in, both to escape a hidden marker and to type headings at their size.
    private func restoreTypingAttributesIfHidden() {
        let desired = LiveMarkdownStyler.typingAttributes(
            forLinePrefix: MarkdownInputReconciliation.lineText(
                in: text, upTo: selectedRange.location
            )
        )
        var alpha: CGFloat?
        if let color = typingAttributes[.foregroundColor] as? UIColor {
            var value: CGFloat = 1
            if color.getWhite(nil, alpha: &value) { alpha = value }
        }
        let currentFont = typingAttributes[.font] as? UIFont
        let isHidden = MarkdownInputReconciliation.shouldRestoreTypingAttributes(
            fontPointSize: currentFont?.pointSize,
            foregroundAlpha: alpha
        )
        // Point size, not font equality — see the macOS view: the concrete
        // face gets substituted for Korean text.
        let sizeDiffers =
            currentFont?.pointSize
            != (desired[.font] as? UIFont)?.pointSize
        guard isHidden || sizeDiffers else { return }
        typingAttributes = desired
    }

    override func deleteBackward() {
        if removeListMarkerBeforeCursor?() == true { return }
        super.deleteBackward()
    }

    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [
            UIKeyCommand(
                input: "\t",
                modifierFlags: [],
                action: #selector(indentCurrentListItem)
            ),
            UIKeyCommand(
                input: "\t",
                modifierFlags: [.shift],
                action: #selector(outdentCurrentListItem)
            ),
        ]
    }

    @objc private func indentCurrentListItem() {
        adjustListIndentation?(.indent)
    }

    @objc private func outdentCurrentListItem() {
        adjustListIndentation?(.outdent)
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let origin = CGPoint(
            x: textContainerInset.left,
            y: textContainerInset.top
        )
        // Computed once per draw() call, not per match — see the matching
        // comment in the macOS override.
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: rect, in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange, actualGlyphRange: nil
        )
        EditorPalette.separator.setStroke()
        for characterRange in MarkdownSeparatorDecoration.ranges(in: text) {
            guard NSIntersectionRange(characterRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: characterRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else {
                continue
            }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let path = UIBezierPath()
            path.lineWidth = 1 / UIScreen.main.scale
            path.move(to: CGPoint(x: origin.x + 4, y: origin.y + fragment.midY))
            path.addLine(
                to: CGPoint(
                    x: origin.x + textContainer.size.width - 4,
                    y: origin.y + fragment.midY
                ))
            path.stroke()
        }
        for bulletMatch in MarkdownBulletDecoration.matches(in: text) {
            guard NSIntersectionRange(bulletMatch.markerRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: bulletMatch.markerRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else {
                continue
            }
            let marker = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            // Center on the marker glyph's own bounding box, not the line
            // fragment rect — the fragment includes the paragraph's line
            // spacing, which sits below the glyph, so using its midY pulls
            // the dot down off-center from the text.
            let dot = CGRect(
                x: origin.x + marker.midX - 3,
                y: origin.y + marker.midY - 3,
                width: 6,
                height: 6
            )
            if bulletMatch.indentationLevel == 0 {
                EditorPalette.label.setFill()
                UIBezierPath(ovalIn: dot).fill()
            } else {
                let ring = UIBezierPath(ovalIn: dot.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.2
                EditorPalette.label.setStroke()
                ring.stroke()
            }
        }
        for checklistMatch in MarkdownChecklistDecoration.matches(in: text) {
            guard NSIntersectionRange(checklistMatch.markerRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: checklistMatch.markerRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else {
                continue
            }
            let marker = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let box = MarkdownChecklistDecoration.boxRect(
                origin: origin, markerBounds: marker
            )
            if checklistMatch.checked {
                EditorPalette.label.setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 4).fill()
                let check = UIBezierPath()
                check.lineWidth = 1.6
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(
                    to: CGPoint(
                        x: box.minX + box.width * 0.22,
                        y: box.minY + box.height * 0.52
                    ))
                check.addLine(
                    to: CGPoint(
                        x: box.minX + box.width * 0.42,
                        y: box.minY + box.height * 0.72
                    ))
                check.addLine(
                    to: CGPoint(
                        x: box.minX + box.width * 0.80,
                        y: box.minY + box.height * 0.28
                    ))
                // The box fill is EditorPalette.label (adapts light/dark),
                // so the checkmark needs the opposite of whatever that
                // resolved to, not a fixed color.
                (traitCollection.userInterfaceStyle == .dark
                    ? UIColor.black
                    : UIColor.white).setStroke()
                check.stroke()
            } else {
                let outline = UIBezierPath(
                    roundedRect: box.insetBy(dx: 0.75, dy: 0.75),
                    cornerRadius: 4
                )
                outline.lineWidth = 1.5
                EditorPalette.secondaryLabel.setStroke()
                outline.stroke()
            }
        }
        let cursorLocation = selectedRange.location
        for imageMatch in MarkdownAttachmentImageDecoration.matches(in: text) {
            guard NSIntersectionRange(imageMatch.markerRange, visibleCharRange).length > 0
            else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: imageMatch.markerRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let displaySize =
                attachmentResizePreview
                .flatMap { $0.id == imageMatch.attachmentID ? $0.size : nil }
                ?? LiveMarkdownStyler.attachmentImageDisplaySize(
                    storedWidth: imageMatch.storedWidth,
                    storedHeight: imageMatch.storedHeight,
                    containerWidth: textContainer.size.width
                )
            let imageRect = MarkdownAttachmentImageDecoration.imageRect(
                origin: origin, fragment: fragment, displaySize: displaySize
            )
            guard rect.intersects(imageRect) else { continue }
            if let image = attachmentImage?(imageMatch.attachmentID) {
                image.draw(in: imageRect)
            } else {
                EditorPalette.codeBackground.setFill()
                UIBezierPath(roundedRect: imageRect, cornerRadius: 6).fill()
                EditorPalette.secondaryLabel.setStroke()
                UIBezierPath(
                    roundedRect: imageRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 6
                ).stroke()
            }
            let lineRange = (text as NSString).lineRange(for: imageMatch.markerRange)
            let cursorOnThisLine =
                cursorLocation >= lineRange.location
                && cursorLocation <= NSMaxRange(lineRange)
            if cursorOnThisLine {
                let handle = MarkdownAttachmentImageDecoration.handleRect(for: imageRect)
                let path = UIBezierPath(ovalIn: handle)
                EditorPalette.label.setFill()
                path.fill()
                (traitCollection.userInterfaceStyle == .dark
                    ? UIColor.black : UIColor.white).setStroke()
                path.lineWidth = 1.5
                path.stroke()
                drawMoveButtons(for: imageMatch, in: imageRect)
            }
        }
    }

    /// ▲/▼ only where the image can actually go — at the top of the body
    /// there is no ▲. The hit test (`Coordinator.attachmentMoveTarget`) asks
    /// the same question, so a button that isn't drawn never takes a tap.
    private func drawMoveButtons(
        for imageMatch: MarkdownAttachmentImageDecoration.Match,
        in imageRect: CGRect
    ) {
        let buttons = MarkdownAttachmentImageDecoration.moveButtonRects(for: imageRect)
        let glyphColor =
            traitCollection.userInterfaceStyle == .dark ? UIColor.black : UIColor.white
        let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        for (rect, direction, symbol) in [
            (buttons.up, MarkdownImageMoveDirection.up, "chevron.up"),
            (buttons.down, MarkdownImageMoveDirection.down, "chevron.down"),
        ] {
            guard
                MarkdownCommandProcessor.movingAttachmentImage(
                    at: imageMatch.markerRange.location, direction: direction, in: text
                ) != nil
            else { continue }
            EditorPalette.label.withAlphaComponent(0.75).setFill()
            UIBezierPath(ovalIn: rect).fill()
            guard
                let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                    .withTintColor(glyphColor, renderingMode: .alwaysOriginal)
            else { continue }
            glyph.draw(
                at: CGPoint(
                    x: rect.midX - glyph.size.width / 2,
                    y: rect.midY - glyph.size.height / 2
                )
            )
        }
    }
}

struct LiveMarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var autoFocus: Bool
    var textScale: Double
    var storeImageAttachment: ((Data, String, String) async -> UUID?)?
    var attachmentImage: ((UUID) async -> Data?)?
    var attachmentRevision = 0
    var imageInserter: MarkdownImageInserter?
    var requestImageInsertion: ((AttachmentPhotoSource) -> Void)?
    /// The text view itself is at least this tall, so the whole blank editor
    /// area under short text is the text view: a tap anywhere there focuses
    /// it (UIKit puts the caret at the end). Reporting only the text's own
    /// height let the `minHeight` frame center a one-line view, which left
    /// the top half of an empty body dead to taps — keys kept going to the
    /// title — and a blank gap above the first line of existing text.
    var minimumHeight: CGFloat = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownUITextView()
        context.coordinator.textView = textView
        imageInserter?.handler = { [weak coordinator = context.coordinator] id, data in
            coordinator?.insertAttachmentImage(id: id, imageData: data) ?? false
        }
        textView.isPointOnAttachmentMoveButton = {
            [weak coordinator = context.coordinator] point in
            coordinator?.attachmentMoveTarget(at: point) != nil
        }
        textView.moveAttachmentImage = { [weak coordinator = context.coordinator] point in
            coordinator?.moveAttachmentImage(at: point) ?? false
        }
        textView.adjustListIndentation = { [weak coordinator = context.coordinator] direction in
            coordinator?.adjustListIndentation(direction)
        }
        textView.removeListMarkerBeforeCursor = { [weak coordinator = context.coordinator] in
            coordinator?.removeListMarkerBeforeCursor() ?? false
        }
        textView.handleImagePaste = { [weak coordinator = context.coordinator] in
            coordinator?.handleImagePaste() ?? false
        }
        textView.attachmentImage = { [weak coordinator = context.coordinator] id in
            coordinator?.cachedAttachmentImage(for: id)
        }
        textView.isPointOnAttachmentResizeHandle = {
            [weak coordinator = context.coordinator] point in
            coordinator?.attachmentResizeTarget(at: point) != nil
        }
        textView.isPointOnChecklistBox = { [weak coordinator = context.coordinator] point in
            coordinator?.checklistTarget(at: point) != nil
        }
        textView.toggleChecklistItem = { [weak coordinator = context.coordinator] point in
            coordinator?.toggleChecklistItem(at: point) ?? false
        }
        textView.beginAttachmentResize = { [weak coordinator = context.coordinator] point in
            coordinator?.beginAttachmentResize(at: point) ?? false
        }
        textView.continueAttachmentResize = { [weak coordinator = context.coordinator] point in
            coordinator?.continueAttachmentResize(to: point)
        }
        textView.endAttachmentResize = { [weak coordinator = context.coordinator] point in
            coordinator?.endAttachmentResize(at: point)
        }
        textView.containerWidthChanged = { [weak coordinator = context.coordinator] width in
            coordinator?.recomputeAttachmentImageSizes(containerWidth: width)
        }
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        // The editor sits inside the screen's own ScrollView, so it must grow
        // to its full content height and let that one scroll view do the
        // scrolling. Left scrollable, it was a scroll view inside a scroll
        // view: the body stayed boxed at `minHeight` showing only its first
        // few paragraphs, the outer view took the drag, and the rest of a
        // long entry could not be reached at all.
        textView.isScrollEnabled = false
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        textView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(
            top: 8,
            left: 0,
            bottom: 8,
            right: 0
        )
        textView.text = text
        context.coordinator.adoptInitialText(text)
        LiveMarkdownStyler.apply(
            to: textView.textStorage,
            revealing: selection,
            containerWidth: textView.textContainer.size.width
        )
        textView.typingAttributes = LiveMarkdownStyler.baseAttributes
        // Set before the text view can become first responder, so UIKit
        // picks it up without `reloadInputViews()`.
        context.coordinator.updateKeyboardAccessory(
            context.environment.markdownKeyboardAccessory,
            on: textView
        )
        if autoFocus {
            DispatchQueue.main.async {
                textView.becomeFirstResponder()
            }
        }
        return textView
    }

    /// Without this SwiftUI sizes the editor from `intrinsicContentSize`, and
    /// a non-scrolling `UITextView` reports the width its text would occupy
    /// *unwrapped* — which made the whole page wider than the screen and
    /// pushed it sideways out of view. Pin the width to what SwiftUI offers
    /// and measure the wrapped height at exactly that width.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else {
            return nil
        }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(fitted.height, minimumHeight))
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attachmentRevisionDidChange(to: attachmentRevision)
        // Touches only the accessory toolbar, never the text or selection.
        context.coordinator.updateKeyboardAccessory(
            context.environment.markdownKeyboardAccessory,
            on: textView
        )
        guard !context.coordinator.isUpdating else { return }
        guard
            MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.markedTextRange != nil
            )
        else {
            context.coordinator.deferExternalText(text)
            return
        }
        if context.coordinator.applyDeferredExternalText(latest: text) { return }
        if MarkdownInputReconciliation.shouldApplyExternalText(
            incoming: text,
            current: textView.text,
            publishedHistory: context.coordinator.publishedHistory
        ) {
            context.coordinator.replaceExternalText(
                text,
                selection: selection,
                registersUndo: true
            )
            return
        }
        guard textView.text == text else { return }
        let safeSelection = clamped(selection, to: textView.text.utf16.count)
        if textView.selectedRange != safeSelection {
            textView.selectedRange = safeSelection
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveMarkdownTextEditor
        var isUpdating = false
        weak var textView: UITextView?
        private(set) var publishedHistory: [Int] = []

        /// Every write to the binding must go through here so the editor can
        /// recognise its own value when SwiftUI echoes it back a render later.
        func publish(_ newText: String) {
            MarkdownInputReconciliation.recordPublishedText(
                newText,
                in: &publishedHistory
            )
            parent.text = newText
        }

        /// The text the view opens with counts as already seen. SwiftUI's
        /// first update after a keystroke can still carry the body from
        /// before it — harmless for every later keystroke, whose previous
        /// value was published, but the opening text never was. Its late echo
        /// was taken for an external change and wiped out whatever had just
        /// been typed. Nothing on iOS sets the body back to the opening text
        /// while the editor is open (revision restore is macOS-only), so this
        /// can't swallow a real external change.
        func adoptInitialText(_ text: String) {
            MarkdownInputReconciliation.recordPublishedText(
                text,
                in: &publishedHistory
            )
        }

        /// See the matching field in the macOS Coordinator.
        private var deferredExternalText: (base: String, incoming: String)?

        func deferExternalText(_ incoming: String) {
            guard let textView,
                MarkdownInputReconciliation.shouldApplyExternalText(
                    incoming: incoming,
                    current: textView.text,
                    publishedHistory: publishedHistory
                )
            else { return }
            deferredExternalText = (deferredExternalText?.base ?? textView.text ?? "", incoming)
        }

        /// See the matching method in the macOS Coordinator.
        @discardableResult
        func applyDeferredExternalText(latest: String? = nil) -> Bool {
            guard let textView, var deferred = deferredExternalText else { return false }
            deferredExternalText = nil
            if let latest,
                MarkdownInputReconciliation.shouldApplyExternalText(
                    incoming: latest,
                    current: textView.text,
                    publishedHistory: publishedHistory
                )
            {
                deferred.incoming = latest
            }
            let rebased = ExternalTextRebase.rebase(
                local: textView.text ?? "",
                base: deferred.base,
                incoming: deferred.incoming,
                localCursorUTF16Offset: NSMaxRange(textView.selectedRange)
            )
            if rebased.text == textView.text {
                publish(rebased.text)
            } else {
                replaceExternalText(
                    rebased.text,
                    selection: NSRange(location: rebased.cursorUTF16Offset, length: 0),
                    registersUndo: true
                )
            }
            return true
        }

        private var stylingTask: Task<Void, Never>?
        private var imageCache: [UUID: PlatformImage] = [:]
        private var loadingAttachmentIDs: Set<UUID> = []
        /// See the matching field in the macOS Coordinator: without this,
        /// an attachment whose data isn't available yet gets re-queried on
        /// every single redraw forever, which reads as permanent typing lag.
        private var missingAttachmentIDs: Set<UUID> = []
        private var lastSeenAttachmentRevision: Int?
        private var resizingAttachmentID: UUID?
        private var resizeStartPoint: CGPoint = .zero
        private var resizeStartSize: CGSize = .zero
        /// Whether the body has had a caret the person put there. Until it
        /// has, the selection is just the initial `0` and a photo added from
        /// outside goes to the end rather than above everything written.
        private var hasPlacedCaret = false

        init(parent: LiveMarkdownTextEditor) {
            self.parent = parent
        }

        private var keyboardAccessoryActions: [() -> Void] = []
        private var keyboardAccessorySignature: [String]?

        /// Keeps the body's keyboard toolbar in step with the editor's items.
        /// Actions are refreshed on every call (they capture the latest view
        /// state); the bar items are rebuilt only when what's shown changes.
        func updateKeyboardAccessory(
            _ accessory: MarkdownKeyboardAccessory?,
            on textView: UITextView
        ) {
            guard let accessory else { return }
            keyboardAccessoryActions = accessory.items.map(\.action)
            guard accessory.signature != keyboardAccessorySignature else { return }
            keyboardAccessorySignature = accessory.signature

            let toolbar: UIToolbar
            if let existing = textView.inputAccessoryView as? UIToolbar {
                toolbar = existing
            } else {
                toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
                toolbar.autoresizingMask = .flexibleWidth
                textView.inputAccessoryView = toolbar
            }
            var index = 0
            func barItem(_ item: MarkdownKeyboardAccessory.Item) -> UIBarButtonItem {
                let actionIndex = index
                index += 1
                let action = UIAction(
                    title: item.title,
                    image: item.systemImage.flatMap { UIImage(systemName: $0) }
                ) { [weak self] _ in
                    guard let self,
                        self.keyboardAccessoryActions.indices.contains(actionIndex)
                    else { return }
                    self.keyboardAccessoryActions[actionIndex]()
                }
                let barItem = UIBarButtonItem(primaryAction: action)
                barItem.accessibilityLabel = item.title
                return barItem
            }
            toolbar.items =
                accessory.leading.map(barItem)
                + [.flexibleSpace()]
                + accessory.trailing.map(barItem)
            toolbar.sizeToFit()
        }

        func attachmentRevisionDidChange(to revision: Int) {
            guard lastSeenAttachmentRevision != revision else { return }
            lastSeenAttachmentRevision = revision
            guard !missingAttachmentIDs.isEmpty else { return }
            missingAttachmentIDs.removeAll()
            textView?.setNeedsDisplay()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            hasPlacedCaret = true
        }

        /// Synchronous — returns the cached decoded image if present, and as
        /// a side effect starts (at most one) async load per attachment.
        /// Never call `parent.attachmentImage` (async) directly from
        /// `draw(_:)`; this is the only sanctioned entry point.
        func cachedAttachmentImage(for id: UUID) -> PlatformImage? {
            if let image = imageCache[id] { return image }
            // Second synchronous check, still zero-cost: the shared cache
            // may already have this image decoded from a previous entry
            // (this Coordinator's own `imageCache` is thrown away whenever
            // the editor is recreated, e.g. switching entries).
            if let shared = AttachmentImageCache.shared.cachedImage(id: id) {
                imageCache[id] = shared
                return shared
            }
            guard !loadingAttachmentIDs.contains(id), !missingAttachmentIDs.contains(id),
                let provider = parent.attachmentImage
            else { return nil }
            loadingAttachmentIDs.insert(id)
            Task { @MainActor [weak self] in
                defer { self?.loadingAttachmentIDs.remove(id) }
                // Decodes downsampled (never at the source's full
                // resolution) — see AttachmentImageCache's doc comment.
                guard let self, let data = await provider(id),
                    let image = await AttachmentImageCache.shared.loadAndCache(
                        id: id, data: data
                    )
                else {
                    self?.missingAttachmentIDs.insert(id)
                    return
                }
                self.imageCache[id] = image
                self.textView?.setNeedsDisplay()
            }
            return nil
        }

        /// Brings the caret into view.
        ///
        /// `scrollRangeToVisible` does nothing now that the text view no
        /// longer scrolls itself, so the screen's scroll view has to be asked
        /// directly — otherwise typing near the end of a long entry runs off
        /// the bottom of the screen with nothing following it.
        func scrollCaretIntoView(_ textView: UITextView) {
            guard let position = textView.selectedTextRange?.end else { return }
            var view: UIView? = textView.superview
            while let candidate = view, !(candidate is UIScrollView) {
                view = candidate.superview
            }
            guard let scrollView = view as? UIScrollView else { return }
            let caret = textView.caretRect(for: position)
            guard !caret.isNull, caret.origin.y.isFinite,
                caret.size.height.isFinite
            else { return }
            // A little margin so the caret doesn't sit flush against the edge.
            scrollView.scrollRectToVisible(
                scrollView.convert(caret, from: textView).insetBy(dx: 0, dy: -24),
                animated: false
            )
        }

        /// The checklist item whose box is under the point, if any. Pure —
        /// the gesture delegate calls it to decide whether to claim a touch.
        func checklistTarget(at point: CGPoint) -> MarkdownChecklistDecoration.Match? {
            guard let textView else { return nil }
            let origin = CGPoint(
                x: textView.textContainerInset.left, y: textView.textContainerInset.top
            )
            let layoutManager = textView.layoutManager
            for match in MarkdownChecklistDecoration.matches(in: textView.text) {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: match.markerRange, actualCharacterRange: nil
                )
                guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
                let marker = layoutManager.boundingRect(
                    forGlyphRange: glyphRange, in: textView.textContainer
                )
                let box = MarkdownChecklistDecoration.boxRect(
                    origin: origin, markerBounds: marker
                )
                if box.contains(point) { return match }
            }
            return nil
        }

        /// See the macOS coordinator: toggling is an ordinary text edit, so
        /// it undoes, autosaves and syncs like any other. `[ ]` and `[x]` are
        /// the same length, so the caret needs no adjusting.
        func toggleChecklistItem(at point: CGPoint) -> Bool {
            guard let match = checklistTarget(at: point) else { return false }
            setChecklistState(match.toggledState, at: match.stateRange)
            return true
        }

        /// One character, edited in place. Rewriting the whole string and
        /// restyling the whole document — what `replaceExternalText` does —
        /// is far too much work for flipping a checkbox, and the delay was
        /// plainly visible on a long entry.
        private func setChecklistState(_ character: String, at range: NSRange) {
            guard let textView else { return }
            let previous = (textView.text as NSString).substring(with: range)
            textView.undoManager?.registerUndo(withTarget: self) { target in
                target.setChecklistState(previous, at: range)
            }
            textView.undoManager?.setActionName(String(localized: "체크리스트"))
            // `[ ]` and `[x]` are the same length, so `range` stays valid for
            // the undo above and the selection needs no adjusting.
            let storage = textView.textStorage
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: character)
            storage.endEditing()
            publish(textView.text)
            textView.setNeedsDisplay()
        }

        /// Pure hit test — which attachment (if any) has its resize handle
        /// under `point`, and what its current display size is. Used both by
        /// the gesture delegate's `shouldReceive` (no side effects allowed
        /// there) and by `beginAttachmentResize`.
        func attachmentResizeTarget(at point: CGPoint) -> (id: UUID, size: CGSize)? {
            guard let textView else { return nil }
            let origin = CGPoint(
                x: textView.textContainerInset.left, y: textView.textContainerInset.top
            )
            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            for match in MarkdownAttachmentImageDecoration.matches(in: textView.text) {
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: match.markerRange, actualCharacterRange: nil
                )
                guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
                let fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location, effectiveRange: nil
                )
                let displaySize = LiveMarkdownStyler.attachmentImageDisplaySize(
                    storedWidth: match.storedWidth,
                    storedHeight: match.storedHeight,
                    containerWidth: textContainer.size.width
                )
                let imageRect = MarkdownAttachmentImageDecoration.imageRect(
                    origin: origin, fragment: fragment, displaySize: displaySize
                )
                let handle = MarkdownAttachmentImageDecoration.handleRect(for: imageRect)
                if handle.contains(point) { return (match.attachmentID, displaySize) }
            }
            return nil
        }

        func beginAttachmentResize(at point: CGPoint) -> Bool {
            guard let target = attachmentResizeTarget(at: point) else { return false }
            resizingAttachmentID = target.id
            resizeStartPoint = point
            resizeStartSize = target.size
            return true
        }

        /// Live-drags the image's paragraph style height only — never runs a
        /// full restyle mid-drag. Attribute-only edits like this don't
        /// trigger `textViewDidChange` (see docs/known-issues.md), so
        /// there's no reentrancy risk running this on every pan update.
        func continueAttachmentResize(to point: CGPoint) {
            guard let id = resizingAttachmentID, let textView else { return }
            let size = draggedSize(to: point, containerWidth: textView.textContainer.size.width)
            guard
                let match = MarkdownAttachmentImageDecoration.matches(in: textView.text)
                    .first(where: { $0.attachmentID == id })
            else { return }
            let style = LiveMarkdownStyler.attachmentImageParagraphStyle(
                storedWidth: size.width, storedHeight: size.height,
                containerWidth: textView.textContainer.size.width
            )
            textView.textStorage.addAttribute(
                .paragraphStyle, value: style, range: match.markerRange
            )
            // Scales the drawn picture with the space being reserved for it.
            (textView as? MarkdownUITextView)?.attachmentResizePreview = (id, size)
            textView.setNeedsDisplay()
        }

        /// Recomputes every image's reserved height for a new container
        /// width (rotation/split-view resize) without a full restyle pass.
        /// Attribute-only edits like this never trigger `textViewDidChange`
        /// (see docs/known-issues.md), so this is safe from `layoutSubviews`.
        func recomputeAttachmentImageSizes(containerWidth: CGFloat) {
            guard let textView else { return }
            for match in MarkdownAttachmentImageDecoration.matches(in: textView.text) {
                let style = LiveMarkdownStyler.attachmentImageParagraphStyle(
                    storedWidth: match.storedWidth, storedHeight: match.storedHeight,
                    containerWidth: containerWidth
                )
                textView.textStorage.addAttribute(
                    .paragraphStyle, value: style, range: match.markerRange
                )
            }
            textView.setNeedsDisplay()
        }

        func endAttachmentResize(at point: CGPoint) {
            defer {
                resizingAttachmentID = nil
                (textView as? MarkdownUITextView)?.attachmentResizePreview = nil
            }
            guard let id = resizingAttachmentID, let textView else { return }
            let size = draggedSize(to: point, containerWidth: textView.textContainer.size.width)
            guard
                let match = MarkdownAttachmentImageDecoration.matches(in: textView.text)
                    .first(where: { $0.attachmentID == id })
            else { return }
            let replaced = (textView.text as NSString).replacingCharacters(
                in: match.markerRange,
                with:
                    "![](attachment:\(id.uuidString) =\(Int(size.width.rounded()))x\(Int(size.height.rounded())))"
            )
            let cursor = NSRange(location: match.markerRange.location, length: 0)
            replaceExternalText(replaced, selection: cursor, registersUndo: true)
        }

        /// Aspect-locked: only the horizontal drag distance drives the
        /// resize, height follows the original aspect ratio.
        private func draggedSize(to point: CGPoint, containerWidth: CGFloat) -> CGSize {
            let aspect = resizeStartSize.height / max(resizeStartSize.width, 1)
            let width = max(
                40, min(containerWidth, resizeStartSize.width + (point.x - resizeStartPoint.x)))
            return CGSize(width: width, height: width * aspect)
        }

        /// Puts an image stored from outside the text view (photo picker,
        /// camera, 파일, keyboard bar) into the body on a line of its own, at
        /// the caret the body last had — or at the end when it never had one
        /// (see `attachmentInsertionSelection`). The same
        /// `replaceExternalText` path as a pasted image, and the caret ends
        /// after the image, so several photos land in the order they came.
        @discardableResult
        func insertAttachmentImage(id: UUID, imageData: Data) -> Bool {
            // Mid-composition the text storage must not be rewritten — the
            // same rule `handleImagePaste` follows.
            guard let textView, textView.markedTextRange == nil else { return false }
            let selection = MarkdownCommandProcessor.attachmentInsertionSelection(
                lastCaret: hasPlacedCaret ? textView.selectedRange : nil,
                in: textView.text
            )
            let displaySize = UIImage(data: imageData).map {
                LiveMarkdownStyler.attachmentImageDisplaySize(
                    storedWidth: $0.size.width,
                    storedHeight: $0.size.height,
                    containerWidth: textView.textContainer.size.width
                )
            }
            let result = MarkdownCommandProcessor.insertingAttachmentImage(
                id: id,
                displaySize: displaySize,
                into: textView.text,
                selection: selection
            )
            replaceExternalText(
                result.text,
                selection: NSRange(location: result.cursorUTF16Offset, length: 0),
                registersUndo: true
            )
            hasPlacedCaret = true
            return true
        }

        /// Which ▲/▼ button is under `point`, if any. Only the image whose
        /// line holds the caret shows its buttons — the same test `draw(_:)`
        /// uses — and only for a direction it can move in. Pure: the tap
        /// gesture's delegate calls it to decide whether to claim a touch.
        func attachmentMoveTarget(
            at point: CGPoint
        ) -> (markerOffset: Int, direction: MarkdownImageMoveDirection)? {
            guard let textView else { return nil }
            let text = textView.text ?? ""
            let caret = textView.selectedRange.location
            let origin = CGPoint(
                x: textView.textContainerInset.left, y: textView.textContainerInset.top
            )
            let layoutManager = textView.layoutManager
            for match in MarkdownAttachmentImageDecoration.matches(in: text) {
                let lineRange = (text as NSString).lineRange(for: match.markerRange)
                guard caret >= lineRange.location, caret <= NSMaxRange(lineRange) else {
                    continue
                }
                let glyphRange = layoutManager.glyphRange(
                    forCharacterRange: match.markerRange, actualCharacterRange: nil
                )
                guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
                let fragment = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location, effectiveRange: nil
                )
                let imageRect = MarkdownAttachmentImageDecoration.imageRect(
                    origin: origin,
                    fragment: fragment,
                    displaySize: LiveMarkdownStyler.attachmentImageDisplaySize(
                        storedWidth: match.storedWidth,
                        storedHeight: match.storedHeight,
                        containerWidth: textView.textContainer.size.width
                    )
                )
                let buttons = MarkdownAttachmentImageDecoration.moveButtonRects(for: imageRect)
                for (rect, direction) in [(buttons.up, .up), (buttons.down, .down)]
                    as [(CGRect, MarkdownImageMoveDirection)]
                {
                    // A little slack around the drawn circle; the gap between
                    // the two buttons is wider than both slacks together.
                    guard rect.insetBy(dx: -2, dy: -2).contains(point),
                        MarkdownCommandProcessor.movingAttachmentImage(
                            at: match.markerRange.location, direction: direction, in: text
                        ) != nil
                    else { continue }
                    return (match.markerRange.location, direction)
                }
            }
            return nil
        }

        /// An ordinary text edit, so it undoes, autosaves and syncs like any
        /// other.
        func moveAttachmentImage(at point: CGPoint) -> Bool {
            guard let textView, textView.markedTextRange == nil,
                let target = attachmentMoveTarget(at: point),
                let result = MarkdownCommandProcessor.movingAttachmentImage(
                    at: target.markerOffset, direction: target.direction, in: textView.text
                )
            else { return false }
            replaceExternalText(
                result.text,
                selection: NSRange(location: result.cursorUTF16Offset, length: 0),
                registersUndo: true
            )
            return true
        }

        /// 사진 삽입 in the menu shown at the caret (a long press, or a tap on
        /// the caret). Not over a selection: a photo goes after one, never
        /// in place of it, and that menu is for acting on the selected text.
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length == 0, let request = parent.requestImageInsertion else {
                return nil
            }
            let image = UIImage(systemName: "photo")
            let insertPhoto: UIMenuElement
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                insertPhoto = UIMenu(
                    title: String(localized: "사진 삽입"),
                    image: image,
                    children: [
                        UIAction(
                            title: String(localized: "사진 보관함"),
                            image: UIImage(systemName: "photo.on.rectangle")
                        ) { _ in request(.library) },
                        UIAction(
                            title: String(localized: "촬영"),
                            image: UIImage(systemName: "camera")
                        ) { _ in
                            request(.camera)
                        },
                    ]
                )
            } else {
                insertPhoto = UIAction(title: String(localized: "사진 삽입"), image: image) { _ in
                    request(.library)
                }
            }
            // First, so it sits on the menu's first page instead of behind
            // the ▸ after 붙여넣기 · 선택 · 전체 선택.
            return UIMenu(children: [insertPhoto] + suggestedActions)
        }

        func replaceExternalText(
            _ replacement: String,
            selection replacementSelection: NSRange,
            registersUndo: Bool
        ) {
            guard let textView, textView.text != replacement else { return }
            stylingTask?.cancel()
            let previousText = textView.text ?? ""
            let previousSelection = textView.selectedRange
            if registersUndo, let undoManager = textView.undoManager {
                undoManager.registerUndo(withTarget: self) { target in
                    target.replaceExternalText(
                        previousText,
                        selection: previousSelection,
                        registersUndo: true
                    )
                }
                undoManager.setActionName(String(localized: "Markdown 서식"))
            }
            isUpdating = true
            textView.text = replacement
            let safeSelection = clamped(
                replacementSelection,
                to: replacement.utf16.count
            )
            LiveMarkdownStyler.apply(
                to: textView.textStorage,
                revealing: safeSelection,
                containerWidth: textView.textContainer.size.width
            )
            // Must follow the caret move — see the macOS coordinator's
            // `replaceExternalText` for why.
            textView.selectedRange = safeSelection
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            // Images, bullets and checkboxes are painted by the view's own
            // `draw(_:)`, which a text change alone doesn't rerun, and the
            // selection-change redraw is skipped while `isUpdating`. Swapping
            // two image lines changes no visible glyph at all, so without
            // this the old pictures stayed in their old places.
            textView.setNeedsDisplay()
            scrollCaretIntoView(textView)
            publish(replacement)
            parent.selection = safeSelection
            isUpdating = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            let currentSelection = textView.selectedRange
            if !MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.markedTextRange != nil
            ) {
                // Keep the SwiftUI source of truth current without touching
                // UITextView's marked range. Otherwise any unrelated view
                // update can restore the pre-composition text and drop Korean
                // jamo or an English autocorrection candidate. A deferred
                // reload owns the binding until composition ends, though.
                if deferredExternalText == nil { publish(textView.text) }
                parent.selection = currentSelection
                return
            }
            if applyDeferredExternalText() { return }
            isUpdating = true
            let expanded = MarkdownCommandProcessor.expandCommand(
                in: textView.text,
                cursorUTF16Offset: NSMaxRange(currentSelection)
            )
            let continued = MarkdownCommandProcessor.continuingBullet(
                in: expanded.text,
                cursorUTF16Offset: expanded.cursorUTF16Offset
            )
            let transformedText = continued.text != textView.text
            if transformedText {
                stylingTask?.cancel()
                textView.text = continued.text
                let cursor = NSRange(
                    location: continued.cursorUTF16Offset,
                    length: 0
                )
                textView.selectedRange = cursor
                scrollCaretIntoView(textView)
            }
            publish(continued.text)
            let preservedSelection = textView.selectedRange
            parent.selection = preservedSelection
            if transformedText
                || MarkdownInputReconciliation.shouldStyleImmediately(
                    after: textView.text,
                    cursorUTF16Offset: NSMaxRange(preservedSelection)
                )
            {
                // See the macOS coordinator: delimiters style immediately.
                stylingTask?.cancel()
                applyStyling(to: textView)
            } else {
                scheduleStyling(for: textView)
            }
            // Keep the caret in view on every change, not just list
            // continuation. Deferred one run-loop tick so the layout pass
            // that grows the text view's content size to fit new lines has
            // already run — see the macOS coordinator's textDidChange for
            // the full explanation.
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.scrollCaretIntoView(textView)
            }
            isUpdating = false
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            guard textView.markedTextRange == nil, !isUpdating else { return }
            stylingTask?.cancel()
            isUpdating = true
            applyStyling(to: textView)
            isUpdating = false
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            let selection = textView.selectedRange
            if !MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.markedTextRange != nil
            ) {
                parent.selection = selection
                return
            }
            parent.selection = selection
            // See the macOS coordinator: a caret landing just after a hidden
            // marker (clear, 0.1pt) would otherwise make the next keystrokes
            // invisible until the next styling pass.
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.setNeedsDisplay()
        }

        func adjustListIndentation(_ direction: MarkdownListIndentDirection) {
            guard let textView, textView.markedTextRange == nil else { return }
            let result = MarkdownCommandProcessor.adjustingListIndentation(
                in: textView.text,
                selection: textView.selectedRange,
                direction: direction
            )
            guard result.text != textView.text else { return }
            replaceExternalText(
                result.text,
                selection: result.selectionUTF16Range
                    ?? NSRange(
                        location: result.cursorUTF16Offset,
                        length: 0
                    ),
                registersUndo: true
            )
        }

        @discardableResult
        func removeListMarkerBeforeCursor() -> Bool {
            guard let textView, textView.markedTextRange == nil else { return false }
            let selection = textView.selectedRange
            guard selection.length == 0,
                let result = MarkdownCommandProcessor.removingListMarkerBeforeCursor(
                    in: textView.text,
                    cursorUTF16Offset: selection.location
                )
            else { return false }
            replaceExternalText(
                result.text,
                selection: result.selectionUTF16Range
                    ?? NSRange(
                        location: result.cursorUTF16Offset,
                        length: 0
                    ),
                registersUndo: true
            )
            return true
        }

        /// Returns false (letting `paste(_:)` fall through to the default
        /// behavior) whenever the pasteboard has no image or there's no
        /// entry to attach to yet — non-image paste (plain text, etc) is
        /// completely unaffected. Storage (hashing + disk write) is
        /// off-main-actor and can take a moment for a large image, so once
        /// this returns `true` the actual insertion happens asynchronously;
        /// the cursor position is captured now, not when storage finishes.
        @discardableResult
        func handleImagePaste() -> Bool {
            guard let textView, textView.markedTextRange == nil else { return false }
            guard let image = Self.pasteboardImageData(from: .general) else { return false }
            let selection = textView.selectedRange
            Task { @MainActor [weak self] in
                guard let self,
                    let attachmentID = await self.parent.storeImageAttachment?(
                        image.data,
                        image.filename,
                        image.mimeType
                    ), let textView = self.textView
                else { return }
                let displaySize = UIImage(data: image.data).map {
                    LiveMarkdownStyler.attachmentImageDisplaySize(
                        storedWidth: $0.size.width,
                        storedHeight: $0.size.height,
                        containerWidth: textView.textContainer.size.width
                    )
                }
                let result = MarkdownCommandProcessor.insertingAttachmentImage(
                    id: attachmentID,
                    displaySize: displaySize,
                    into: textView.text,
                    selection: selection
                )
                self.replaceExternalText(
                    result.text,
                    selection: NSRange(location: result.cursorUTF16Offset, length: 0),
                    registersUndo: true
                )
            }
            return true
        }

        private static func pasteboardImageData(
            from pasteboard: UIPasteboard
        ) -> (data: Data, filename: String, mimeType: String)? {
            guard let image = pasteboard.image, let data = image.pngData() else {
                return nil
            }
            return (data, "pasted.png", "image/png")
        }

        private func scheduleStyling(for textView: UITextView) {
            stylingTask?.cancel()
            stylingTask = Task { @MainActor [weak self, weak textView] in
                do {
                    try await Task.sleep(for: EditorTiming.stylingDebounce)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                    let self,
                    let textView,
                    textView.markedTextRange == nil,
                    !self.isUpdating
                else { return }
                self.isUpdating = true
                self.applyStyling(to: textView)
                self.isUpdating = false
            }
        }

        private func applyStyling(to textView: UITextView) {
            let selection = textView.selectedRange
            LiveMarkdownStyler.apply(
                to: textView.textStorage,
                revealing: selection,
                containerWidth: textView.textContainer.size.width
            )
            // Must follow the caret move — see `replaceExternalText`.
            textView.selectedRange = clamped(
                selection,
                to: textView.text.utf16.count
            )
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
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

private func clamped(_ range: NSRange, to length: Int) -> NSRange {
    let location = min(max(0, range.location), length)
    return NSRange(
        location: location,
        length: min(max(0, range.length), length - location)
    )
}

enum MarkdownInputReconciliation {
    static func canMutateTextStorage(isComposing: Bool) -> Bool {
        !isComposing
    }

    static let publishedHistoryLimit = 32

    /// Identifies a published value without keeping a copy of the document.
    ///
    /// The history is consulted on every render, so it stores fingerprints
    /// rather than strings. Keeping 32 document copies and comparing them one
    /// by one would cost the whole document length per entry on each render.
    static func publishedFingerprint(_ text: String) -> Int {
        var hasher = Hasher()
        hasher.combine(text)
        return hasher.finalize()
    }

    /// Block-level markers, matched against a whole line: the line holds
    /// nothing but the marker, so the caret is sitting right where the
    /// formatting should switch on.
    private static let blockMarkerRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:#{1,6} |[-*] (?:\[[ xX]\] )?|> |---|\*\*\*|___)$"#
    )

    /// Whether the caret has just completed a block marker, meaning the line
    /// should be restyled on this keystroke instead of on the debounce.
    ///
    /// Restyling the whole document is expensive, so it normally waits for a
    /// pause — but a marker is exactly the case where waiting is visible:
    /// typing `# ` left the line unformatted, and the very next character
    /// used to cancel the pending pass, so the heading
    /// only appeared after Return. Markers complete rarely, so styling
    /// eagerly here costs nothing in ordinary typing.
    static func completesBlockMarker(
        in text: String,
        cursorUTF16Offset: Int
    ) -> Bool {
        let line = lineText(in: text, upTo: cursorUTF16Offset)
        guard !line.isEmpty else { return false }
        return blockMarkerRegex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) != nil
    }

    /// The current line from its start up to the caret — what decides which
    /// block the caret is in, for both marker completion and the attributes
    /// the next keystroke should carry.
    static func lineText(in text: String, upTo cursorUTF16Offset: Int) -> String {
        let source = text as NSString
        let cursor = min(max(0, cursorUTF16Offset), source.length)
        guard cursor > 0 else { return "" }
        let previousNewline = source.range(
            of: "\n",
            options: .backwards,
            range: NSRange(location: 0, length: cursor)
        )
        let lineStart =
            previousNewline.location == NSNotFound
            ? 0
            : NSMaxRange(previousNewline)
        return source.substring(
            with: NSRange(
                location: lineStart,
                length: cursor - lineStart
            ))
    }

    /// Whether the text view's current typing attributes would render the
    /// next keystroke invisible, and must be reset to the base attributes.
    ///
    /// Markers are hidden by painting them clear at a 0.1pt font and drawing
    /// the real decoration over them, and AppKit/UIKit seed typing attributes
    /// from the character before the caret. A caret that lands just after a
    /// hidden marker — the `# ` a slash command leaves behind, or an image
    /// line, which is hidden in its entirety — therefore types text that is
    /// stored correctly but never drawn until restyling repairs it. Restore
    /// the attributes before insertion instead of waiting for that pass.
    ///
    /// Checked at the moment of insertion rather than at each of the many
    /// places the caret can move, so no path can miss it. Ordinary typing
    /// leaves attributes untouched — important for IME composition, which
    /// must not be disturbed (see `docs/known-issues.md`).
    static func shouldRestoreTypingAttributes(
        fontPointSize: CGFloat?,
        foregroundAlpha: CGFloat?
    ) -> Bool {
        if let fontPointSize, fontPointSize < 1 { return true }
        if let foregroundAlpha, foregroundAlpha <= 0 { return true }
        return false
    }

    /// Records a value the editor pushed into its SwiftUI binding.
    static func recordPublishedText(
        _ text: String,
        in history: inout [Int]
    ) {
        let fingerprint = publishedFingerprint(text)
        if history.last == fingerprint { return }
        history.append(fingerprint)
        if history.count > publishedHistoryLimit {
            history.removeFirst(history.count - publishedHistoryLimit)
        }
    }

    /// Decides whether a binding value should overwrite the text view.
    ///
    /// SwiftUI hands back the value captured when the view was rendered. While
    /// that render is in flight the user keeps typing, so the value can arrive
    /// one or more keystrokes behind what the text view already holds. Writing
    /// it back would silently drop those keystrokes, which reads as characters
    /// being swallowed. Any value the editor itself published is therefore
    /// treated as an echo; only text the editor has never seen is external.
    static func shouldApplyExternalText(
        incoming: String,
        current: String,
        publishedHistory: [Int]
    ) -> Bool {
        guard incoming != current else { return false }
        return !publishedHistory.contains(publishedFingerprint(incoming))
    }

    /// Called after composition ends. Delimiters can complete inline syntax
    /// without a following space; other edits use the deferred styling pass.
    static func shouldStyleImmediately(
        after text: String,
        cursorUTF16Offset: Int
    ) -> Bool {
        if completesBlockMarker(in: text, cursorUTF16Offset: cursorUTF16Offset) {
            return true
        }
        let source = text as NSString
        guard cursorUTF16Offset > 0,
            cursorUTF16Offset <= source.length
        else { return false }
        let lastCharacter = source.substring(
            with: NSRange(
                location: cursorUTF16Offset - 1,
                length: 1
            ))
        return ["*", "_", "~", "=", "`", ")", "]"].contains(lastCharacter)
    }
}

/// Carries what the user typed during an IME composition over to an external
/// text change (an entry reload) that had to wait for the composition to end.
///
/// The text view refuses external text while text is marked, so a reload that
/// lands mid-composition is held back. When the composition ends, the editor
/// holds `base` (its text when the reload arrived) plus the composed
/// characters, and the reload holds `base` plus its own change — typically
/// detail lines appended by a kind move. Applying either alone drops the
/// other's change.
enum ExternalTextRebase {
    struct Result: Equatable {
        let text: String
        /// UTF-16 caret offset: just after the carried-over edit, or the
        /// local caret mapped into `text` when there was nothing to carry.
        let cursorUTF16Offset: Int
    }

    /// Applies the edit `base → local` to `incoming`. When both edits touch
    /// the same part of `base`, `incoming` wins and the local edit (at most
    /// the composed characters) is dropped: the reload is the one that cannot
    /// be retyped.
    static func rebase(
        local: String,
        base: String,
        incoming: String,
        localCursorUTF16Offset: Int
    ) -> Result {
        let baseUnits = Array(base.utf16)
        let localUnits = Array(local.utf16)
        let incomingUnits = Array(incoming.utf16)
        let localEdit = changedRange(from: baseUnits, to: localUnits)
        let incomingEdit = changedRange(from: baseUnits, to: incomingUnits)
        let shift = incomingUnits.count - baseUnits.count

        guard let localEdit else {
            // Nothing typed since the reload arrived: keep the caret where
            // it was, moved past whatever the reload inserted before it.
            var cursor = min(max(0, localCursorUTF16Offset), baseUnits.count)
            if let incomingEdit, cursor > incomingEdit.start {
                cursor =
                    cursor >= incomingEdit.end
                    ? cursor + shift
                    : incomingEdit.start + incomingEdit.replacementCount
            }
            return Result(text: incoming, cursorUTF16Offset: cursor)
        }
        let inserted = localUnits[
            localEdit.start..<(localEdit.start + localEdit.replacementCount)]
        let offset: Int
        if let incomingEdit {
            if localEdit.end <= incomingEdit.start {
                offset = 0
            } else if incomingEdit.end <= localEdit.start {
                offset = shift
            } else {
                return Result(
                    text: incoming,
                    cursorUTF16Offset: incomingEdit.start + incomingEdit.replacementCount)
            }
        } else {
            offset = 0
        }
        let start = localEdit.start + offset
        let end = localEdit.end + offset
        let merged = Array(incomingUnits[..<start]) + inserted + incomingUnits[end...]
        return Result(
            text: String(decoding: merged, as: UTF16.self),
            cursorUTF16Offset: start + inserted.count
        )
    }

    /// The range of `old` that differs from `new` (after the common prefix
    /// and suffix), and how many units of `new` replace it. Nil when equal.
    /// Boundaries never split a surrogate pair.
    private static func changedRange(
        from old: [UTF16.CodeUnit],
        to new: [UTF16.CodeUnit]
    ) -> (start: Int, end: Int, replacementCount: Int)? {
        guard old != new else { return nil }
        var prefix = 0
        let limit = min(old.count, new.count)
        while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }
        return (prefix, old.count - suffix, new.count - suffix - prefix)
    }
}

struct MarkdownPreviewView: View {
    @EnvironmentObject private var model: AppModel
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
        case let .heading(level):
            inlineText(block.content)
                .font(headingFont(level: level))
        case .paragraph:
            inlineText(block.content)
                .font(.body)
        case let .bullet(indentation):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(JournalTheme.ink)
                    .frame(width: 6, height: 6)
                    .alignmentGuide(.firstTextBaseline) { dimensions in
                        dimensions[VerticalAlignment.center]
                    }
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
