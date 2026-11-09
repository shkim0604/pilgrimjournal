import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum CodeSyntaxHighlighter {
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
        let revealed = revealedInlineSpans(in: storage.string, selection: selection)

        applyInlineStyle(
            regex: MarkdownPatterns.boldAsterisks,
            trait: .bold,
            revealed: revealed,
            storage: storage
        )
        applyInlineStyle(
            regex: MarkdownPatterns.boldUnderscores,
            trait: .bold,
            revealed: revealed,
            storage: storage
        )
        applyInlineStyle(
            regex: MarkdownPatterns.italicAsterisk,
            trait: .italic,
            revealed: revealed,
            storage: storage
        )
        applyInlineStyle(
            regex: MarkdownPatterns.italicUnderscore,
            trait: .italic,
            revealed: revealed,
            storage: storage
        )
        applyRegex(MarkdownPatterns.strikethrough, to: storage) { match in
            storage.addAttribute(
                .strikethroughStyle,
                value: NSUnderlineStyle.single.rawValue,
                range: match.range(at: 1)
            )
            styleInlineMarkers(in: match, revealed: revealed, storage: storage)
        }
        applyRegex(MarkdownPatterns.highlight, to: storage) { match in
            storage.addAttribute(
                .backgroundColor,
                value: EditorPalette.highlight,
                range: match.range(at: 1)
            )
            styleInlineMarkers(in: match, revealed: revealed, storage: storage)
        }
        applyRegex(MarkdownPatterns.inlineCode, to: storage) { match in
            storage.addAttributes(
                [
                    .font: monospacedFont,
                    .backgroundColor: EditorPalette.secondaryLabel
                        .withAlphaComponent(0.12),
                ], range: match.range(at: 1))
            styleInlineMarkers(in: match, revealed: revealed, storage: storage)
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

    /// Inline formats whose markers (`**`, `*`, `__`, `_`, `~~`, `==`, `` ` ``)
    /// are hidden like heading and list prefixes, and shown dimmed only while
    /// the caret or selection touches that span, so they can still be edited.
    /// Links are not among them: hiding `](url)` would leave the URL
    /// unreachable.
    static let revealableInlinePatterns: [NSRegularExpression] = [
        MarkdownPatterns.boldAsterisks,
        MarkdownPatterns.boldUnderscores,
        MarkdownPatterns.italicAsterisk,
        MarkdownPatterns.italicUnderscore,
        MarkdownPatterns.strikethrough,
        MarkdownPatterns.highlight,
        MarkdownPatterns.inlineCode,
    ]

    /// The whole ranges (markers included) of the revealable inline spans
    /// the selection touches. A caret counts when it sits anywhere from just
    /// before the opening marker to just after the closing one. None of the
    /// patterns crosses a newline, so only the selection's own lines are
    /// searched — the editors call this on every caret move.
    static func revealedInlineSpans(in text: String, selection: NSRange?) -> Set<NSRange> {
        guard let selection else { return [] }
        let source = text as NSString
        let location = min(max(0, selection.location), source.length)
        let length = min(max(0, selection.length), source.length - location)
        let safeSelection = NSRange(location: location, length: length)
        let lines = source.lineRange(for: safeSelection)
        var spans = Set<NSRange>()
        for regex in revealableInlinePatterns {
            for match in regex.matches(in: text, range: lines) {
                let span = match.range
                let touches =
                    length == 0
                    ? location >= span.location && location <= NSMaxRange(span)
                    : NSIntersectionRange(safeSelection, span).length > 0
                if touches { spans.insert(span) }
            }
        }
        return spans
    }

    /// Hides an inline span's markers, or dims them while the span is
    /// revealed (see `revealedInlineSpans`).
    private static func styleInlineMarkers(
        in match: NSTextCheckingResult,
        revealed: Set<NSRange>,
        storage: NSTextStorage
    ) {
        guard !revealed.contains(match.range) else {
            fadeMarkers(in: match, groups: [0], excluding: [1], storage: storage)
            return
        }
        for range in subtract(match.range(at: 1), from: match.range) where range.length > 0 {
            storage.addAttributes(
                [
                    .font: hiddenMarkerFont,
                    .foregroundColor: PlatformColor.clear,
                ], range: range)
        }
    }

    private static func applyInlineStyle(
        regex: NSRegularExpression,
        trait: FontTrait,
        revealed: Set<NSRange>,
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
            styleInlineMarkers(in: match, revealed: revealed, storage: storage)
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

#if os(iOS)
private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else {
            return self
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
#endif
