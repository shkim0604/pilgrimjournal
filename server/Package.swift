// swift-tools-version: 6.2

import PackageDescription

// The group server (design.md "구성"): one image, two processes (`serve`, `worker`) plus
// `migrate`. App logic lives in the PilgrimServerCore library so tests can `@testable import`
// it; PilgrimServer is only the entry point. The shared contract (DTOs, error codes, rule
// functions) comes from the PilgrimAPI package next door — never duplicate its types here.
//
// vapor/jwt (S1: Apple identity tokens, access JWTs), vapor/apns (S5: push) and
// apple/app-store-server-library-swift (S8: subscriptions) are declared up front so the parallel
// Phase 1 branches don't all edit this file and Package.resolved.
let package = Package(
    name: "PilgrimServer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PilgrimServer", targets: ["PilgrimServer"])
    ],
    dependencies: [
        .package(path: "PilgrimAPI"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.12.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        // jwt 4.x: app-store-server-library-swift still requires jwt-kit 4.
        .package(url: "https://github.com/vapor/jwt.git", "4.2.0"..<"5.0.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "5.1.0"),
        .package(
            url: "https://github.com/apple/app-store-server-library-swift.git",
            "1.0.0"..<"7.0.0"),
    ],
    targets: [
        .target(
            name: "PilgrimServerCore",
            dependencies: [
                .product(name: "PilgrimAPI", package: "PilgrimAPI"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "VaporAPNS", package: "apns"),
                .product(
                    name: "AppStoreServerLibrary", package: "app-store-server-library-swift"),
            ]
        ),
        .executableTarget(
            name: "PilgrimServer",
            dependencies: [
                "PilgrimServerCore",
                .product(name: "Vapor", package: "vapor"),
            ]
        ),
        .testTarget(
            name: "PilgrimServerTests",
            dependencies: [
                "PilgrimServerCore",
                .product(name: "PilgrimAPI", package: "PilgrimAPI"),
                .product(name: "XCTVapor", package: "vapor"),
            ]
        ),
    ]
)
