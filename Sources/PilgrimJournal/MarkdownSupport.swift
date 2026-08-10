import Foundation
import SwiftUI

enum EditorTextScale {
    static let defaultValue = 1.15
    static let minimum = 0.7
    static let maximum = 1.6
}
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
        case .bold: "굵게"
        case .italic: "기울임"
        case .strikethrough: "취소선"
        case .highlight: "하이라이트"
        case .code: "인라인 코드"
        case .heading: "제목"
        case .bullet: "불릿"
        case .quote: "인용"
        case .link: "링크"
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
}

enum MarkdownCommandProcessor {
    struct ExpansionResult: Equatable {
        var text: String
        var cursorUTF16Offset: Int
        var selectionUTF16Range: NSRange? = nil
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

    static func trailingSlashQuery(in text: String) -> String? {
        let line = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).last.map(String.init) ?? ""
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
        let lineStart = previousNewline.location == NSNotFound
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

        let surroundingMarker: String? = switch format {
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
               selected.hasSuffix(marker) {
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
               source.substring(with: trailingRange) == marker {
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
            let prefix = switch format {
            case .heading: "## "
            case .bullet: "* "
            case .quote: "> "
            default: ""
            }
            replacement = lines
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
        let preservedSelection: NSRange = switch format {
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
        }
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
        let lineRange = source.lineRange(for: NSRange(
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
        let lineStart = priorNewline.location == NSNotFound
            ? 0
            : NSMaxRange(priorNewline)
        let previousLine = source.substring(with: NSRange(
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

    private static func listItem(
        from line: String
    ) -> (
        indentation: String,
        bullet: String?,
        number: Int?,
        isChecklist: Bool,
        content: String
    )? {
        let pattern = #"^([ \t]*)(?:(\*|-)|(\d+)\.)(?: (\[[ xX]\]))? (.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let source = line as NSString
        let range = NSRange(location: 0, length: source.length)
        guard let match = regex.firstMatch(in: line, range: range) else {
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

private enum MarkdownBlockKind: Equatable {
    case heading(Int)
    case paragraph
    case bullet(Int)
    case numbered(String, Int)
    case checklist(Bool, Int)
    case quote
    case code(String?)
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
        var codeLanguage: String?
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
                blocks.append(MarkdownBlock(
                    kind: .heading(heading.level),
                    content: heading.content
                ))
            } else if let checklist = checklistItem(from: contentLine) {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .checklist(checklist.checked, indentation),
                    content: checklist.content
                ))
            } else if contentLine.hasPrefix("- ")
                        || contentLine.hasPrefix("* ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .bullet(indentation),
                    content: String(contentLine.dropFirst(2))
                ))
            } else if contentLine.hasPrefix("> ") {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .quote,
                    content: String(contentLine.dropFirst(2))
                ))
            } else if let numbered = numberedListItem(from: contentLine) {
                flushParagraph()
                blocks.append(MarkdownBlock(
                    kind: .numbered(numbered.marker, indentation),
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

    private static func indentationLevel(in line: String) -> Int {
        let prefix = line.prefix(while: { $0 == " " || $0 == "\t" })
        let spaces = prefix.reduce(into: 0) { count, character in
            count += character == "\t" ? 2 : 1
        }
        return spaces / 2
    }

    private static func heading(
        from line: String
    ) -> (level: Int, content: String)? {
        let hashes = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(hashes.count),
              line.dropFirst(hashes.count).hasPrefix(" ") else {
            return nil
        }
        return (hashes.count, String(line.dropFirst(hashes.count + 1)))
    }

    private static func checklistItem(
        from line: String
    ) -> (checked: Bool, content: String)? {
        guard line.hasPrefix("- [") || line.hasPrefix("* ["),
              line.count >= 6 else { return nil }
        let source = line as NSString
        let marker = source.substring(with: NSRange(location: 2, length: 3))
        guard ["[ ]", "[x]", "[X]"].contains(marker),
              source.substring(with: NSRange(location: 5, length: 1)) == " " else {
            return nil
        }
        return (marker.lowercased() == "[x]", source.substring(from: 6))
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
    @State private var selection = NSRange(location: 0, length: 0)
    @AppStorage("editor-text-scale") private var editorTextScale =
        EditorTextScale.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                                    "\(command.trigger)  \(command.title)",
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

            LiveMarkdownTextEditor(
                text: $text,
                selection: $selection,
                autoFocus: autoFocus,
                textScale: editorTextScale
            )
                .frame(
                    maxWidth: .infinity,
                    minHeight: minHeight,
                    maxHeight: .infinity
                )
                .accessibilityLabel("Markdown 본문")

            #if os(macOS)
            Color.clear
                .frame(width: 0, height: 0)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .applyMarkdownKeyboardCommand
                    )
                ) { notification in
                    guard let rawValue = notification.object as? String,
                          let command = MarkdownKeyboardCommand(rawValue: rawValue),
                          MacMarkdownEditorFocus.isFocused
                    else { return }
                    apply(command)
                }
            #endif

            if let query = MarkdownCommandProcessor.trailingSlashQuery(in: text) {
                commandPalette(query: query)
            }

            Text("/ 입력으로 제목, 목록, 체크리스트, 인용, 코드와 날짜 삽입")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func apply(_ format: MarkdownInlineFormat) {
        let result = MarkdownCommandProcessor.applying(
            format,
            to: text,
            selection: selection
        )
        text = result.text
        selection = result.selectionUTF16Range
            ?? NSRange(location: result.cursorUTF16Offset, length: 0)
    }

    private func apply(_ command: MarkdownKeyboardCommand) {
        let result = MarkdownCommandProcessor.applyingKeyboardCommand(
            command,
            to: text,
            selection: selection
        )
        text = result.text
        selection = result.selectionUTF16Range
            ?? NSRange(location: result.cursorUTF16Offset, length: 0)
    }

    @ViewBuilder
    private func commandPalette(query: String) -> some View {
        let matches = MarkdownSlashCommand.allCases.filter {
            query.isEmpty
                || $0.rawValue.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
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
                        let result = MarkdownCommandProcessor
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
                            Text(command.title)
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
            .clipShape(RoundedRectangle(
                cornerRadius: JournalTheme.Radius.medium,
                style: .continuous
            ))
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
    private static let pattern =
        #"\\([\u0021-\u002F\u003A-\u0040\u005B-\u0060\u007B-\u007E])"#

    static func markerRanges(in markdown: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.matches(in: markdown, range: range).map {
            NSRange(location: $0.range.location, length: 1)
        }
    }

    static func unescaped(_ markdown: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return markdown
        }
        let range = NSRange(markdown.startIndex..., in: markdown)
        return regex.stringByReplacingMatches(
            in: markdown,
            range: range,
            withTemplate: "$1"
        )
    }
}

private enum CodeSyntaxHighlighter {
    private static let keywordPattern =
        #"\b(?:actor|and|any|as|async|await|break|case|catch|class|const|continue|def|default|do|else|enum|extension|false|final|for|from|func|function|guard|if|import|in|is|let|new|nil|not|null|or|private|protocol|public|return|self|some|static|struct|switch|this|throw|throws|true|try|typealias|var|where|while)\b"#
    private static let numberPattern = #"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#
    private static let stringPattern = #"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#

    static func apply(
        to value: NSMutableAttributedString,
        range: NSRange,
        language: String?
    ) {
        color(keywordPattern, with: EditorPalette.codeKeyword, in: value, range: range)
        color(numberPattern, with: EditorPalette.codeNumber, in: value, range: range)

        let stringRanges = matches(stringPattern, in: value.string, range: range)
            .map(\.range)
        stringRanges.forEach {
            value.addAttribute(.foregroundColor, value: EditorPalette.codeString, range: $0)
        }

        let normalizedLanguage = language?.lowercased() ?? ""
        let commentPatterns: [String]
        if ["python", "py", "shell", "sh", "bash", "zsh", "ruby", "rb"]
            .contains(normalizedLanguage) {
            commentPatterns = [#"(?m)#.*$"#]
        } else if ["json"].contains(normalizedLanguage) {
            commentPatterns = []
        } else {
            commentPatterns = [#"(?m)//.*$"#, #"(?s)/\*.*?\*/"#]
        }
        for pattern in commentPatterns {
            for match in matches(pattern, in: value.string, range: range) {
                guard !stringRanges.contains(where: {
                    NSIntersectionRange($0, match.range).length > 0
                }) else { continue }
                value.addAttribute(
                    .foregroundColor,
                    value: EditorPalette.codeComment,
                    range: match.range
                )
            }
        }
    }

    private static func color(
        _ pattern: String,
        with color: PlatformColor,
        in value: NSMutableAttributedString,
        range: NSRange
    ) {
        matches(pattern, in: value.string, range: range).forEach {
            value.addAttribute(.foregroundColor, value: color, range: $0.range)
        }
    }

    private static func matches(
        _ pattern: String,
        in source: String,
        range: NSRange
    ) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return regex.matches(in: source, range: range)
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
        revealing selection: NSRange? = nil
    ) {
        let fullRange = NSRange(location: 0, length: storage.length)
        guard fullRange.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)

        applyInlineStyle(
            pattern: #"(?<!\\)\*\*([^*\n]+)(?<!\\)\*\*"#,
            trait: .bold,
            storage: storage
        )
        applyInlineStyle(
            pattern: #"(?<!\\)__([^_\n]+)(?<!\\)__"#,
            trait: .bold,
            storage: storage
        )
        applyInlineStyle(
            pattern: #"(?<![\\*])\*([^*\n]+)(?<!\\)\*(?!\*)"#,
            trait: .italic,
            storage: storage
        )
        applyInlineStyle(
            pattern: #"(?<![\\_])_([^_\n]+)(?<!\\)_(?!_)"#,
            trait: .italic,
            storage: storage
        )
        applyRegex(#"(?<!\\)~~([^~\n]+)(?<!\\)~~"#, to: storage) { match in
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: match.range(at: 1)
            )
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }
        applyRegex(#"(?<!\\)==([^=\n]+)(?<!\\)=="#, to: storage) { match in
            storage.addAttribute(
                .backgroundColor,
                value: EditorPalette.highlight,
                range: match.range(at: 1)
            )
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
        }
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

        applyRegex(#"(?m)^(#{1,6})[ \t]+(.*)$"#, to: storage) { match in
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
            storage.addAttributes([
                .font: hiddenMarkerFont,
                .foregroundColor: PlatformColor.clear,
            ], range: hiddenPrefixRange)
        }
        applyRegex(#"(?m)^([\-*]) (.*)$"#, to: storage) { match in
            storage.addAttributes([
                .foregroundColor: PlatformColor.clear,
                .font: hiddenMarkerFont,
            ], range: match.range(at: 1))
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
        applyRegex(
            #"(?m)^([ \t]*)([-*]) (\[([ xX])\]) (.*)$"#,
            to: storage
        ) { match in
            let state = (storage.string as NSString).substring(
                with: match.range(at: 4)
            )
            let checked = state.lowercased() == "x"
            storage.addAttributes([
                .foregroundColor: EditorPalette.label,
                .font: bodyFont,
                .attachment: checkboxAttachment(checked: checked),
            ], range: match.range(at: 2))
            storage.addAttributes([
                .font: hiddenMarkerFont,
                .foregroundColor: PlatformColor.clear,
            ], range: match.range(at: 3))
            storage.addAttribute(
                .paragraphStyle,
                value: bulletParagraphStyle,
                range: match.range
            )
            if checked {
                storage.addAttribute(
                    .foregroundColor,
                    value: EditorPalette.secondaryLabel,
                    range: match.range(at: 5)
                )
            }
        }
        applyRegex(#"(?m)^(>) (.*)$"#, to: storage) { match in
            #if os(macOS)
            storage.addAttributes([
                .font: hiddenMarkerFont,
                .foregroundColor: PlatformColor.clear,
            ], range: match.range(at: 1))
            #else
            storage.addAttributes([
                .font: bodyFont,
                .foregroundColor: EditorPalette.quoteBar,
            ], range: match.range(at: 1))
            #endif
            storage.addAttributes([
                .foregroundColor: EditorPalette.secondaryLabel,
                .paragraphStyle: quoteParagraphStyle(),
            ], range: match.range)
        }
        applyRegex(#"(?m)^(---|\*\*\*|___)$"#, to: storage) { match in
            storage.addAttributes([
                .font: hiddenMarkerFont,
                .foregroundColor: PlatformColor.clear,
                .paragraphStyle: separatorParagraphStyle,
            ], range: match.range)
        }
        applyRegex(#"(?s)(```[^\n]*\n?)(.*?)(\n?```)"#, to: storage) { match in
            storage.addAttributes([
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
                storage.addAttributes([
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
                    isActive = selection.location >= tokenRange.location
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

    private static var bulletParagraphStyle: NSParagraphStyle {
        let style = bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.firstLineHeadIndent = 18
        style.headIndent = 18
        style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        return style
    }

    private static func quoteParagraphStyle() -> NSParagraphStyle {
        let style = bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
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
        let style = bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
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
        let style = bodyParagraphStyle.mutableCopy() as! NSMutableParagraphStyle
        style.minimumLineHeight = 20
        style.maximumLineHeight = 20
        style.paragraphSpacingBefore = 6
        style.paragraphSpacing = 6
        return style
    }

    private static func checkboxAttachment(checked: Bool) -> NSTextAttachment {
        let attachment = NSTextAttachment()
#if os(macOS)
        attachment.image = NSImage(
            systemSymbolName: checked ? "checkmark.square.fill" : "square",
            accessibilityDescription: checked ? "완료" : "미완료"
        )
        attachment.bounds = NSRect(x: 0, y: -2, width: 14, height: 14)
#else
        attachment.image = UIImage(
            systemName: checked ? "checkmark.square.fill" : "square"
        )?.withTintColor(EditorPalette.label, renderingMode: .alwaysOriginal)
        attachment.bounds = CGRect(x: 0, y: -2, width: 14, height: 14)
#endif
        return attachment
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
private final class MarkdownNSTextView: NSTextView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        EditorPalette.separator.setStroke()
        for characterRange in MarkdownSeparatorDecoration.ranges(in: string) {
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
            line.line(to: NSPoint(
                x: origin.x + textContainer.size.width - 4,
                y: origin.y + fragment.midY
            ))
            line.stroke()
        }
    }
}

private struct LiveMarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var autoFocus: Bool
    var textScale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.7
        scrollView.maxMagnification = 1.6
        scrollView.magnification = CGFloat(textScale)

        let textView = MarkdownNSTextView()
        textView.identifier = MacMarkdownEditorFocus.identifier
        context.coordinator.textView = textView
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
        LiveMarkdownStyler.apply(
            to: textView.textStorage!,
            revealing: selection
        )
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
        if abs(scrollView.magnification - CGFloat(textScale)) > 0.001 {
            scrollView.setMagnification(CGFloat(textScale), centeredAt: .zero)
        }
        guard MarkdownInputReconciliation.canMutateTextStorage(
            isComposing: textView.hasMarkedText()
        ) else { return }
        if textView.string != text {
            context.coordinator.replaceExternalText(
                text,
                selection: selection,
                registersUndo: true
            )
            return
        }
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

        init(parent: LiveMarkdownTextEditor) {
            self.parent = parent
        }

        func replaceExternalText(
            _ replacement: String,
            selection replacementSelection: NSRange,
            registersUndo: Bool
        ) {
            guard let textView, textView.string != replacement else { return }
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
                undoManager.setActionName("Markdown 서식")
            }
            isUpdating = true
            textView.string = replacement
            let safeSelection = clamped(
                replacementSelection,
                to: replacement.utf16.count
            )
            LiveMarkdownStyler.apply(
                to: textView.textStorage!,
                revealing: safeSelection
            )
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.setSelectedRange(safeSelection)
            parent.text = replacement
            parent.selection = safeSelection
            isUpdating = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating,
                  let textView = notification.object as? NSTextView else {
                return
            }
            let currentSelection = textView.selectedRange()
            if !MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.hasMarkedText()
            ) {
                parent.text = textView.string
                parent.selection = currentSelection
                return
            }
            isUpdating = true
            let expanded = MarkdownCommandProcessor.expandCommand(
                in: textView.string,
                cursorUTF16Offset: NSMaxRange(currentSelection)
            )
            let continued = MarkdownCommandProcessor.continuingBullet(
                in: expanded.text,
                cursorUTF16Offset: expanded.cursorUTF16Offset
            )
            if continued.text != textView.string {
                textView.string = continued.text
                textView.setSelectedRange(NSRange(
                    location: continued.cursorUTF16Offset,
                    length: 0
                ))
            }
            parent.text = continued.text
            let preservedSelection = textView.selectedRange()
            parent.selection = preservedSelection
            LiveMarkdownStyler.apply(
                to: textView.textStorage!,
                revealing: preservedSelection
            )
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.setSelectedRange(preservedSelection)
            isUpdating = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating,
                  let textView = notification.object as? NSTextView else {
                return
            }
            let selection = textView.selectedRange()
            if !MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.hasMarkedText()
            ) {
                parent.selection = selection
                return
            }
            isUpdating = true
            parent.selection = selection
            LiveMarkdownStyler.apply(
                to: textView.textStorage!,
                revealing: selection
            )
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.setSelectedRange(selection)
            isUpdating = false
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
private final class MarkdownUITextView: UITextView {
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        let origin = CGPoint(
            x: textContainerInset.left,
            y: textContainerInset.top
        )
        EditorPalette.separator.setStroke()
        for characterRange in MarkdownSeparatorDecoration.ranges(in: text) {
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
            path.addLine(to: CGPoint(
                x: origin.x + textContainer.size.width - 4,
                y: origin.y + fragment.midY
            ))
            path.stroke()
        }
    }
}

private struct LiveMarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var autoFocus: Bool
    var textScale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = MarkdownUITextView()
        context.coordinator.textView = textView
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
        LiveMarkdownStyler.apply(
            to: textView.textStorage,
            revealing: selection
        )
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
        guard MarkdownInputReconciliation.canMutateTextStorage(
            isComposing: textView.markedTextRange != nil
        ) else { return }
        if textView.text != text {
            context.coordinator.replaceExternalText(
                text,
                selection: selection,
                registersUndo: true
            )
            return
        }
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
        private var stylingTask: Task<Void, Never>?

        init(parent: LiveMarkdownTextEditor) {
            self.parent = parent
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
                undoManager.setActionName("Markdown 서식")
            }
            isUpdating = true
            textView.text = replacement
            let safeSelection = clamped(
                replacementSelection,
                to: replacement.utf16.count
            )
            LiveMarkdownStyler.apply(
                to: textView.textStorage,
                revealing: safeSelection
            )
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.selectedRange = safeSelection
            parent.text = replacement
            parent.selection = safeSelection
            isUpdating = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            let currentSelection = textView.selectedRange
            if !MarkdownInputReconciliation.canMutateTextStorage(
                isComposing: textView.markedTextRange != nil
            ) {
                parent.text = textView.text
                parent.selection = currentSelection
                return
            }
            isUpdating = true
            let expanded = MarkdownCommandProcessor.expandCommand(
                in: textView.text,
                cursorUTF16Offset: NSMaxRange(currentSelection)
            )
            let continued = MarkdownCommandProcessor.continuingBullet(
                in: expanded.text,
                cursorUTF16Offset: expanded.cursorUTF16Offset
            )
            if continued.text != textView.text {
                stylingTask?.cancel()
                textView.text = continued.text
                textView.selectedRange = NSRange(
                    location: continued.cursorUTF16Offset,
                    length: 0
                )
            }
            parent.text = continued.text
            let preservedSelection = textView.selectedRange
            parent.selection = preservedSelection
            if continued.text != expanded.text
                || expanded.text != textView.text {
                applyStyling(to: textView)
            } else {
                scheduleStyling(for: textView)
            }
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
            scheduleStyling(for: textView)
        }

        private func scheduleStyling(for textView: UITextView) {
            stylingTask?.cancel()
            stylingTask = Task { @MainActor [weak self, weak textView] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      let textView,
                      textView.markedTextRange == nil,
                      !self.isUpdating else { return }
                self.isUpdating = true
                self.applyStyling(to: textView)
                self.isUpdating = false
            }
        }

        private func applyStyling(to textView: UITextView) {
            let selection = textView.selectedRange
            LiveMarkdownStyler.apply(
                to: textView.textStorage,
                revealing: selection
            )
            textView.typingAttributes = LiveMarkdownStyler.baseAttributes
            textView.selectedRange = clamped(
                selection,
                to: textView.text.utf16.count
            )
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
}

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
        case let .heading(level):
            inlineText(block.content)
                .font(headingFont(level: level))
        case .paragraph:
            inlineText(block.content)
                .font(.body)
        case let .bullet(indentation):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(JournalTheme.brandPrimary)
                    .frame(width: 5, height: 5)
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
            .clipShape(RoundedRectangle(
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
            .clipShape(RoundedRectangle(
                cornerRadius: JournalTheme.Radius.small,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.small,
                    style: .continuous
                )
                .stroke(codeBlockBorder, lineWidth: 1)
            }
        case .divider:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        let pattern = #"(?<!\\)==([^=\n]+)(?<!\\)=="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return markdownText(source)
        }
        let sourceString = source as NSString
        let fullRange = NSRange(location: 0, length: sourceString.length)
        let matches = regex.matches(in: source, range: fullRange)
        guard !matches.isEmpty else { return markdownText(source) }

        var result = Text("")
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                result = result + markdownText(sourceString.substring(with: NSRange(
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
