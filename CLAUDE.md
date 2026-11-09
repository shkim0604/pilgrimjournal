# CLAUDE.md

Guidance for Claude Code in this repository.

## Project

Pilgrim Journal — a local-first journal app for iOS 17+ / macOS 14+. It imports Day One exports and sorts entries into user-manageable kinds (defaults 기도노트, 성경공부, 독서노트, 일기, 메모; unmatched imports stay 미분류). Sign in with Apple gates app access (email kept only in the device Keychain); sync uses the device's iCloud account through the CloudKit private database. The two are deliberately independent — see [docs/privacy.md](docs/privacy.md).

## Commands

```sh
swift build
swift test                                   # or: swift test --filter JournalDomainTests[.Case/testName]
swift run JournalChecks                      # scriptable runtime checks
./scripts/check.sh                           # full local gate (below)
```

- `scripts/check.sh` = `swift format lint --strict` (fix: `swift format format -i --recursive Sources Tests`), build, tests, `JournalChecks`, admin-snapshot freshness, and a scan that fails on any `.zip` or Day One-looking export.
- The Xcode project enforces member import visibility, so after changing imports also run `xcodebuild -project PilgrimJournal/PilgrimJournal.xcodeproj -scheme PilgrimJournalApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.
- `swift test` skips `#if os(iOS)` tests (e.g. `LiveMarkdownTextEditorIOSTests`). Run them with `xcodebuild test -scheme PilgrimJournal-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PilgrimJournalTests -testLanguage ko -testRegion KR CODE_SIGNING_ALLOWED=NO`.
- After changing a SwiftData model or `Package.swift` targets, run `./scripts/admin-snapshot.sh` and commit `web/admin/snapshot/`. The console itself: `cd web/admin && npm test && npm run typecheck`.
- CI (`.github/workflows/check.yml`) runs all of the above on every PR and push to `main`, pinned to Xcode 26.2 on `macos-26`; bump `DEVELOPER_DIR` there when bumping local Xcode.
- Signing, Sign in with Apple, CloudKit and real devices need the Xcode project with a Developer Team; unsigned builds only prove compilation. CloudKit tooling (schema deploy, wipe, login bypass via env vars on a directly-run debug binary), release archiving (never inside an iCloud-synced folder) and the admin console deploy are in [docs/development.md](docs/development.md).

**Localization:** Korean text is the key; English lives in String Catalogs (`Sources/PilgrimJournal/Localizable.xcstrings`, `Sources/<Library>/Resources/Localizable.xcstrings`, `PilgrimJournal/PilgrimJournal/InfoPlist.xcstrings`). User-visible text goes through `Text("…")` / `String(localized:)`; never localize stored or synced data (built-in kind names are stored in Korean, translated via `KindDefinition.displayName`). Procedure in docs/development.md ("로컬라이제이션").

## Architecture

Domain-first Swift Package; platform concerns sit behind protocols.

- **JournalDomain** — pure types and logic. `JournalRepository`/`BackupRestoreRepository`/`AttachmentRepository` are the storage contract; `RevisionResolver`, `ClassificationEngine`, `ClassificationRuleResolver` resolve conflicts deterministically (timestamp → deviceID → UUID). `KindCatalog` + `KindDeletionService`/`KindReconciler` manage kinds. Prayer topics (`PrayerTopic`, `PrayerTopicAggregator`, `PrayerTemplateCatalog`) ride inside the entry's `EntryDetails.detailsData` JSON blob, so they needed no CloudKit schema change.
- **JournalData** — SwiftData + CloudKit adapter (decided; kept behind the protocol). `JournalContainerFactory` builds a CloudKit-synced `Canonical` store and a device-only `LocalAuxiliary` store. Per-account files live under `JournalAccountScope` (`Accounts/<hash>/`). Also `AppLockService` (Keychain passcode/biometrics), `CloudIdentityBindingService`/`CloudAccountMonitor`, `CloudKitSchemaInitializer`, `AccountDeletionService`.
- **iCloud key-value store** — a second sync channel next to CloudKit: `KindCatalogStore`, `PrayerTemplateStore`, the notebook catalog. Any new key must also be removed by account deletion. Debug builds use the `.debug` bundle ID but share the release KVS.
- **JournalSharing** — family sharing: each shared notebook or entry gets its own `pilgrim-share-<uuid>` zone, shared with `CKShare` and synced by `CKSyncEngine` (`SharedSpaceStore`, `SharedSyncEngineHost`) beside SwiftData.
- **DayOneImport** — safe Day One `.zip` parsing (`SafeZipArchive`, `DayOneArchiveAnalyzer`) plus shared ZIP primitives (`StoredZipWriter`, `ZipChecksum`).
- **JournalSearch** — local SQLite/FTS5 index, fully derived and never synced or backed up ([docs/search.md](docs/search.md)).
- **JournalBackup** — full local backup export/import.
- **PilgrimJournal** — the SwiftUI app. `AppModel` (central `@MainActor` model), `JournalSessionController` (opens stores, manual sync), `AppLockCoordinator`/`AppleAuthenticationCoordinator` gate the UI.
- **JournalChecks**, **ShareCardEval** (on-device model eval, macOS 26 only, not in CI), **AdminSnapshot** (writes `web/admin/snapshot/`).
- **`web/admin`** — read-only developer console (Node + Hono, Mac mini + Cloudflare Tunnel). It parses the tracking docs: keep top-level `- [ ]` lines in the checklist and `- **제목**` lines under `## 대기 중` in the todo.

App code is split by area: the markdown editor in `Sources/PilgrimJournal/Markdown/` (`LiveMarkdownTextEditor+iOS.swift`/`+macOS.swift` hold the input path), entry screens in `Entry/`, and `AppModel` as a core file plus `AppModel+<Area>.swift` extensions. Locate symbols with `git grep -n` and read ranges rather than whole files.

## Rules that have bitten before

Read [docs/known-issues.md](docs/known-issues.md) before touching CloudKit models or the markdown editor. The two load-bearing ones:

- **CloudKit schema drift** — adding a model or optional property to `canonicalModels` requires running `initializeCloudKitSchema()` and deploying in CloudKit Console before release; Production silently rejects unknown fields.
- **Editor input echo (release gate)** — `LiveMarkdownTextEditor`'s `updateUIView`/`updateNSView` must not treat its own published binding writes as external changes (`publishedHistory` + `MarkdownInputReconciliation.shouldApplyExternalText`). Run the [real-device typing gate](docs/known-issues.md#에디터-입력-릴리스-게이트) before every TestFlight build.

## Docs

- Living tracking docs — update them in any session that touches their subject: [docs/pre-release-checklist.md](docs/pre-release-checklist.md) (open release-gate items only) and [docs/implementation-todo.md](docs/implementation-todo.md) (deferred work; recent "완료").
- [docs/roadmap.md](docs/roadmap.md) — product direction (private faith groups, share cards); read before sharing work. Feature specs go in `openspec/changes/`.
- `docs/archive/` and `openspec/changes/archive/` are history; don't read them by default.

## Privacy constraints on this repo

Personal Day One exports and real export content must never be committed, used as fixtures, or logged; tests use anonymized structural fixtures. Do not bypass the `scripts/check.sh` scan.
