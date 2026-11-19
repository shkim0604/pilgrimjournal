#if canImport(XCTest)
import Foundation
import PilgrimAPI
import XCTest

/// APNs resolves `loc-key`/`title-loc-key` from the app's main bundle, so every
/// `PushLocKey` needs a `ko` and an `en` text in the app's String Catalog that takes exactly
/// the `loc-args` the server sends (design.md 10).
final class GroupPushLocalizationTests: XCTestCase {
    private static let catalogURL = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources/PilgrimJournal/Localizable.xcstrings")

    private func strings() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.catalogURL)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(catalog["strings"] as? [String: Any])
    }

    /// The `ko` and `en` values of `key`.
    private func texts(_ key: String, in strings: [String: Any]) throws -> [String: String] {
        let entry = try XCTUnwrap(strings[key] as? [String: Any], "\(key) is missing")
        XCTAssertEqual(entry["extractionState"] as? String, "manual", key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
        var texts: [String: String] = [:]
        for language in ["ko", "en"] {
            let localization = try XCTUnwrap(
                localizations[language] as? [String: Any], "\(key) has no \(language)")
            let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], key)
            XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(language)")
            let value = try XCTUnwrap(unit["value"] as? String, key)
            XCTAssertFalse(value.isEmpty, "\(key) \(language)")
            texts[language] = value
        }
        return texts
    }

    private func argumentCount(_ text: String) -> Int {
        text.components(separatedBy: "%@").count - 1
    }

    func testEveryPushKeyHasKoreanAndEnglishText() throws {
        let strings = try strings()
        for key in PushLocKey.all {
            _ = try texts(key, in: strings)
        }
    }

    func testPushTextsTakeTheArgumentsTheServerSends() throws {
        let strings = try strings()
        let groupID = UUID()
        let payloads =
            PostKind.allCases.map {
                PushPayload.newPost(
                    groupID: groupID, postID: UUID(), kind: $0, groupName: "수요 기도모임",
                    authorName: "민지")
            }
            + [
                PushPayload.dailyReport(itemCount: 3),
                PushPayload.group(.voteStarted, groupID: groupID, groupName: "수요 기도모임"),
                PushPayload.group(.voteRunoff, groupID: groupID, groupName: "수요 기도모임"),
                PushPayload.group(
                    .voteDecided(newAdminName: "준호"), groupID: groupID, groupName: "수요 기도모임"),
                PushPayload.group(.deletionScheduled, groupID: groupID, groupName: "수요 기도모임"),
                PushPayload.prayerAnswered(
                    groupID: groupID, postID: UUID(), groupName: "수요 기도모임", authorName: "민지"),
            ]
        var covered = Set<String>()
        for payload in payloads {
            let alert = payload.aps.alert
            for (key, args) in [
                (alert.titleLocKey, alert.titleLocArgs), (alert.locKey, alert.locArgs),
            ] {
                covered.insert(key)
                for (language, text) in try texts(key, in: strings) {
                    XCTAssertEqual(argumentCount(text), args.count, "\(key) \(language): \(text)")
                }
            }
        }
        XCTAssertEqual(covered, Set(PushLocKey.all))
    }
}
#endif
