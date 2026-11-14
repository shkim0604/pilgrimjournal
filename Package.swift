// swift-tools-version: 6.2

import PackageDescription

let swiftDataDefine = SwiftSetting.define("PILGRIM_SWIFTDATA", .when(platforms: [.iOS, .macOS]))

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
        .library(name: "JournalSharing", targets: ["JournalSharing"]),
        .library(name: "DayOneImport", targets: ["DayOneImport"]),
        .library(name: "JournalSearch", targets: ["JournalSearch"]),
        .library(name: "JournalBackup", targets: ["JournalBackup"]),
        .executable(name: "PilgrimJournal", targets: ["PilgrimJournal"]),
        .executable(name: "JournalChecks", targets: ["JournalChecks"]),
        .executable(name: "ShareCardEval", targets: ["ShareCardEval"]),
        .executable(name: "AdminSnapshot", targets: ["AdminSnapshot"]),
    ],
    targets: [
        .target(
            name: "JournalDomain",
            resources: [.process("Resources")]
        ),
        .target(
            name: "JournalData",
            dependencies: ["JournalDomain"],
            resources: [.process("Resources")],
            swiftSettings: [
                swiftDataDefine
            ],
            linkerSettings: [
                .linkedFramework("CloudKit"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
            ]
        ),
        // Family sharing: shared notebooks and entries in their own CloudKit zones, synced
        // with CKSyncEngine apart from the SwiftData-mirrored private journal.
        .target(
            name: "JournalSharing",
            dependencies: ["JournalDomain"],
            linkerSettings: [
                .linkedFramework("CloudKit")
            ]
        ),
        .target(
            name: "DayOneImport",
            dependencies: ["JournalDomain"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "JournalSearch",
            dependencies: ["JournalDomain"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "JournalBackup",
            dependencies: ["JournalDomain", "DayOneImport"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "PilgrimJournal",
            dependencies: [
                "JournalDomain",
                "JournalData",
                "DayOneImport",
                "JournalSearch",
                "JournalBackup",
                "JournalSharing",
            ],
            // The app's String Catalog is compiled by the Xcode app target,
            // which builds these sources directly; SwiftPM builds only run
            // tests, which read the Korean source strings.
            exclude: ["Localizable.xcstrings"],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug)),
                swiftDataDefine,
            ],
            linkerSettings: [
                .linkedFramework("AuthenticationServices")
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
        // On-device model eval for the roadmap's share cards. Builds everywhere (the model code
        // is behind `canImport(FoundationModels)` / macOS 26 checks) but only runs on an Apple
        // Intelligence Mac, so scripts/check.sh and CI never run it.
        .executableTarget(
            name: "ShareCardEval",
            resources: [.copy("Resources/prompt-lab.html")]
        ),
        // Exports the SwiftData schema for the developer admin console (web/admin). Run via
        // scripts/admin-snapshot.sh; scripts/check.sh fails when the committed snapshot is stale.
        .executableTarget(
            name: "AdminSnapshot",
            dependencies: ["JournalData"],
            swiftSettings: [
                swiftDataDefine,
            ]
        ),
        .testTarget(
            name: "ShareCardEvalTests",
            dependencies: ["ShareCardEval"]
        ),
        .testTarget(
            name: "JournalDomainTests",
            dependencies: ["JournalDomain"]
        ),
        .testTarget(
            name: "JournalDataTests",
            dependencies: ["JournalData", "JournalDomain"],
            swiftSettings: [
                swiftDataDefine
            ]
        ),
        .testTarget(
            name: "JournalSharingTests",
            dependencies: ["JournalSharing", "JournalDomain", "JournalData"]
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
            dependencies: ["DayOneImport", "JournalBackup", "JournalData", "JournalDomain"]
        ),
        .testTarget(
            name: "PilgrimJournalTests",
            dependencies: ["PilgrimJournal", "JournalData"]
        ),
    ]
)
