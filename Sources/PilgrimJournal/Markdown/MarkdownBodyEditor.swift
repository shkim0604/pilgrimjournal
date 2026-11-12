import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The buttons shown above the keyboard while the iPhone body is edited.
///
/// SwiftUI's `.toolbar(placement: .keyboard)` only attaches to SwiftUI text
/// inputs, so the body's UIKit text view never showed it. The iPhone editor
/// passes the same items down through the environment
/// (`markdownKeyboardAccessory`) and the text view shows them in a
/// `UIToolbar` of its own.
struct MarkdownKeyboardAccessory {
    struct Item {
        var title: String
        /// `nil` shows `title` as a text button.
        var systemImage: String?
        var action: () -> Void
    }

    var leading: [Item]
    /// Placed after a flexible space.
    var trailing: [Item]

    var items: [Item] { leading + trailing }

    /// What is on screen. The editor rebuilds this value (closures included)
    /// on every render, so the toolbar is only rebuilt when this changes.
    var signature: [String] {
        leading.map(Self.key) + ["|"] + trailing.map(Self.key)
    }

    private static func key(_ item: Item) -> String {
        "\(item.title)\u{1F}\(item.systemImage ?? "")"
    }
}

private struct MarkdownKeyboardAccessoryKey: EnvironmentKey {
    static var defaultValue: MarkdownKeyboardAccessory? { nil }
}

extension EnvironmentValues {
    var markdownKeyboardAccessory: MarkdownKeyboardAccessory? {
        get { self[MarkdownKeyboardAccessoryKey.self] }
        set { self[MarkdownKeyboardAccessoryKey.self] = newValue }
    }
}

/// Where a photo the person asked to put into the body comes from.
enum AttachmentPhotoSource {
    case library
    case camera
}

/// Lets views outside the body editor — the 첨부 section — put an image they
/// just stored into the body. The editor's coordinator does the insertion,
/// through the same `replaceExternalText` path as a pasted image, so it
/// undoes and is recorded as the editor's own text like every other
/// programmatic edit (see docs/known-issues.md, 편집기 입력이 씹힌다). Only the
/// iPhone editor connects one; elsewhere `insertImage` reports `false`.
@MainActor
final class MarkdownImageInserter {
    var handler: ((UUID, Data) -> Bool)?

    @discardableResult
    func insertImage(id: UUID, data: Data) -> Bool {
        handler?(id, data) ?? false
    }
}

struct MarkdownBodyEditor: View {
    @Binding var text: String
    var minHeight: CGFloat = 240
    var autoFocus = false
    var storeImageAttachment: ((Data, String, String) async -> UUID?)?
    var attachmentImage: ((UUID) async -> Data?)?
    /// Bumped whenever any attachment's state changes (e.g. a background
    /// CloudKit download finishes). Lets the editor retry attachments it
    /// previously failed to load, without needing to reopen the entry.
    var attachmentRevision = 0
    /// The Markdown menu row and the slash-command hint. Focus mode hides these
    /// while keeping the text editor mounted.
    var showsChrome = true
    /// iPhone only: see `MarkdownImageInserter`.
    var imageInserter: MarkdownImageInserter?
    /// iPhone only: the edit menu's 사진 삽입 asks for a photo through this.
    var requestImageInsertion: ((AttachmentPhotoSource) -> Void)?
    @State private var selection = NSRange(location: 0, length: 0)
    @AppStorage(EditorTextScale.storageKey) private var editorTextScale =
        EditorTextScale.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Conditional siblings keep `LiveMarkdownTextEditor` at the same
            // structural position, so toggling the chrome never re-creates
            // the text view (and never drops keystrokes in flight).
            if showsChrome {
                markdownMenuRow
            }

            liveEditor
                .frame(
                    maxWidth: .infinity,
                    minHeight: minHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .accessibilityLabel("Markdown 본문")

            Color.clear
                .frame(width: 0, height: 0)
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: .applyMarkdownKeyboardCommand
                    )
                ) { notification in
                    guard let rawValue = notification.object as? String,
                        let command = MarkdownKeyboardCommand(rawValue: rawValue)
                    else { return }
                    #if os(macOS)
                    guard MacMarkdownEditorFocus.isFocused else { return }
                    #endif
                    apply(command)
                }

            if let query = MarkdownCommandProcessor.trailingSlashQuery(in: text) {
                commandPalette(query: query)
            }

            if showsChrome {
                Text("/ 입력으로 제목, 목록, 체크리스트, 인용, 코드와 날짜 삽입")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var markdownMenuRow: some View {
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
                                "\(command.trigger)  \(command.displayTitle)",
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

            // The selection buttons take this label's place: in a narrow
            // editor column both together don't fit, and the label wrapped
            // into a one-letter-wide column.
            if selection.length == 0 {
                Label("입력 즉시 서식 표시", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var liveEditor: LiveMarkdownTextEditor {
        var editor = LiveMarkdownTextEditor(
            text: $text,
            selection: $selection,
            autoFocus: autoFocus,
            textScale: editorTextScale,
            storeImageAttachment: storeImageAttachment,
            attachmentImage: attachmentImage,
            attachmentRevision: attachmentRevision
        )
        editor.minimumHeight = minHeight
        #if os(iOS)
        editor.imageInserter = imageInserter
        editor.requestImageInsertion = requestImageInsertion
        #endif
        return editor
    }

    private func apply(_ format: MarkdownInlineFormat) {
        let result = MarkdownCommandProcessor.applying(
            format,
            to: text,
            selection: selection
        )
        text = result.text
        selection =
            result.selectionUTF16Range
            ?? NSRange(location: result.cursorUTF16Offset, length: 0)
    }

    private func apply(_ command: MarkdownKeyboardCommand) {
        let result = MarkdownCommandProcessor.applyingKeyboardCommand(
            command,
            to: text,
            selection: selection
        )
        text = result.text
        selection =
            result.selectionUTF16Range
            ?? NSRange(location: result.cursorUTF16Offset, length: 0)
    }

    @ViewBuilder
    private func commandPalette(query: String) -> some View {
        let matches = MarkdownSlashCommand.allCases.filter {
            query.isEmpty
                || $0.rawValue.localizedCaseInsensitiveContains(query)
                || $0.title.localizedCaseInsensitiveContains(query)
                || $0.displayTitle.localizedCaseInsensitiveContains(query)
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
                        let result =
                            MarkdownCommandProcessor
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
                            Text(command.displayTitle)
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
            .clipShape(
                RoundedRectangle(
                    cornerRadius: JournalTheme.Radius.medium,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: JournalTheme.Radius.medium)
                    .stroke(JournalTheme.separator, lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Markdown 명령")
        }
    }
}
