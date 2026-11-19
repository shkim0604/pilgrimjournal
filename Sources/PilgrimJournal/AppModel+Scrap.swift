import Foundation
import JournalData
import JournalDomain
import JournalGroups
import JournalSearch
import PilgrimAPI

/// What `scrapGroupPost` did.
enum GroupScrapResult: Equatable {
    /// The new entry's ID.
    case saved(UUID)
    /// A scrap of this post is already in the journal and `saveAgain` was false: ask
    /// "이미 스크랩했어요. 한 번 더 저장할까요?" and call again with `saveAgain: true`.
    case alreadyScrapped
    /// Nothing was saved; the message says why.
    case failed(String)
}

/// Downloads a photo's bytes from a signed media URL.
typealias GroupScrapDownloader = @Sendable (URL) async throws -> Data

// MARK: - Scrap (design.md 15절)

extension AppModel {
    /// Fetches with `URLSession.shared`; anything but a 2xx answer is a failure.
    nonisolated static let urlSessionScrapDownloader: GroupScrapDownloader = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Whether the journal already holds a scrap of `postID`: an entry of the scrap kind
    /// (outside the trash) whose body carries that post's source marker.
    func hasScrapped(postID: UUID) -> Bool {
        do {
            var cursor: JournalTimelineCursor?
            repeat {
                let page = try repository.page(
                    kind: .scrap, includeDeleted: false, after: cursor, limit: 500)
                if page.entries.contains(where: {
                    ScrapMarker.contains(postID: postID, in: $0.body)
                }) {
                    return true
                }
                cursor = page.nextCursor
            } while cursor != nil
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    /// Scraps a group post with the groups controller's API, naming the notebook after the
    /// group as the sidebar has it now.
    func scrapGroupPost(_ post: PostResponse, saveAgain: Bool = false) async -> GroupScrapResult {
        guard let groups else {
            return .failed(String(localized: "그룹 서버에 연결할 수 없어요"))
        }
        let groupName = groups.groups.first { $0.id == post.groupId }?.name
        return await scrapGroupPost(
            post, groupName: groupName, using: groups.api, saveAgain: saveAgain)
    }

    /// Copies a group post, its visible comments and its photos into the user's own journal
    /// as a new entry of the scrap kind, in the notebook "스크랩 · <그룹 이름>". The server
    /// is only read from. Nothing is saved unless every photo downloaded.
    ///
    /// - The words are the post's own language (Korean if it has any Hangul, else English),
    ///   never the device's, and the notebook name is always Korean (`ScrapComposer`), so
    ///   two devices never word one scrap differently or split a group into two notebooks.
    /// - The entry always goes to this scope's own journal, never into a shared notebook,
    ///   whatever the sidebar shows.
    /// - The scrap kind appears in the catalog on the first scrap (and comes back if the user
    ///   deleted it); the notebook is created, or taken off the deleted-notebook list.
    /// - `groupName` nil asks the server for the group's name.
    func scrapGroupPost(
        _ post: PostResponse,
        groupName: String?,
        using api: any GroupAPI,
        saveAgain: Bool = false,
        download: @escaping GroupScrapDownloader = AppModel.urlSessionScrapDownloader,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> GroupScrapResult {
        if !saveAgain, hasScrapped(postID: post.id) { return .alreadyScrapped }
        guard let attachmentRepository = repository as? any AttachmentRepository else {
            return .failed(String(localized: "이 저장소에서는 첨부 파일을 사용할 수 없습니다."))
        }

        // 1. Read everything from the server.
        let comments: [CommentResponse]
        let name: String
        do {
            comments = try await Self.allComments(of: post.id, api: api)
            if let groupName {
                name = groupName
            } else {
                name = try await api.group(id: post.groupId).name
            }
        } catch {
            return .failed(GroupContentError.message(for: error))
        }
        let composition = ScrapComposer.compose(
            post: Self.scrapPost(post, groupName: name),
            comments: comments.map(Self.scrapComment))

        var media: [UUID: MediaRef] = [:]
        for ref in post.media + comments.flatMap(\.media) { media[ref.id] = ref }
        var photos: [UUID: Data] = [:]
        do {
            for attachment in composition.attachments where photos[attachment.mediaID] == nil {
                guard let ref = media[attachment.mediaID] else { throw URLError(.fileDoesNotExist) }
                photos[attachment.mediaID] = try await Self.downloadPhoto(
                    ref, api: api, download: download, now: now)
            }
        } catch {
            return .failed(String(localized: "사진을 내려받지 못했어요. 다시 시도해 주세요."))
        }

        // 2. Write the photos' files before the entry, so a failure leaves no entry behind.
        let entryID = UUID()
        let attachmentsRoot = paths.attachments
        let pending = composition.attachments.compactMap { attachment in
            photos[attachment.mediaID].map { (attachment, $0) }
        }
        let records: [(AttachmentRecord, Data)]
        do {
            records = try await Task.detached(priority: .userInitiated) {
                let store = try AttachmentFileStore(root: attachmentsRoot)
                return try pending.map { attachment, data in
                    var record = try store.store(
                        data: data, entryID: entryID, originalName: attachment.originalName,
                        mimeType: attachment.mimeType
                    ).record
                    record.id = attachment.id
                    return (record, data)
                }
            }.value
        } catch {
            return .failed(error.localizedDescription)
        }

        // 3. The kind, the notebook, then the entry and its attachments.
        materializeScrapKind()
        var draft = composition.draft
        draft.id = entryID
        draft.notebookName = createNotebook(named: composition.notebookName)
        do {
            let record = try repository.save(draft, deviceID: deviceID, at: .now)
            for (attachment, data) in records {
                var stored = attachment
                stored.state = cloudAccountMonitor == nil ? .local : .pending
                stored.updatedAt = .now
                try attachmentRepository.saveAttachment(stored, binary: data)
            }
            try searchIndex.upsert(record)
            if !records.isEmpty { attachmentRevision += 1 }
            markLocalMutation()
            refresh()
            return .saved(record.id)
        } catch {
            errorMessage = error.localizedDescription
            refresh()
            return .failed(error.localizedDescription)
        }
    }

    /// Stores the scrap kind's definition the first time (or restores it after the user
    /// deleted it), merging the iCloud catalog first like every other catalog edit.
    private func materializeScrapKind() {
        if mergeKindCatalogFromCloud() { reconcileKinds() }
        var catalog = kindCatalogStore.catalog
        let before = catalog
        catalog.materialize(.scrap, deviceID: deviceID, at: .now)
        guard catalog != before else { return }
        kindCatalogStore.save(catalog)
        kindCatalog = kindCatalogStore.catalog
        unknownKinds.removeAll { kindCatalog.isKnown($0) }
        markLocalMutation()
    }

    // MARK: Server → composer

    /// Every comment the server shows this user (hidden and blocked people's are already
    /// left out), oldest first.
    private static func allComments(of postID: UUID, api: any GroupAPI) async throws
        -> [CommentResponse]
    {
        var comments: [CommentResponse] = []
        var cursor: String?
        var seen = Set<UUID>()
        repeat {
            let page = try await api.comments(
                postID: postID, cursor: cursor, limit: Page<CommentResponse>.maximumLimit)
            for comment in page.items where seen.insert(comment.id).inserted {
                comments.append(comment)
            }
            guard page.nextCursor != cursor else { break }
            cursor = page.nextCursor
        } while cursor != nil
        return comments
    }

    /// A signed URL lasts ten minutes: an expired (or nearly expired) one is renewed first,
    /// and a failed download is retried once with a fresh URL.
    private static func downloadPhoto(
        _ ref: MediaRef, api: any GroupAPI, download: GroupScrapDownloader,
        now: () -> Date
    ) async throws -> Data {
        var url = ref.url
        var renewed = false
        if ref.urlExpiresAt <= now().addingTimeInterval(30) {
            url = try await api.mediaURL(id: ref.id).url
            renewed = true
        }
        do {
            return try await download(url)
        } catch {
            guard !renewed else { throw error }
            return try await download(api.mediaURL(id: ref.id).url)
        }
    }

    static func scrapPost(_ post: PostResponse, groupName: String) -> ScrapPost {
        let kind: ScrapPost.Kind =
            switch post.kind {
            case .prayer: .prayer
            case .bookReport: .bookReport
            case .testimony: .testimony
            }
        return ScrapPost(
            id: post.id,
            groupID: post.groupId,
            groupName: groupName,
            kind: kind,
            authorName: post.author.displayName,
            title: post.title,
            body: post.body,
            items: (post.items ?? []).map {
                ScrapPost.PrayerLine(text: $0.text, topic: $0.topic, section: $0.section)
            },
            book: post.book.map { ScrapPost.Book(title: $0.title, author: $0.author) },
            deadline: post.deadline.map {
                ScrapPost.Day(year: $0.year, month: $0.month, day: $0.day)
            },
            createdAt: post.createdAt,
            timeZoneIdentifier: post.timeZone,
            photoIDs: post.media.map(\.id))
    }

    static func scrapComment(_ comment: CommentResponse) -> ScrapComment {
        ScrapComment(
            authorName: comment.author.displayName,
            body: comment.body,
            createdAt: comment.createdAt,
            photoIDs: comment.media.map(\.id),
            hasSticker: comment.sticker != nil || comment.stickerRemoved)
    }

}
