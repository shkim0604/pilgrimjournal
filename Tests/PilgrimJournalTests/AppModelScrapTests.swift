#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
import JournalGroups
import JournalSearch
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

/// Counts photo downloads and can be told to fail.
private final class FakePhotoServer: @unchecked Sendable {
    private let lock = NSLock()
    private var downloads: [URL] = []
    private let data: Data
    var fails = false

    init(data: Data) { self.data = data }

    var downloadCount: Int { lock.withLock { downloads.count } }

    var download: GroupScrapDownloader {
        { [self] url in
            try lock.withLock {
                if fails { throw URLError(.notConnectedToInternet) }
                downloads.append(url)
                return data
            }
        }
    }
}

@MainActor
final class AppModelScrapTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-scrap-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel(
        repository: InMemoryJournalRepository = InMemoryJournalRepository()
    ) throws -> AppModel {
        let paths = JournalPaths(root: root.appending(path: UUID().uuidString))
        try paths.prepare()
        return AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: try JournalSearchIndex(url: paths.search.appending(path: "index.sqlite")),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: UserDefaults(suiteName: "pilgrim-scrap-\(UUID().uuidString)")!)
    }

    /// A prayer request with two photos and one comment in 수요 기도모임.
    private func prayerPost(_ fixture: GroupsContentFixture) async throws -> PostResponse {
        let jpeg = try GroupsContentFixture.jpeg(width: 800, height: 600)
        var mediaIDs: [UUID] = []
        for _ in 0..<2 {
            let media = try await fixture.api.upload(
                GroupMediaUpload(
                    clientID: UUID(), purpose: .post, groupID: fixture.wednesday.id,
                    jpegData: jpeg, width: 800, height: 600))
            mediaIDs.append(media.id)
        }
        let post = try await fixture.api.createPost(
            groupID: fixture.wednesday.id,
            CreatePostRequest(
                clientId: UUID(), kind: .prayer,
                items: [PrayerItem(text: "어머니 검사 결과가 좋게 나오도록", topic: "health", who: "엄마")],
                deadline: LocalDate(year: 2025, month: 11, day: 20),
                timeZone: GroupsContentFixture.seoul.identifier, mediaIds: mediaIDs))
        _ = try await fixture.api.createComment(
            postID: post.id, CreateCommentRequest(clientId: UUID(), body: "함께 기도할게요"))
        return post
    }

    private func scrap(
        _ model: AppModel, _ post: PostResponse, _ fixture: GroupsContentFixture,
        server: FakePhotoServer, groupName: String? = "수요 기도모임", saveAgain: Bool = false
    ) async -> GroupScrapResult {
        let clock = fixture.clock
        return await model.scrapGroupPost(
            post, groupName: groupName, using: fixture.api, saveAgain: saveAgain,
            download: server.download, now: { clock.now })
    }

    private func savedID(_ result: GroupScrapResult) throws -> UUID {
        guard case .saved(let id) = result else {
            XCTFail("expected a saved scrap, got \(result)")
            throw CancellationError()
        }
        return id
    }

    func testFirstScrapAddsKindNotebookEntryAndPhotos() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))
        XCTAssertFalse(model.sidebarKinds.contains { $0.kind == .scrap })
        XCTAssertFalse(model.hasScrapped(postID: post.id))

        let id = try savedID(await scrap(model, post, fixture, server: server))

        let entry = try XCTUnwrap(repository.entry(id: id))
        XCTAssertEqual(entry.kind, .scrap)
        XCTAssertEqual(entry.title, "\(post.author.displayName)의 기도제목")
        XCTAssertEqual(entry.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(entry.occurredAt, post.createdAt)
        XCTAssertEqual(entry.originalTimeZone, "Asia/Seoul")
        XCTAssertTrue(entry.body.hasPrefix("> 스크랩 · 수요 기도모임\n"))
        XCTAssertTrue(entry.body.contains(ScrapMarker.line(groupID: post.groupId, postID: post.id)))
        XCTAssertTrue(entry.body.contains("- 어머니 검사 결과가 좋게 나오도록 (엄마/건강)"))
        XCTAssertTrue(entry.body.contains("함께 기도할게요"))
        XCTAssertNil(entry.sourceUUID)

        let attachments = model.attachments(for: id)
        XCTAssertEqual(attachments.count, 2)
        for attachment in attachments {
            XCTAssertTrue(entry.body.contains("![](attachment:\(attachment.id.uuidString))"))
            XCTAssertEqual(attachment.mimeType, "image/jpeg")
            XCTAssertNotNil(model.attachmentData(for: attachment.id))
        }
        XCTAssertEqual(server.downloadCount, 2)

        // The kind appeared, last before 미분류, but is not offered for new entries.
        XCTAssertEqual(model.sidebarKinds.last?.kind, .unclassified)
        XCTAssertEqual(model.sidebarKinds.dropLast().last?.kind, .scrap)
        XCTAssertFalse(model.kindCatalog.creatableKinds.contains { $0.kind == .scrap })
        XCTAssertFalse(model.kindPickerOptions().contains { $0.kind == .scrap })
        XCTAssertEqual(model.defaultKindForNewEntry, .diary)
        XCTAssertTrue(model.notebooks.contains("스크랩 · 수요 기도모임"))
        XCTAssertTrue(model.hasScrapped(postID: post.id))
        let hits = try model.searchIndex.search(JournalSearchQuery(text: "검사 결과"))
        XCTAssertEqual(hits.map(\.id), [id])
    }

    func testScrappingTheSamePostAgainAsksFirst() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))
        _ = try savedID(await scrap(model, post, fixture, server: server))

        let again = await scrap(model, post, fixture, server: server)
        XCTAssertEqual(again, .alreadyScrapped)
        XCTAssertEqual(server.downloadCount, 2, "asking downloads nothing")

        _ = try savedID(await scrap(model, post, fixture, server: server, saveAgain: true))
        XCTAssertEqual(
            try repository.list(kind: .scrap, includeDeleted: false, limit: 10).count, 2)
    }

    func testPostLanguageNotDeviceLanguagePicksTheWordsAndOneNotebookServesBoth() async throws {
        let fixture = try await GroupsContentFixture()
        let korean = try await prayerPost(fixture)
        let english = try await fixture.api.createPost(
            groupID: fixture.wednesday.id,
            CreatePostRequest(
                clientId: UUID(), kind: .prayer,
                items: [PrayerItem(text: "Pray for my interview this week", topic: "work")],
                timeZone: GroupsContentFixture.seoul.identifier))
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))

        let koreanID = try savedID(await scrap(model, korean, fixture, server: server))
        let englishID = try savedID(await scrap(model, english, fixture, server: server))

        let englishEntry = try XCTUnwrap(repository.entry(id: englishID))
        XCTAssertEqual(englishEntry.title, "\(english.author.displayName)'s prayer requests")
        XCTAssertTrue(englishEntry.body.hasPrefix("> Scraps · 수요 기도모임\n"), englishEntry.body)
        XCTAssertTrue(englishEntry.body.contains(" · Prayer requests · Posted on "))
        XCTAssertTrue(englishEntry.body.contains("- Pray for my interview this week (work)"))
        XCTAssertEqual(
            try repository.entry(id: koreanID)?.title, "\(korean.author.displayName)의 기도제목")
        // Both languages land in the one Korean-named notebook.
        XCTAssertEqual(englishEntry.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(try repository.entry(id: koreanID)?.notebookName, "스크랩 · 수요 기도모임")
        XCTAssertEqual(model.notebooks.filter { $0.contains("수요 기도모임") }, ["스크랩 · 수요 기도모임"])
        XCTAssertEqual(model.kindCatalog.definition(for: .scrap).name, "스크랩")
    }

    func testPreviouslyDeletedNotebookComesBack() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let model = try makeModel()
        XCTAssertEqual(model.createNotebook(named: "스크랩 · 수요 기도모임"), "스크랩 · 수요 기도모임")
        XCTAssertTrue(model.deleteNotebook(named: "스크랩 · 수요 기도모임"))
        XCTAssertTrue(model.deletedNotebookNames.contains("스크랩 · 수요 기도모임"))

        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))
        let id = try savedID(await scrap(model, post, fixture, server: server))

        XCTAssertTrue(model.notebooks.contains("스크랩 · 수요 기도모임"))
        XCTAssertFalse(model.deletedNotebookNames.contains("스크랩 · 수요 기도모임"))
        XCTAssertEqual(model.entryRecord(id: id)?.notebookName, "스크랩 · 수요 기도모임")
        model.selectNotebook("스크랩 · 수요 기도모임")
        XCTAssertEqual(model.entries.map(\.id), [id])
    }

    func testGroupNameComesFromTheServerWhenNotGiven() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let model = try makeModel()
        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))
        let id = try savedID(await scrap(model, post, fixture, server: server, groupName: nil))
        XCTAssertEqual(
            model.entryRecord(id: id)?.notebookName, "스크랩 · \(fixture.wednesday.name)")
    }

    func testScrapAlwaysGoesToTheOwnJournal() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        // A new entry would go into a shared notebook right now.
        model.newEntrySharedSpaceID = UUID()

        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))
        let id = try savedID(await scrap(model, post, fixture, server: server))

        XCTAssertEqual(try repository.entry(id: id)?.kind, .scrap)
    }

    func testFailedPhotoDownloadSavesNothing() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let catalog = model.kindCatalog
        let notebooks = model.notebooks
        let server = FakePhotoServer(data: Data())
        server.fails = true

        let result = await scrap(model, post, fixture, server: server)

        guard case .failed = result else { return XCTFail("expected failure, got \(result)") }
        XCTAssertTrue(try repository.list(kind: nil, includeDeleted: true, limit: 10).isEmpty)
        XCTAssertEqual(model.kindCatalog, catalog, "the kind appears only with a scrap")
        XCTAssertEqual(model.notebooks, notebooks)
    }

    func testDeletedScrapKindIsRestoredByTheNextScrap() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let repository = InMemoryJournalRepository()
        let model = try makeModel(repository: repository)
        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))
        let first = try savedID(await scrap(model, post, fixture, server: server))

        try model.deleteKind(.scrap, moveTo: .memo)
        XCTAssertEqual(try repository.entry(id: first)?.kind, .memo)
        XCTAssertFalse(model.sidebarKinds.contains { $0.kind == .scrap })
        XCTAssertEqual(model.kindCatalog.deletedBuiltIns.map(\.kind), [.scrap])

        // The moved entry is no longer a scrap, so this one is not a repeat.
        let second = try savedID(await scrap(model, post, fixture, server: server))
        XCTAssertEqual(try repository.entry(id: second)?.kind, .scrap)
        XCTAssertTrue(model.sidebarKinds.contains { $0.kind == .scrap })
        XCTAssertTrue(model.kindCatalog.deletedBuiltIns.isEmpty)
    }

    func testScrapKindTakesTheAlternateNameWhenScrapIsTaken() async throws {
        let fixture = try await GroupsContentFixture()
        let post = try await prayerPost(fixture)
        let model = try makeModel()
        let mine = try model.createKind(name: "스크랩", colorToken: .rose, iconToken: "tag")
        let server = FakePhotoServer(data: try GroupsContentFixture.jpeg(width: 800, height: 600))

        _ = try savedID(await scrap(model, post, fixture, server: server))

        XCTAssertEqual(model.kindCatalog.definition(for: .scrap).name, "그룹 스크랩")
        XCTAssertEqual(model.kindCatalog.definition(for: mine).name, "스크랩")
    }

    func testExistingUsersCatalogIsUntouchedUntilTheFirstScrap() throws {
        let model = try makeModel()
        model.refresh()
        XCTAssertEqual(
            model.sidebarKinds.map(\.kind),
            [.prayer, .bibleStudy, .reading, .diary, .memo, .unclassified])
        XCTAssertEqual(model.kindCatalog, KindCatalog())
        XCTAssertTrue(model.kindCatalogStore.catalog.definitions.isEmpty)
    }
}
#endif
