import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

func clamped(_ range: NSRange, to length: Int) -> NSRange {
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
