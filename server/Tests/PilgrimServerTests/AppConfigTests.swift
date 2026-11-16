import PilgrimAPI
import XCTest

@testable import PilgrimServerCore

final class AppConfigTests: XCTestCase {
    private let base = ["DATABASE_URL": "postgres://u:p@localhost:5432/pilgrim"]

    private func production(_ extra: [String: String] = [:]) -> [String: String] {
        base.merging(
            [
                "APP_ENV": "production",
                "JWT_SECRET": String(repeating: "j", count: 32),
                "MEDIA_URL_SECRET": String(repeating: "m", count: 32),
            ], uniquingKeysWith: { $1 }
        ).merging(extra, uniquingKeysWith: { $1 })
    }

    func testDevelopmentDefaults() throws {
        let config = try AppConfig(environment: base)
        XCTAssertEqual(config.appEnvironment, .development)
        XCTAssertEqual(config.dayLength, 86_400)
        XCTAssertFalse(config.subscriptionRequired)
        XCTAssertFalse(config.devLoginEnabled)
        XCTAssertEqual(config.httpPort, 3100)
        XCTAssertEqual(config.allowedBundleIDs, BundleIDs.all)
        XCTAssertEqual(config.publicBaseURL.absoluteString, "http://localhost:3100")
        XCTAssertEqual(config.rateLimits, RateLimits())
    }

    func testMissingDatabaseURLIsRefused() {
        XCTAssertThrowsError(try AppConfig(environment: [:]))
    }

    func testProductionRefusesDevLogin() {
        XCTAssertThrowsError(try AppConfig(environment: production(["DEV_LOGIN_ENABLED": "true"])))
        { error in
            XCTAssertTrue("\(error)".contains("DEV_LOGIN_ENABLED"))
        }
        XCTAssertNoThrow(try AppConfig(environment: production()))
    }

    func testProductionRefusesScaledDaysAndMissingSecrets() {
        XCTAssertThrowsError(
            try AppConfig(environment: production(["TIME_SCALE_DAY_SECONDS": "10"])))
        var noSecret = production()
        noSecret["MEDIA_URL_SECRET"] = nil
        XCTAssertThrowsError(try AppConfig(environment: noSecret))
        var noJWT = production()
        noJWT["JWT_SECRET"] = "short"
        XCTAssertThrowsError(try AppConfig(environment: noJWT))
    }

    func testProductionUsesThePublicHost() throws {
        let config = try AppConfig(environment: production())
        XCTAssertEqual(config.publicBaseURL, APIPaths.productionBaseURL)
    }

    func testDevelopmentSwitches() throws {
        let config = try AppConfig(
            environment: base.merging(
                [
                    "DEV_LOGIN_ENABLED": "true",
                    "SUBSCRIPTION_REQUIRED": "yes",
                    "TIME_SCALE_DAY_SECONDS": "10",
                    "MIN_CLIENT_VERSION": "1.3.0",
                    "PUBLIC_BASE_URL": "https://example.test/",
                    "RATE_LIMIT_POSTS": "5/60",
                ], uniquingKeysWith: { $1 }))
        XCTAssertTrue(config.devLoginEnabled)
        XCTAssertTrue(config.subscriptionRequired)
        XCTAssertEqual(config.dayLength, 10)
        XCTAssertEqual(config.minimumClientVersion, ClientVersion("1.3"))
        XCTAssertEqual(config.publicBaseURL.absoluteString, "https://example.test")
        XCTAssertEqual(config.rateLimits.posts, RateLimitRule(requests: 5, window: 60))
    }

    func testDayLengthAlias() throws {
        let config = try AppConfig(
            environment: base.merging(["DAY_LENGTH_SECONDS": "30"], uniquingKeysWith: { $1 }))
        XCTAssertEqual(config.dayLength, 30)
    }

    func testInvalidValuesAreRefused() {
        for (key, value) in [
            ("APP_ENV", "staging"), ("SUBSCRIPTION_REQUIRED", "maybe"),
            ("TIME_SCALE_DAY_SECONDS", "0"), ("MIN_CLIENT_VERSION", "one"),
            ("RATE_LIMIT_POSTS", "30"), ("PORT", "70000"), ("ADMIN_API_TOKEN", "short"),
        ] {
            XCTAssertThrowsError(
                try AppConfig(environment: base.merging([key: value], uniquingKeysWith: { $1 })),
                "\(key)=\(value)")
        }
    }
}
