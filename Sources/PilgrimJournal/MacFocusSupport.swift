import JournalDomain
import SwiftUI

#if os(macOS)
import AppKit
#endif

#if os(macOS)
@MainActor
enum MacNavigationSplitFocus {
    /// Hides the middle (timeline) column of the journal's split view.
    ///
    /// SwiftUI cannot hide that column itself on macOS (see
    /// `FocusModeLayoutPolicy`), and it never re-shows it on its own, so a
    /// plain `isHidden` on the arranged subview holds across detail swaps.
    /// Because it mutates AppKit's split view hierarchy directly and outside
    /// SwiftUI's diffing, it must never touch a view that isn't actually
    /// still attached to the key window — SwiftUI can swap the whole detail
    /// column's content (e.g. a fresh `InlineEntryEditorView` from a
    /// new-entry action) around the same moment this runs, and mutating a
    /// torn-down hierarchy is exactly the kind of thing that produces a
    /// hard-to-reproduce AppKit crash.
    static func setTimelineHidden(_ hidden: Bool) {
        guard let keyWindow = NSApp.keyWindow,
            let contentView = keyWindow.contentView
        else { return }
        splitViews(below: contentView)
            .filter {
                $0.window === keyWindow
                    && $0.isVertical
                    && $0.arrangedSubviews.count == 3
            }
            .forEach { splitView in
                let timeline = splitView.arrangedSubviews[1]
                guard timeline.window === keyWindow,
                    timeline.isHidden != hidden
                else { return }
                timeline.isHidden = hidden
                splitView.needsLayout = true
                splitView.layoutSubtreeIfNeeded()
            }
    }

    private static func splitViews(below view: NSView) -> [NSSplitView] {
        var matches = view.subviews.flatMap(splitViews(below:))
        if let splitView = view as? NSSplitView {
            matches.insert(splitView, at: 0)
        }
        return matches
    }
}

@MainActor
enum MacSearchFocus {
    static var isFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }
        if responder is NSSearchField { return true }
        return (responder as? NSTextView)?.delegate is NSSearchField
    }

    static func focus() {
        guard let window = NSApp.keyWindow,
            let contentView = window.contentView,
            let searchField = firstSearchField(in: contentView)
        else { return }
        window.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    static func clearFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private static func firstSearchField(in view: NSView) -> NSSearchField? {
        if let searchField = view as? NSSearchField { return searchField }
        return view.subviews.lazy.compactMap(firstSearchField(in:)).first
    }
}

extension Notification.Name {
    static let toggleJournalFocusMode = Notification.Name(
        "PilgrimJournal.toggleFocusMode"
    )
    static let toggleJournalSidebar = Notification.Name(
        "PilgrimJournal.toggleSidebar"
    )
    static let focusJournalSearch = Notification.Name(
        "PilgrimJournal.focusSearch"
    )
    static let navigateToPreviousJournalEntry = Notification.Name(
        "PilgrimJournal.navigateToPreviousEntry"
    )
    static let navigateToNextJournalEntry = Notification.Name(
        "PilgrimJournal.navigateToNextEntry"
    )
}
#endif
