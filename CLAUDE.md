# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Pilgrim Journal — a local-first journal app for Apple platforms (iOS 17+, macOS 14+) that imports Day One entries and organizes them into user-manageable kinds (defaults: prayer notes (기도노트), Bible study (성경공부), reading notes (독서노트), diary (일기) and memo (메모)); imported entries no rule matches stay unclassified (미분류). Sign in with Apple gates app access (no name requested; the email scope is requested only to show the signed-in account and is kept in the device Keychain, never in CloudKit); sync uses the device's system iCloud account via CloudKit private database — these are deliberately separate concerns (see Privacy below).

## Commands

Shared code lives in a Swift Package, so domain/import/search/backup logic can be built and tested with just macOS Command Line Tools — no Xcode required:

```sh
swift build
swift test
swift run JournalChecks       # additional runtime checks (see Sources/JournalChecks)
```

Run a single test target or test:

```sh
swift test --filter JournalDomainTests
swift test --filter JournalDomainTests.SomeTestCase/testSomeName
```

`./scripts/check.sh` is the full local gate: `swift format lint --strict` (config in `.swift-format`; fix with `swift format format -i --recursive Sources Tests`), build, `swift test`, `JournalChecks`, then a scan that fails if any `.zip` file or Day One-looking export is present in the repo (personal data must never be committed — see Privacy).

The Xcode project is stricter than `swift build` (it enforces member import visibility), so after changing imports also build it unsigned:

```sh
xcodebuild -project PilgrimJournal/PilgrimJournal.xcodeproj -scheme PilgrimJournalApp -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

`swift test` runs on macOS, so it skips `#if os(iOS)` tests such as `LiveMarkdownTextEditorIOSTests` (the hosted iPhone editor tests guarding the typing release gate). Run the app test target on an iOS Simulator for those:

```sh
xcodebuild test -scheme PilgrimJournal-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:PilgrimJournalTests -testLanguage ko -testRegion KR CODE_SIGNING_ALLOWED=NO
```

### Localization (Korean source, English translation)

The UI is Korean-first; the Korean text itself is the localization key and English lives in String Catalogs: `Sources/PilgrimJournal/Localizable.xcstrings` (app, main bundle; excluded from SwiftPM and compiled by the Xcode app target), `Sources/<Library>/Resources/Localizable.xcstrings` (libraries, `String(localized: "…", bundle: .module)`), and `PilgrimJournal/PilgrimJournal/InfoPlist.xcstrings` (permission texts). New user-visible text must go through `Text("…")`-style `LocalizedStringKey` literals or `String(localized:)`; never localize stored or synced data (Day One matching, import-audit records, kind names in the catalog). Built-in kind names are stored in Korean and translated only for display (`KindDefinition.displayName` / `storedName(for:)`). Command-line SwiftPM copies catalogs without compiling them, so `swift test` sees Korean; Xcode builds do compile them, which is why the iOS Simulator test run pins `-testLanguage ko`. After adding strings, `xcodebuild -exportLocalizations -project PilgrimJournal/PilgrimJournal.xcodeproj -localizationPath <dir> -exportLanguage en` (and the same without `-project` in the package root for the libraries) refreshes the catalogs' keys; then fill in the missing `en` values.

CI (`.github/workflows/check.yml`) runs `scripts/check.sh`, both unsigned Xcode builds, and that iOS Simulator test run on every PR and push to `main`. It is pinned to Xcode 26.2 on the `macos-26` runner, and the iOS job picks any available iPhone on the newest iOS runtime instead of naming a device. When bumping the local Xcode, bump `DEVELOPER_DIR` there too.

Running the actual app (Simulator, Sign in with Apple, CloudKit entitlements, real-device verification) requires the full Xcode project at `PilgrimJournal/PilgrimJournal.xcodeproj` with a Developer Team signing identity. `CODE_SIGNING_ALLOWED=NO` builds only validate UI/compilation, not auth or sync.

CloudKit debug tooling (schema deploy, data wipe, login-gate bypass) is documented in [docs/development.md](docs/development.md) under "CloudKit 운영 도구" — these run via env vars on a directly-invoked debug binary (not `open`, which drops env vars).

Release archiving must happen outside the `~/Documents` iCloud-synced path (extended attributes break codesign); see the full procedure in [docs/development.md](docs/development.md).

## Architecture

The app is split into a domain-first Swift Package with adapter targets, so platform concerns (SwiftData, CloudKit, UIKit) stay swappable behind protocols:

- **JournalDomain** — pure domain types and logic, no platform dependencies. `JournalRepository`/`BackupRestoreRepository`/`AttachmentRepository` protocols define the storage contract; `RevisionResolver`, `ClassificationEngine`, `ClassificationRuleResolver` are deterministic conflict-resolution logic shared by every adapter (last-write-wins by timestamp, then deviceID, then UUID as tiebreakers — see `JournalRepository.swift`). `KindCatalog` holds the user-manageable kind definitions (create/rename/recolour/reorder/delete-with-move-target/restore built-ins) with a deterministic merge; `KindDeletionService`/`KindReconciler` move entries off deleted kinds.
- **JournalData** — the SwiftData + CloudKit adapter (current storage implementation). `JournalContainerFactory` builds a `ModelContainer` with two configurations: a `Canonical` store (CloudKit-synced) and a `LocalAuxiliary` store (device-only, never synced — used for search index state, import audit, etc.). Also owns `AppLockService` (Keychain-backed passcode/biometric gate, in `AppLockSecurity.swift`), `CloudIdentityBindingService`/`CloudAccountMonitor` (binds a private CloudKit database to one Apple Sign-In identity via a one-way hash, blocking the UI if a different Apple user opens the same iCloud storage), and `CloudKitSchemaInitializer` (see known-issues below for why this exists).
- **DayOneImport** — parses and safely extracts Day One `.zip` exports (`SafeZipArchive`, `DayOneArchiveAnalyzer`) into domain drafts. Also holds the shared ZIP primitives (`StoredZipWriter`, `ZipChecksum`) that backups and `JournalChecks` write with.
- **JournalSearch** — local SQLite/FTS5 search index (trigram tokenizer where available, `unicode61` fallback, `LIKE` fallback for ≤2-char queries). Fully derived data: never included in CloudKit sync or backups, rebuilt from the canonical store on integrity mismatch. Details in [docs/search.md](docs/search.md).
- **JournalBackup** — export/import of full local backups (depends on both JournalDomain and DayOneImport).
- **PilgrimJournal** — the SwiftUI app executable, composing all the above. `AppModel` is the central `@MainActor` `ObservableObject` driving the UI; `AppLockCoordinator`/`AppleAuthenticationCoordinator` gate access before the journal UI mounts.
- **JournalChecks** — a small executable for scriptable runtime verification (used by `scripts/check.sh`), separate from `swift test`.
- **ShareCardEval** — a re-runnable eval of the roadmap's share-card extraction on Apple's on-device Foundation Models, over synthetic fixtures. Needs macOS 26 + Apple Intelligence, so it is deliberately not in `scripts/check.sh`/CI; usage in [docs/development.md](docs/development.md) ("공유 카드 추출 평가").

Storage adapters are intentionally provisional: the domain protocol is the stable contract, and `docs/development.md` lists concrete real-device conditions (background convergence between two devices, offline concurrent-edit revision preservation, delete tombstone + restore, external attachment upload, large-import responsiveness) that the SwiftData adapter must pass. If any fails, the plan is to swap in an `NSPersistentCloudKitContainer` adapter without touching JournalDomain.

### Sync and identity model

Sign in with Apple (app-access auth) and CloudKit sync (iCloud account) are independent — a user can be authenticated but running fully local-only if iCloud is unavailable. On first cloud connection, the private CloudKit database is bound to a SHA-256 hash of the Apple Sign-In opaque user ID; if a different Apple account later opens the same iCloud storage, the journal UI is blocked rather than merging data. See [docs/privacy.md](docs/privacy.md) for the full boundary (no public/shared CloudKit DB, no analytics/ad SDKs, app-lock password is never stored — only a salted verifier).

## Known recurring issues

[docs/known-issues.md](docs/known-issues.md) tracks problems that have resurfaced more than once — read it before touching CloudKit schema or the markdown text editor. Two are load-bearing for any related change:

- **CloudKit schema drift**: CloudKit's automatic schema generation only sees fields that have actually been exported with a non-nil value in Development — it does not read the SwiftData model. Adding a model or an optional property to `canonicalModels` requires manually running `initializeCloudKitSchema()` (see `Sources/JournalData/CloudKitSchemaInitializer.swift` and the command in `docs/development.md`) and deploying via CloudKit Console before release, or Production will silently reject records using the new field with no UI error.
- **Editor input dropping (release gate)**: `LiveMarkdownTextEditor`'s `updateUIView`/`updateNSView` (`Sources/PilgrimJournal/MarkdownSupport.swift`) must not treat its own recently-published SwiftUI binding writes as external changes — doing so overwrites in-flight keystrokes. The fix uses `publishedHistory` + `MarkdownInputReconciliation.shouldApplyExternalText` to distinguish an echo from a real external change. This has regressed silently before; the release checklist in `docs/known-issues.md` (fast 30s+ mixed Korean/English typing, Release config, real iPhone soft keyboard) must be run before every TestFlight build — automated tests (the pure-function reconciliation logic, plus `LiveMarkdownTextEditorIOSTests` driving the hosted iPhone editor with `insertText`) don't cover real keyboard input timing.

## Tracking docs — keep these current

Two living checklists track work outside of git history; update them as part of any session that touches their subject matter, don't let them go stale:

- [docs/pre-release-checklist.md](docs/pre-release-checklist.md) — release-gate status: real-device verification sessions from `docs/device-verification.md`, what's been deferred, what's still untested.
- [docs/implementation-todo.md](docs/implementation-todo.md) — deferred feature work and known UX gaps that aren't release blockers, moved to "완료" when shipped.

Longer-term product direction (subscriber-only private faith groups, shareable prayer/book-report/testimony cards with expiry and scrap) is in [docs/roadmap.md](docs/roadmap.md). It plans a self-hosted group backend, which the current privacy boundary in `docs/privacy.md` (no own server) rules out today, so read it before any work that touches sharing.

## Privacy constraints on this repo

Personal Day One `.zip` exports and real export content must never be committed, included in test fixtures, or logged — tests use anonymized fixtures that only reproduce structure. `scripts/check.sh` enforces this with a scan after the tests; do not bypass it when adding import-related tests or fixtures.
