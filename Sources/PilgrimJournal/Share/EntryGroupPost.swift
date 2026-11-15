import Foundation
import JournalDomain
import PilgrimAPI

extension JournalEntryRecord {
    /// Whether "그룹에 올리기" is offered for this entry (as a book report or testimony): there
    /// must be text to share, outside the trash. Callers also check that groups are on.
    var offersGroupPosting: Bool {
        !isDeleted && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Fills the group composer from one entry: a reading note becomes a book report (book title
/// and author from its details), anything else a testimony. The text keeps the entry's words
/// with its inline image lines taken out; the images come along as photos instead, inline
/// ones first in the order they appear, then the other image attachments.
///
/// Nothing is posted from here: the composer opens filled in, and the person edits, picks a
/// group and presses "올리기" (or closes it).
enum EntryGroupPostDraft {
    static func kind(for entry: JournalEntryRecord) -> PostKind {
        entry.kind.builtIn == .reading ? .bookReport : .testimony
    }

    static func draft(for entry: JournalEntryRecord, photos: [Data]) -> GroupPostDraft {
        let kind = kind(for: entry)
        return GroupPostDraft(
            kind: kind,
            title: entry.title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: text(of: entry.body),
            bookTitle: kind == .bookReport ? trimmed(entry.details.bookTitle) : "",
            bookAuthor: kind == .bookReport ? trimmed(entry.details.bookAuthor) : "",
            photos: photos)
    }

    /// `body` without its `![](attachment:…)` lines, and without the blank runs they leave.
    static func text(of body: String) -> String {
        let imageLines = Set(
            MarkdownAttachmentImageDecoration.matches(in: body).map {
                (body as NSString).substring(with: $0.markerRange)
            })
        var lines: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if imageLines.contains(String(line)) { continue }
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank, lines.last.map({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) == true
            {
                continue
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The entry's image attachments to offer as photos: the ones shown in the text first, in
    /// text order, then the rest in `attachments` order.
    static func photoAttachmentIDs(body: String, attachments: [AttachmentRecord]) -> [UUID] {
        let images = attachments.filter {
            $0.deletedAt == nil && $0.mimeType.lowercased().hasPrefix("image/")
        }
        let imageIDs = Set(images.map(\.id))
        var ordered: [UUID] = []
        for match in MarkdownAttachmentImageDecoration.matches(in: body)
        where imageIDs.contains(match.attachmentID) && !ordered.contains(match.attachmentID) {
            ordered.append(match.attachmentID)
        }
        for image in images where !ordered.contains(image.id) {
            ordered.append(image.id)
        }
        return ordered
    }

    private static func trimmed(_ text: String?) -> String {
        (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension AppModel {
    /// The composer draft for posting `entry` to a group, with its photos loaded.
    ///
    /// Loads one photo more than a post may carry, so the composer can say that only four go.
    func groupPostDraft(for entry: JournalEntryRecord) -> GroupPostDraft {
        let ids = EntryGroupPostDraft.photoAttachmentIDs(
            body: entry.body, attachments: attachments(for: entry.id))
        var photos: [Data] = []
        for id in ids {
            guard photos.count <= APILimits.photosPerPost else { break }
            if let data = attachmentData(for: id) { photos.append(data) }
        }
        return EntryGroupPostDraft.draft(for: entry, photos: photos)
    }
}
