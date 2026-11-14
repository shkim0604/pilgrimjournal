// swift-tools-version: 6.2

import PackageDescription

// The shared group-server contract: request/response DTOs, error codes and the pure rule
// functions (expiry, admin votes, photo limits, invite codes). Foundation only, so the app
// (through JournalGroups) and the Vapor server on Linux depend on the same copy.
let package = Package(
    name: "PilgrimAPI",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PilgrimAPI", targets: ["PilgrimAPI"])
    ],
    targets: [
        .target(name: "PilgrimAPI"),
        .testTarget(name: "PilgrimAPITests", dependencies: ["PilgrimAPI"]),
    ]
)
