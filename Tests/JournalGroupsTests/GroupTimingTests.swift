import XCTest

@testable import JournalGroups

final class GroupTimingTests: XCTestCase {
    func testRouteHidesIDs() {
        let id = UUID().uuidString
        XCTAssertEqual(GroupTiming.route(["groups", id, "posts"]), "groups/:id/posts")
        XCTAssertEqual(
            GroupTiming.route(["posts", id, "items", "2", "answer"]), "posts/:id/items/:id/answer")
    }

    func testServerDurationReadsDur() {
        XCTAssertEqual(GroupTiming.serverDuration("app;dur=12.3"), "12.3ms")
        XCTAssertEqual(GroupTiming.serverDuration("app;dur=4, db;dur=1"), "4ms")
        XCTAssertNil(GroupTiming.serverDuration(nil))
        XCTAssertNil(GroupTiming.serverDuration("app"))
    }
}
