#if canImport(XCTest)
import Foundation
import JournalData
import JournalDomain
import JournalGroups
import JournalSearch
import PilgrimAPI
@testable import PilgrimJournal
import XCTest

/// "기도노트에서 가져오기" in the group composer, and the answered marks that follow.
@MainActor
final class GroupPrayerImportTests: XCTestCase {
    private var root: URL!
    private var suiteName = ""
    private var repository: InMemoryJournalRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(
            path: "pilgrim-prayer-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        suiteName = "pilgrim-prayer-import-\(UUID().uuidString)"
        repository = InMemoryJournalRepository()
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func note(
        _ topics: [PrayerTopic], categories: [String] = [], title: String = "노트",
        at date: Date = GroupsContentFixture.start
    ) throws -> JournalEntryRecord {
        try repository.save(
            JournalEntryDraft(
                kind: .prayer, title: title, occurredAt: date,
                details: EntryDetails(prayerTopics: topics, prayerCategories: categories)),
            deviceID: "test", at: date)
    }

    private func composer(
        _ fixture: GroupsContentFixture, api: (any GroupAPI)? = nil,
        prayerNotes: GroupPrayerNoteSource? = nil
    ) -> GroupComposerModel {
        GroupComposerModel(
            api: api ?? fixture.api, groups: [fixture.wednesday], groupID: fixture.wednesday.id,
            now: { [clock = fixture.clock] in clock.now }, timeZone: GroupsContentFixture.seoul,
            language: "ko", events: fixture.events, prayerNotes: prayerNotes)
    }

    /// A journal whose groups talk to `api` and whose links use the fixture's clock.
    private func appModel(_ fixture: GroupsContentFixture, api: any GroupAPI) throws -> AppModel {
        let paths = JournalPaths(root: root.appending(path: UUID().uuidString))
        try paths.prepare()
        let defaults = UserDefaults(suiteName: suiteName)!
        let model = AppModel(
            repository: repository,
            importStore: InMemoryImportStore(),
            searchIndex: try JournalSearchIndex(url: paths.search.appending(path: "index.sqlite")),
            paths: paths,
            cloudAccountMonitor: nil,
            notebookDefaults: defaults)
        model.groupPrayerLinks = GroupPrayerLinkStore(
            defaults: defaults, cloudStore: nil, now: { [clock = fixture.clock] in clock.now })
        model.groups = GroupsMembershipFixtures.controller(api: api)
        return model
    }

    private func answeredCalls(_ api: ScriptedGroupAPI) async -> Int {
        await api.calls.filter { $0.hasPrefix("setPrayerItemAnswered") }.count
    }

    private func status(_ entryID: UUID, _ topicID: UUID) throws -> PrayerStatus? {
        try repository.entry(id: entryID)?.details.prayerTopics?.first { $0.id == topicID }?
            .status
    }

    // MARK: Composer

    func testNoteGroupsTopicsBySectionInTheNotesOrder() throws {
        let family = PrayerTopic(text: "아버지 건강", category: "가족")
        let loose = PrayerTopic(text: "이번 주 면접")
        let thanks = PrayerTopic(text: "새 직장", status: .answered, category: "감사")
        let family2 = PrayerTopic(text: "동생 진로", category: "가족")
        let record = try note([family, loose, thanks, family2], categories: ["감사", "가족"])

        let note = GroupPrayerNote(record)
        XCTAssertEqual(note.sections.map(\.name), [nil, "감사", "가족"])
        XCTAssertEqual(
            note.sections.map { $0.topics.map(\.id) },
            [
                [loose.id], [thanks.id], [family.id, family2.id],
            ])
        XCTAssertEqual(note.ongoingCount, 3)
        XCTAssertEqual(note.answeredCount, 1)
    }

    func testImportReplacesThePlaceholderAndKeepsSources() async throws {
        let fixture = try await GroupsContentFixture()
        let family = PrayerTopic(text: "아버지 건강", category: "가족")
        let loose = PrayerTopic(text: "이번 주 면접")
        let thanks = PrayerTopic(text: "새 직장", status: .answered, category: "감사")
        let record = try note([family, loose, thanks], categories: ["감사", "가족"])
        let model = composer(fixture)
        XCTAssertEqual(model.items.count, 1, "the empty placeholder")

        model.importTopics([family.id, loose.id], from: GroupPrayerNote(record))

        XCTAssertEqual(model.sections.map(\.name), ["", "가족"])
        XCTAssertEqual(model.items.map(\.text), ["이번 주 면접", "아버지 건강"])
        XCTAssertEqual(
            model.items.map(\.source),
            [
                GroupPrayerTopicSource(entryID: record.id, topicID: loose.id),
                GroupPrayerTopicSource(entryID: record.id, topicID: family.id),
            ])
        XCTAssertEqual(model.filledItems.map(\.section), [nil, "가족"])
        XCTAssertNil(model.notice)

        // Importing again skips what is already there and joins an existing section.
        model.importTopics([family.id, thanks.id], from: GroupPrayerNote(record))
        XCTAssertEqual(model.sections.map(\.name), ["", "가족", "감사"])
        XCTAssertEqual(model.items.map(\.text), ["이번 주 면접", "아버지 건강", "새 직장"])
    }

    func testImportStopsAtTenLinesWithTheNotice() async throws {
        let fixture = try await GroupsContentFixture()
        let topics = (1...12).map { PrayerTopic(text: "기도제목 \($0)") }
        let record = try note(topics)
        let model = composer(fixture)
        model.sections[0].items[0].text = "직접 쓴 줄"

        model.importTopics(Set(topics.map(\.id)), from: GroupPrayerNote(record))

        XCTAssertEqual(model.items.count, GroupComposerModel.maxItems)
        XCTAssertEqual(model.items.first?.text, "직접 쓴 줄", "typed lines stay")
        XCTAssertEqual(model.items.last?.text, "기도제목 9")
        XCTAssertEqual(model.notice, GroupComposerIssue.tooManyItems.message)
    }

    func testFilledSourcesUseThePostedIndexes() async throws {
        let fixture = try await GroupsContentFixture()
        let first = PrayerTopic(text: "첫째")
        let second = PrayerTopic(text: "둘째", category: "가족")
        let record = try note([first, second], categories: ["가족"])
        var posted: (PostResponse, [Int: GroupPrayerTopicSource])?
        let model = composer(
            fixture,
            prayerNotes: GroupPrayerNoteSource(
                notes: { [] }, didPost: { posted = ($0, $1) }))
        model.importTopics([first.id, second.id], from: GroupPrayerNote(record))
        // A typed line and an empty one before the imported lines.
        model.sections[0].items.insert(GroupComposerItem(text: "직접"), at: 0)
        model.sections[0].items.insert(GroupComposerItem(), at: 1)

        XCTAssertEqual(model.filledItems.map(\.text), ["직접", "첫째", "둘째"])
        XCTAssertEqual(
            model.filledSources,
            [
                1: GroupPrayerTopicSource(entryID: record.id, topicID: first.id),
                2: GroupPrayerTopicSource(entryID: record.id, topicID: second.id),
            ])

        let submitted = await model.submit()
        let post = try XCTUnwrap(submitted)
        let (reported, sources) = try XCTUnwrap(posted)
        XCTAssertEqual(reported.id, post.id)
        XCTAssertEqual(sources, model.filledSources)
        XCTAssertEqual(post.items?[1].text, "첫째")
        XCTAssertEqual(post.items?[2].text, "둘째")
        XCTAssertEqual(post.items?[2].section, "가족")
    }

    // MARK: Answered sync

    func testJournalToggleMarksOnlyLinkedLines() async throws {
        let fixture = try await GroupsContentFixture()
        let api = ScriptedGroupAPI(base: fixture.api)
        let model = try appModel(fixture, api: api)
        let linked = PrayerTopic(text: "면접")
        let other = PrayerTopic(text: "건강")
        let record = try note([linked, other])
        // Posted through the composer with only `linked` imported.
        let source = model.groupPrayerNoteSource
        let notes = source.notes()
        XCTAssertEqual(notes.map(\.id), [record.id])
        let composer = composer(fixture, api: api, prayerNotes: source)
        composer.importTopics([linked.id], from: try XCTUnwrap(notes.first))
        composer.addItem()
        composer.sections[0].items[1].text = "건강"
        let submitted = await composer.submit()
        let post = try XCTUnwrap(submitted)
        XCTAssertEqual(
            model.groupPrayerLinks.links().map(\.itemIndex), [0], "only the imported line")

        model.setPrayerTopicStatus(entryID: record.id, topicID: other.id, status: .answered)
        await model.groupPrayerSyncTask?.value
        let callsAfterOther = await answeredCalls(api)
        XCTAssertEqual(callsAfterOther, 0, "an unlinked topic stays off the server")

        model.setPrayerTopicStatus(entryID: record.id, topicID: linked.id, status: .answered)
        await model.groupPrayerSyncTask?.value
        let callsAfterLinked = await answeredCalls(api)
        XCTAssertEqual(callsAfterLinked, 1)
        let server = try await fixture.api.post(id: post.id)
        XCTAssertNotNil(server.items?[0].answeredAt)
        XCTAssertNil(server.items?[1].answeredAt)

        model.setPrayerTopicStatus(entryID: record.id, topicID: linked.id, status: .ongoing)
        await model.groupPrayerSyncTask?.value
        let undone = try await fixture.api.post(id: post.id)
        XCTAssertNil(undone.items?[0].answeredAt)
    }

    func testDetailToggleMarksTheLinkedTopicWithoutASecondCall() async throws {
        let fixture = try await GroupsContentFixture()
        let api = ScriptedGroupAPI(base: fixture.api)
        let model = try appModel(fixture, api: api)
        let topic = PrayerTopic(text: "면접")
        let record = try note([topic])
        let post = try await fixture.api.createPost(
            groupID: fixture.wednesday.id,
            CreatePostRequest(
                clientId: UUID(), kind: .prayer, items: [PrayerItem(text: "면접")],
                visibleDays: 3, timeZone: GroupsContentFixture.seoul.identifier))
        model.linkPostedPrayerItems(
            post, sources: [0: GroupPrayerTopicSource(entryID: record.id, topicID: topic.id)])
        let detail = GroupPostDetailModel(
            api: api, postID: post.id, groupID: post.groupId, isAdmin: false,
            events: fixture.events, onAnsweredChange: model.groups?.onPrayerItemAnswered)
        await detail.load()

        await detail.toggleAnswered(index: 0)
        await model.groupPrayerSyncTask?.value
        XCTAssertEqual(try status(record.id, topic.id), .answered)
        let calls = await answeredCalls(api)
        XCTAssertEqual(calls, 1, "only the detail's own call")
        // The mark kept the post longer; the link follows.
        XCTAssertEqual(
            model.groupPrayerLinks.links().first?.expiresAt, detail.post?.expiresAt)

        await detail.toggleAnswered(index: 0)
        await model.groupPrayerSyncTask?.value
        XCTAssertEqual(try status(record.id, topic.id), .ongoing)
        let callsAfterUndo = await answeredCalls(api)
        XCTAssertEqual(callsAfterUndo, 2)
    }

    func testFeedRefreshMarksLinesAnsweredInTheJournalOnly() async throws {
        let fixture = try await GroupsContentFixture()
        let api = ScriptedGroupAPI(base: fixture.api)
        let model = try appModel(fixture, api: api)
        let answeredHere = PrayerTopic(text: "하나", status: .answered, answeredAt: fixture.clock.now)
        let same = PrayerTopic(text: "둘")
        let answeredThere = PrayerTopic(text: "셋")
        let record = try note([answeredHere, same, answeredThere])
        let post = try await fixture.api.createPost(
            groupID: fixture.wednesday.id,
            CreatePostRequest(
                clientId: UUID(), kind: .prayer,
                items: [PrayerItem(text: "하나"), PrayerItem(text: "둘"), PrayerItem(text: "셋")],
                visibleDays: 3, timeZone: GroupsContentFixture.seoul.identifier))
        _ = try await fixture.api.setPrayerItemAnswered(postID: post.id, index: 2, answered: true)
        model.linkPostedPrayerItems(
            post,
            sources: [
                0: GroupPrayerTopicSource(entryID: record.id, topicID: answeredHere.id),
                1: GroupPrayerTopicSource(entryID: record.id, topicID: same.id),
                2: GroupPrayerTopicSource(entryID: record.id, topicID: answeredThere.id),
            ])
        let feed = GroupFeedModel(
            api: api, groupID: fixture.wednesday.id, now: { [clock = fixture.clock] in clock.now },
            events: fixture.events, onRefreshed: model.groups?.onFeedRefreshed)

        await feed.refresh()
        await model.groupPrayerSyncTask?.value
        let calls = await answeredCalls(api)
        XCTAssertEqual(calls, 1, "only line 0: answered in the journal, not in the group")
        let server = try await fixture.api.post(id: post.id)
        XCTAssertNotNil(server.items?[0].answeredAt)
        XCTAssertNil(server.items?[1].answeredAt)
        XCTAssertNotNil(
            server.items?[2].answeredAt,
            "a mark made elsewhere is never undone by catch-up (the journal may lag behind)")
        XCTAssertEqual(try status(record.id, answeredThere.id), .ongoing)

        await feed.refresh()
        await model.groupPrayerSyncTask?.value
        let callsAfterSecondRefresh = await answeredCalls(api)
        XCTAssertEqual(callsAfterSecondRefresh, 1, "nothing left to fix")
    }

    func testAccountDeletionClearsTheLinkKey() {
        XCTAssertTrue(AppModel.cloudKeyValueKeys.contains(GroupPrayerLinkStore.key))
        XCTAssertTrue(AppModel.cloudKeyValueKeys.contains(KindCatalogStore.key))
        XCTAssertTrue(AppModel.cloudKeyValueKeys.contains(PrayerTemplateStore.key))
    }
}
#endif
