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

enum EditorPalette {
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
