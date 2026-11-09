import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
