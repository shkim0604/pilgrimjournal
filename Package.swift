// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PilgrimJournal",
    defaultLocalization: "ko",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "JournalDomain", targets: ["JournalDomain"]),
        .library(name: "JournalData", targets: ["JournalData"]),
        .library(name: "DayOneImport", targets: ["DayOneImport"]),
        .library(name: "JournalSearch", targets: ["JournalSearch"]),
        .library(name: "JournalBackup", targets: ["JournalBackup"]),
        .executable(name: "PilgrimJournal", targets: ["PilgrimJournal"]),
        .executable(name: "JournalChecks", targets: ["JournalChecks"]),
    ],
    targets: [
        .target(name: "JournalDomain"),
        .target(
            name: "JournalData",
            dependencies: ["JournalDomain"],
            swiftSettings: [
                .define("PILGRIM_SWIFTDATA", .when(platforms: [.iOS, .macOS])),
            ],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
        .target(
            name: "DayOneImport",
            dependencies: ["JournalDomain"]
        ),
        .target(
            name: "JournalSearch",
            dependencies: ["JournalDomain"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "JournalBackup",
            dependencies: ["JournalDomain", "DayOneImport"]
        ),
        .executableTarget(
            name: "PilgrimJournal",
            dependencies: [
                "JournalDomain",
                "JournalData",
                "DayOneImport",
                "JournalSearch",
                "JournalBackup",
            ],
            swiftSettings: [
                .define("PILGRIM_SWIFTDATA", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .executableTarget(
            name: "JournalChecks",
            dependencies: [
                "JournalDomain",
                "JournalData",
                "DayOneImport",
                "JournalSearch",
                "JournalBackup",
            ]
        ),
        .testTarget(
            name: "JournalDomainTests",
            dependencies: ["JournalDomain"]
        ),
        .testTarget(
            name: "JournalDataTests",
            dependencies: ["JournalData", "JournalDomain"],
            swiftSettings: [
                .define("PILGRIM_SWIFTDATA", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "DayOneImportTests",
            dependencies: ["DayOneImport", "JournalData", "JournalDomain"]
        ),
        .testTarget(
            name: "JournalSearchTests",
            dependencies: ["JournalSearch", "JournalDomain"]
        ),
        .testTarget(
            name: "JournalBackupTests",
            dependencies: ["JournalBackup", "JournalDomain"]
        ),
        .testTarget(
            name: "PilgrimJournalTests",
            dependencies: ["PilgrimJournal", "JournalData"]
        ),
    ]
)
