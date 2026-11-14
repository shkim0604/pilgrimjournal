import Combine
import CoreGraphics
import Foundation
import ImageIO
import JournalGroups
import PilgrimAPI
import SwiftUI

/// Turns a picked photo into the JPEG the server accepts for `purpose` (post/comment: long edge
/// ≤ 1600, ≤ 500 KB; sticker: 256 × 256, ≤ 100 KB; metadata stripped).
typealias GroupImagePreparer =
    @Sendable (_ data: Data, _ purpose: MediaPurpose) async throws -> Data

enum GroupImagePreparation {
    /// Sends the data as is. Only for previews and tests: `PreviewGroupAPI` accepts any JPEG.
    static let identity: GroupImagePreparer = { data, _ in data }

    /// What every group screen uses unless a test injects its own. Phase 2 points this at
    /// `JournalGroups.ImageCompressor` (A1).
    @MainActor static var current: GroupImagePreparer = identity
}

/// Pixel sizes and thumbnails of encoded images, without UIKit/AppKit.
enum GroupImageMetrics {
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    /// An upright image no larger than `maxPixelSize` on its long edge.
    static func cgImage(from data: Data, maxPixelSize: Int = 1_024) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func image(from data: Data, maxPixelSize: Int = 512) -> Image? {
        cgImage(from: data, maxPixelSize: maxPixelSize).map { Image(decorative: $0, scale: 1) }
    }
}

/// A photo picked for a post or comment. `id` is also the upload `clientId`, so a retry after
/// a lost response never uploads the same photo twice.
struct GroupComposerPhoto: Identifiable, Equatable, Sendable {
    var id = UUID()
    var data: Data
    /// Set once the upload succeeded.
    var mediaID: UUID?
}

/// Prepares and uploads one photo.
struct GroupPhotoUploader: Sendable {
    let api: any GroupAPI
    let prepare: GroupImagePreparer

    func upload(_ photo: GroupComposerPhoto, purpose: MediaPurpose, groupID: UUID)
        async throws -> MediaRef
    {
        let jpeg = try await prepare(photo.data, purpose)
        guard let size = GroupImageMetrics.pixelSize(of: jpeg) else {
            throw GroupAPIError.server(.mediaInvalid)
        }
        return try await api.upload(
            GroupMediaUpload(
                clientID: photo.id, purpose: purpose, groupID: groupID, jpegData: jpeg,
                width: size.width, height: size.height))
    }
}

/// What the composer opens with. A4 fills it from an entry or the prayer-request sheet; the
/// feed's "새 글" opens it empty with only `kind` set.
struct GroupPostDraft: Equatable, Sendable {
    var kind: PostKind
    var title: String
    /// Prayer: optional. Book report and testimony: required.
    var body: String
    /// Prayer only; empty-text items are dropped.
    var items: [PrayerItem]
    var bookTitle: String
    var bookAuthor: String
    /// Book report only; sent as a leading `> ` block of `body` (the API has no quote field).
    var quote: String
    /// Prayer only. When set, the post ends three days after this day; otherwise `visibleDays`.
    var deadline: LocalDate?
    var visibleDays: Int
    /// Encoded images (any format ImageIO reads); prepared and uploaded when posting.
    var photos: [Data]

    init(
        kind: PostKind = .prayer, title: String = "", body: String = "",
        items: [PrayerItem] = [], bookTitle: String = "", bookAuthor: String = "",
        quote: String = "", deadline: LocalDate? = nil,
        visibleDays: Int = PostExpiryPolicy.defaultVisibleDays, photos: [Data] = []
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.items = items
        self.bookTitle = bookTitle
        self.bookAuthor = bookAuthor
        self.quote = quote
        self.deadline = deadline
        self.visibleDays = visibleDays
        self.photos = photos
    }
}

/// One editable prayer line.
struct GroupComposerItem: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var topic: String?
    var who: String

    init(text: String = "", topic: String? = nil, who: String = "") {
        self.text = text
        self.topic = topic
        self.who = who
    }

    init(_ item: PrayerItem) {
        self.init(text: item.text, topic: item.topic, who: item.who ?? "")
    }
}

/// Why the composer cannot post yet.
enum GroupComposerIssue: Equatable {
    case noGroup
    case titleTooLong
    case bodyRequired
    case bodyTooLong
    case itemsRequired
    case tooManyItems
    case itemTooLong
    case whoTooLong
    case bookTitleRequired
    case bookTitleTooLong
    case bookAuthorTooLong
    case tooManyPhotos
    case deadline(PostExpiryError)

    var message: String {
        switch self {
        case .noGroup: String(localized: "올릴 그룹을 골라 주세요")
        case .titleTooLong: String(localized: "제목은 80자까지 쓸 수 있어요")
        case .bodyRequired: String(localized: "내용을 써 주세요")
        case .bodyTooLong: String(localized: "내용은 2,000자까지 쓸 수 있어요")
        case .itemsRequired: String(localized: "기도제목을 한 줄 이상 써 주세요")
        case .tooManyItems: String(localized: "기도제목은 10줄까지 올릴 수 있어요")
        case .itemTooLong: String(localized: "기도제목 한 줄은 200자까지예요")
        case .whoTooLong: String(localized: "누구를 위한 기도인지는 30자까지예요")
        case .bookTitleRequired: String(localized: "책 제목을 써 주세요")
        case .bookTitleTooLong: String(localized: "책 제목은 100자까지예요")
        case .bookAuthorTooLong: String(localized: "저자 이름은 60자까지예요")
        case .tooManyPhotos: String(localized: "사진은 4장까지 붙일 수 있어요")
        case .deadline(.deadlineInPast): String(localized: "데드라인은 오늘 이후로 골라 주세요")
        case .deadline(.deadlineTooFar): String(localized: "데드라인은 1년 안으로 골라 주세요")
        case .deadline: String(localized: "데드라인과 공개 기간을 확인해 주세요")
        }
    }
}

/// The post composer: prayer requests, book reports and testimonies, with up to four photos.
///
/// A failed post keeps everything typed and picked, and a retry reuses the same `clientId` (and
/// the photos' upload IDs), so a request whose response was lost never makes a second post.
@MainActor
final class GroupComposerModel: ObservableObject {
    @Published var kind: PostKind
    @Published var title: String
    @Published var body: String
    @Published var items: [GroupComposerItem]
    @Published var bookTitle: String
    @Published var bookAuthor: String
    @Published var quote: String
    /// Prayer: a deadline instead of a visible period. The two are mutually exclusive: the
    /// request carries exactly one of them.
    @Published var usesDeadline: Bool
    @Published var deadlineDate: Date
    @Published var visibleDays: Int
    @Published private(set) var photos: [GroupComposerPhoto]
    @Published var groupID: UUID? {
        didSet { if groupID != oldValue { resetUploadIdentity() } }
    }
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?
    /// A non-blocking hint ("사진은 4장까지 붙일 수 있어요").
    @Published var notice: String?
    @Published private(set) var postedPost: PostResponse?

    /// Groups that accept new posts.
    let groups: [GroupSummary]
    let timeZone: TimeZone
    private let api: any GroupAPI
    private let uploader: GroupPhotoUploader
    private let now: () -> Date
    private let language: String
    private let policy: PostExpiryPolicy
    private let events: GroupContentEvents?
    private(set) var clientID = UUID()

    static let maxPhotos = APILimits.photosPerPost
    static let maxItems = APILimits.prayerItems.upperBound

    init(
        api: any GroupAPI,
        groups: [GroupSummary],
        groupID: UUID?,
        draft: GroupPostDraft = GroupPostDraft(),
        prepareImage: @escaping GroupImagePreparer = GroupImagePreparation.identity,
        now: @escaping () -> Date = { Date() },
        timeZone: TimeZone = .current,
        language: String = GroupComposerModel.defaultLanguage,
        policy: PostExpiryPolicy = PostExpiryPolicy(),
        events: GroupContentEvents? = .shared
    ) {
        self.api = api
        self.uploader = GroupPhotoUploader(api: api, prepare: prepareImage)
        self.groups = groups.filter { $0.status != .pendingDeletion }
        self.now = now
        self.timeZone = timeZone
        self.language = language
        self.policy = policy
        self.events = events
        kind = draft.kind
        title = draft.title
        body = draft.body
        items = draft.items.map(GroupComposerItem.init)
        bookTitle = draft.bookTitle
        bookAuthor = draft.bookAuthor
        quote = draft.quote
        usesDeadline = draft.deadline != nil
        visibleDays =
            PostExpiryPolicy.allowedVisibleDays.contains(draft.visibleDays)
            ? draft.visibleDays : PostExpiryPolicy.defaultVisibleDays
        let start = now()
        deadlineDate =
            draft.deadline.map { $0.startOfDay(in: timeZone).addingTimeInterval(12 * 3_600) }
            ?? start.addingTimeInterval(7 * 86_400)
        photos = draft.photos.prefix(Self.maxPhotos).map { GroupComposerPhoto(data: $0) }
        let writable = self.groups
        self.groupID =
            groupID.flatMap { id in writable.contains { $0.id == id } ? id : nil }
            ?? (writable.count == 1 ? writable.first?.id : nil)
        if items.isEmpty, kind == .prayer { items = [GroupComposerItem()] }
        if draft.photos.count > Self.maxPhotos {
            notice = GroupComposerIssue.tooManyPhotos.message
        }
    }

    nonisolated static var defaultLanguage: String {
        Locale.current.language.languageCode?.identifier == "en" ? "en" : "ko"
    }

    // MARK: Editing

    func addItem() {
        guard items.count < Self.maxItems else {
            notice = GroupComposerIssue.tooManyItems.message
            return
        }
        items.append(GroupComposerItem())
    }

    func removeItem(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    /// Adds picked photos up to the limit of four; the rest are dropped with a notice.
    func addPhotos(_ data: [Data]) {
        let room = Self.maxPhotos - photos.count
        if data.count > room { notice = GroupComposerIssue.tooManyPhotos.message }
        guard room > 0 else { return }
        photos.append(contentsOf: data.prefix(room).map { GroupComposerPhoto(data: $0) })
    }

    func removePhoto(_ id: UUID) {
        photos.removeAll { $0.id == id }
    }

    var canAddPhotos: Bool { photos.count < Self.maxPhotos }

    /// Today … today + 365 days, for the deadline picker.
    var deadlineRange: ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now())
        let last =
            calendar.date(byAdding: .day, value: APILimits.deadlineMaxDaysAhead, to: today)
            ?? today
        return today...last.addingTimeInterval(86_399)
    }

    // MARK: Request

    var deadline: LocalDate? {
        guard kind == .prayer, usesDeadline else { return nil }
        return LocalDate(deadlineDate, in: timeZone)
    }

    /// `visibleDays` for a prayer post without a deadline; nil otherwise.
    var requestVisibleDays: Int? {
        guard kind == .prayer, !usesDeadline else { return nil }
        return visibleDays
    }

    var filledItems: [PrayerItem] {
        items.compactMap { item in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let who = item.who.trimmingCharacters(in: .whitespacesAndNewlines)
            return PrayerItem(text: text, topic: item.topic, who: who.isEmpty ? nil : who)
        }
    }

    /// The body as sent: a book report's quote becomes a leading `> ` block.
    var composedBody: String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .bookReport, !quoted.isEmpty {
            return GroupPostQuote.compose(quote: quoted, body: text)
        }
        return text.isEmpty ? nil : text
    }

    private var trimmedTitle: String? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    func request(mediaIDs: [UUID]) -> CreatePostRequest {
        let book: BookInfo? =
            kind == .bookReport
            ? BookInfo(
                title: bookTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                author: bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty)
            : nil
        return CreatePostRequest(
            clientId: clientID, kind: kind, title: trimmedTitle, body: composedBody,
            items: kind == .prayer ? filledItems : nil, book: book, deadline: deadline,
            visibleDays: requestVisibleDays, timeZone: timeZone.identifier, language: language,
            mediaIds: mediaIDs)
    }

    /// When the post would disappear if posted now, by the same rule the server applies.
    var expiryPreview: Date? {
        try? policy.expiresAt(
            kind: kind, createdAt: now(), deadline: deadline, visibleDays: requestVisibleDays,
            timeZone: timeZone)
    }

    /// "사라지는 날: 11월 23일" text, or nil when the deadline is out of range.
    var expiryPreviewText: String? {
        guard let expiresAt = expiryPreview else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return GroupExpiryText.monthDay(
            GroupExpiryText.lastVisibleDay(expiresAt, calendar: calendar), calendar: calendar)
    }

    // MARK: Validation

    var issues: [GroupComposerIssue] {
        var issues: [GroupComposerIssue] = []
        if groupID == nil { issues.append(.noGroup) }
        if (trimmedTitle?.count ?? 0) > APILimits.postTitleMax { issues.append(.titleTooLong) }
        let bodyCount = composedBody?.count ?? 0
        if bodyCount > APILimits.postBodyMax { issues.append(.bodyTooLong) }
        if photos.count > Self.maxPhotos { issues.append(.tooManyPhotos) }
        switch kind {
        case .prayer:
            let filled = filledItems
            if filled.isEmpty { issues.append(.itemsRequired) }
            if filled.count > Self.maxItems { issues.append(.tooManyItems) }
            if filled.contains(where: { $0.text.count > APILimits.prayerItemTextMax }) {
                issues.append(.itemTooLong)
            }
            if filled.contains(where: { ($0.who?.count ?? 0) > APILimits.prayerItemWhoMax }) {
                issues.append(.whoTooLong)
            }
            if let deadline {
                do {
                    try policy.validateDeadline(deadline, now: now(), timeZone: timeZone)
                } catch let error as PostExpiryError {
                    issues.append(.deadline(error))
                } catch {}
            }
        case .bookReport:
            let book = bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if book.isEmpty { issues.append(.bookTitleRequired) }
            if book.count > APILimits.bookTitleMax { issues.append(.bookTitleTooLong) }
            if bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines).count
                > APILimits.bookAuthorMax
            {
                issues.append(.bookAuthorTooLong)
            }
            if bodyCount == 0 { issues.append(.bodyRequired) }
        case .testimony:
            if bodyCount == 0 { issues.append(.bodyRequired) }
        }
        return issues
    }

    var canSubmit: Bool { issues.isEmpty && !isSubmitting }

    /// Prayer lines naming someone else need one more confirmation before they go up.
    var needsOthersConfirmation: Bool {
        kind == .prayer && filledItems.contains { $0.who != nil }
    }

    /// Whether anything was typed or picked (closing would lose it).
    var hasContent: Bool {
        !title.isEmpty || !body.isEmpty || !quote.isEmpty || !bookTitle.isEmpty
            || !bookAuthor.isEmpty || !photos.isEmpty || !filledItems.isEmpty
    }

    // MARK: Posting

    /// Uploads the photos not uploaded yet, then posts. Returns the post, or nil with
    /// `errorMessage` set and every field kept.
    @discardableResult
    func submit() async -> PostResponse? {
        guard canSubmit, let groupID else { return nil }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            var mediaIDs: [UUID] = []
            for photo in photos {
                if let mediaID = photo.mediaID {
                    mediaIDs.append(mediaID)
                    continue
                }
                let media = try await uploader.upload(photo, purpose: .post, groupID: groupID)
                if let index = photos.firstIndex(where: { $0.id == photo.id }) {
                    photos[index].mediaID = media.id
                }
                mediaIDs.append(media.id)
            }
            let post = try await api.createPost(groupID: groupID, request(mediaIDs: mediaIDs))
            postedPost = post
            events?.send(.postCreated(post))
            return post
        } catch {
            errorMessage = GroupContentError.message(for: error)
            return nil
        }
    }

    /// Another group means other uploads: media attach to the group they were uploaded for.
    private func resetUploadIdentity() {
        clientID = UUID()
        photos = photos.map { GroupComposerPhoto(data: $0.data) }
    }
}

/// A book report's quote travels as a leading `> ` block of the body.
enum GroupPostQuote {
    static func compose(quote: String, body: String) -> String {
        let quoted = quote.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        return body.isEmpty ? quoted : "\(quoted)\n\n\(body)"
    }

    /// Splits a body back into its leading quote and the rest.
    static func split(_ body: String) -> (quote: String?, body: String) {
        var quoteLines: [Substring] = []
        var rest = body[...]
        while rest.hasPrefix(">") {
            let end = rest.firstIndex(of: "\n") ?? rest.endIndex
            var line = rest[rest.index(after: rest.startIndex)..<end]
            if line.hasPrefix(" ") { line = line.dropFirst() }
            quoteLines.append(line)
            rest = end == rest.endIndex ? rest[end...] : rest[rest.index(after: end)...]
        }
        guard !quoteLines.isEmpty else { return (nil, body) }
        let remaining = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return (quoteLines.joined(separator: "\n"), remaining)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}
