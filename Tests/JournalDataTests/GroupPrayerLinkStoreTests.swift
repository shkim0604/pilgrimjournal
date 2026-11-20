#if canImport(XCTest)
import Foundation
import XCTest

@testable import JournalData

@MainActor
final class GroupPrayerLinkStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let start = Date(timeIntervalSince1970: 1_763_079_600)
    private var now = Date(timeIntervalSince1970: 1_763_079_600)

    override func setUp() {
        super.setUp()
        suiteName = "pilgrim-prayer-links-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        now = start
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func store(_ cloud: FakeCloudStore?) -> GroupPrayerLinkStore {
        GroupPrayerLinkStore(
            defaults: defaults, cloudStore: cloud, now: { [unowned self] in self.now })
    }

    private func link(post: UUID = UUID(), index: Int = 0, expiresIn days: Double = 3)
        -> GroupPrayerLink
    {
        GroupPrayerLink(
            postID: post, groupID: UUID(), itemIndex: index, entryID: UUID(), topicID: UUID(),
            expiresAt: start.addingTimeInterval(days * 86_400))
    }

    func testSavesToTheCloudStoreAndLoadsBack() {
        let cloud = FakeCloudStore()
        let links = store(cloud)
        let post = UUID()
        let first = link(post: post, index: 0)
        let second = link(post: post, index: 1)
        links.add([first, second])

        XCTAssertNotNil(cloud.storage[GroupPrayerLinkStore.key])
        XCTAssertNil(defaults.data(forKey: GroupPrayerLinkStore.key), "cloud only")
        XCTAssertEqual(store(cloud).links(), [first, second])

        // The same post line again replaces the old link.
        var replaced = link(post: post, index: 1)
        replaced.topicID = UUID()
        links.add([replaced])
        XCTAssertEqual(links.links(), [first, replaced])
    }

    func testLocalOnlyScopeUsesDefaults() {
        let links = store(nil)
        let saved = link()
        links.add([saved])
        XCTAssertNotNil(defaults.data(forKey: GroupPrayerLinkStore.key))
        XCTAssertEqual(links.links(), [saved])
    }

    func testExpiredLinksArePrunedWhenRead() {
        let cloud = FakeCloudStore()
        let live = link(expiresIn: 5)
        store(cloud).add([live, link(expiresIn: 1)])

        now = start.addingTimeInterval(2 * 86_400)
        XCTAssertEqual(store(cloud).links(), [live])
        // Written back without the expired one, even for a clock before it expired.
        now = start
        XCTAssertEqual(store(cloud).links(), [live])
    }

    func testUpdateExpiryMovesEveryLineOfThePost() {
        let links = store(FakeCloudStore())
        let post = UUID()
        let other = link()
        links.add([link(post: post, index: 0), link(post: post, index: 1), other])
        let extended = start.addingTimeInterval(10 * 86_400)

        links.updateExpiry(postID: post, to: extended)
        let kept = links.links()
        XCTAssertEqual(kept.filter { $0.postID == post }.map(\.expiresAt), [extended, extended])
        XCTAssertEqual(kept.last, other)
    }

    func testUnreadableValueReadsAsEmpty() {
        let cloud = FakeCloudStore()
        cloud.storage[GroupPrayerLinkStore.key] = Data("not json".utf8)
        XCTAssertEqual(store(cloud).links(), [])
        XCTAssertEqual(cloud.setCount, 0, "left alone")
    }
}
#endif
