import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS)
@MainActor
enum MacMarkdownEditorFocus {
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
        if context.coordinator.isOpeningTextEcho(text, current: textView.string) { return }
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
        /// The inline spans whose markers the caret last revealed.
        private var revealedInlineSpans: Set<NSRange> = []
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

        // A layout update can still carry the opening text after the first edit.
        // Once SwiftUI supplies a newer value, restoring the opening revision
        // must again be treated as an external edit.
        private var openingText: String?

        func isOpeningTextEcho(_ incoming: String, current: String) -> Bool {
            guard let openingText else { return false }
            if incoming != openingText {
                self.openingText = nil
                return false
            }
            return !publishedHistory.isEmpty && incoming != current
        }

        init(parent: LiveMarkdownTextEditor) {
            self.parent = parent
            openingText = parent.text
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
            restyleIfRevealedSpansChanged(in: textView, selection: selection)
        }

        /// Inline markers show only while the caret touches their span, so a
        /// caret move into or out of one needs a styling pass. It goes through
        /// the same debounced `scheduleStyling` typing uses — never a
        /// synchronous restyle here, which could land between keystrokes.
        private func restyleIfRevealedSpansChanged(in textView: NSTextView, selection: NSRange) {
            let spans = LiveMarkdownStyler.revealedInlineSpans(
                in: textView.string, selection: selection
            )
            guard spans != revealedInlineSpans else { return }
            revealedInlineSpans = spans
            scheduleStyling(for: textView)
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
#endif
