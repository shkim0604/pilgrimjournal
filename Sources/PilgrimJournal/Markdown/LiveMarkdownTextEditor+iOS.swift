import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(iOS)
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
            // iPad/hardware keyboards: the macOS menu bar's ⌘⇧X (the
            // `CommandMenu("Markdown")` in PilgrimJournalApp) is not
            // available on iOS, so the text view offers it itself.
            UIKeyCommand(
                title: String(localized: "취소선"),
                action: #selector(toggleStrikethrough),
                input: "x",
                modifierFlags: [.command, .shift]
            ),
        ]
    }

    @objc private func toggleStrikethrough() {
        NotificationCenter.default.post(
            name: .applyMarkdownKeyboardCommand,
            object: MarkdownKeyboardCommand.strikethrough.rawValue
        )
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
            // TextKit includes spacing below the line in the marker bounds.
            // Anchor the dot to the first line's baseline and visible letter height.
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil
            )
            let baseline = fragment.minY + layoutManager.location(forGlyphAt: glyphRange.location).y
            let markerFont =
                textStorage.attribute(
                    .font, at: bulletMatch.markerRange.location, effectiveRange: nil)
                as? UIFont ?? UIFont.preferredFont(forTextStyle: .body)
            let dot = CGRect(
                x: origin.x + marker.midX - 3,
                y: origin.y + baseline - markerFont.capHeight / 2 - 3,
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
        /// The inline spans whose markers the caret last revealed.
        private var revealedInlineSpans: Set<NSRange> = []

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
            // See the macOS coordinator's `restyleIfRevealedSpansChanged`.
            let spans = LiveMarkdownStyler.revealedInlineSpans(
                in: textView.text, selection: selection
            )
            if spans != revealedInlineSpans {
                revealedInlineSpans = spans
                scheduleStyling(for: textView)
            }
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
#endif
