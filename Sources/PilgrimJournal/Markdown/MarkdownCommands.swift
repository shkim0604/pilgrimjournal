import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
        .bold, .italic, .strikethrough, .heading, .bullet, .quote, .link,
    ]
}

enum MarkdownKeyboardCommand: String {
    case bold
    case italic
    case strikethrough
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
        case .strikethrough:
            return applying(MarkdownInlineFormat.strikethrough, to: text, selection: selection)
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
