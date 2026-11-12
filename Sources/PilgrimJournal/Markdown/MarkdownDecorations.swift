import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
