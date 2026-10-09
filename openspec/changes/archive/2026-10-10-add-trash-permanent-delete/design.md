## Context

`JournalRepository`/`AttachmentRepository`/`BackupRestoreRepository`
(`Sources/JournalDomain/JournalRepository.swift`) have exactly two conformers —
`SwiftDataJournalRepository` and `InMemoryJournalRepository` — so any new protocol
method touches both. Canonical models (`JournalEntryEntity`, `EntryRevisionEntity`,
`AttachmentEntity`, `ClassificationRuleEntity`, `RestoreEpochEntity`) are mirrored to
CloudKit via SwiftData's native `ModelConfiguration.CloudKitDatabase`
(`Sources/JournalData/JournalContainerFactory.swift`), so `context.delete(...)` on a
canonical row already propagates as a CKRecord delete with no manual CloudKit code —
`deleteClassificationRule` is the one existing precedent for that. There are **no**
SwiftData relationships: `EntryRevisionEntity.entryID` and `AttachmentEntity.entryID`
are plain `UUID` columns, so nothing cascades automatically. Attachment binaries live
in two independent places — the mirrored `AttachmentEntity.binary`
(`@Attribute(.externalStorage)`, freed by row deletion) and a checksum-deduplicated,
cross-entry-shared CAS store on disk (`AttachmentFileStore`,
`removeIfUnreferenced(checksum:referencedChecksums:)`). See proposal.md for why this
is needed.

## Goals / Non-Goals

**Goals:**
- Remove entry + revision + attachment rows for trashed entries in one atomic
  operation, from both repository conformers.
- Reclaim CAS attachment files that no surviving entry still references.
- Unblock Day One re-import for a purged `sourceUUID`.
- Do all of this without adding a canonical model or a canonical attribute.

**Non-Goals:**
- Automatic time-based purge (proposal explicitly defers this).
- Guaranteeing a purged entry can never reappear on any device — see Risks below;
  this design accepts and documents the residual risk instead of engineering a
  distributed-deletion protocol for it.
- Changing `moveToTrash`/`restoreFromTrash` semantics or the tombstone model itself.
- A "purge history" or audit trail entity (would be a new canonical model).

## Decisions

**One batch repository method, `purgeEntries(ids:) -> JournalPurgeSummary`, on
`JournalRepository`, not `AttachmentRepository`.**
Entry, revision, and attachment rows must die in one store transaction — no
relationships means no cascade, so splitting the call across two protocols would
require two `context.save()` calls and leave a window where attachment rows outlive
their entry (an orphaned CKRecord no UI path can ever reach again). Both conformers
already implement all three repository protocols, so co-locating costs nothing.
Alternative considered: a separate `emptyTrash()` repository method — rejected because
"the trash" is a UI-level query (`AppModel.trashEntries`), and duplicating that query
inside two repository implementations risks the two disagreeing about what "trash"
means. `emptyTrash` is instead `AppModel` calling `purgeEntries` with every id from
`refreshTrash()`.

**No `deviceID:`/`at:` parameters, unlike `moveToTrash`/`restoreFromTrash`.**
Purge writes no tombstone and no revision — there is nothing to attribute to a device
or timestamp.

**Validate-all-then-delete.** `purgeEntries` fetches every requested id first and
throws before deleting anything if any id refers to a non-trashed (`deletedAt == nil`)
entry. A UI bug can then never turn into "the batch also deleted some live entries."
IDs that don't exist at all are skipped silently (not an error) so the operation is
idempotent under races (e.g. two windows purging the same id).

**`purgeEntries` does not use `BackupRestoreRepository.performRestoreTransaction`.**
That helper is scoped to `JournalRestoreExecutor`, is re-entrancy-guarded for that use,
and its `InMemoryJournalRepository` implementation snapshots every dictionary in the
store. `purgeEntries` gets its own atomicity: `SwiftDataJournalRepository` deletes
children then parents and calls `saveIfNeeded()`, rolling back the context on failure;
`InMemoryJournalRepository` snapshots the three affected dictionaries and restores them
on failure. This also means a future `purgeEntries` call nested inside a restore
transaction (not used today, but not precluded) won't split that transaction.

**`AttachmentRepository.attachmentChecksums()` is a new method rather than reusing
`allAttachments()`.** `allAttachments()` materializes every `binary`
(`@Attribute(.externalStorage)`), which would fault potentially gigabytes of blob data
onto the main actor just to compute a reference set. `attachmentChecksums()` reads only
the `checksum` column.

**CAS file cleanup happens in `AppModel`, strictly after the repository commit, not
inside the repository.** `purgeEntries` returns `releasedChecksums`; `AppModel` (which
already owns `paths: JournalPaths` and already constructs `AttachmentFileStore`
ad-hoc for uploads) re-queries `attachmentChecksums()` for the **full remaining**
reference set and calls `removeIfUnreferenced` per checksum. Two reasons to keep this
out of the repository: (1) a filesystem delete cannot participate in a SwiftData
rollback, so keeping it strictly post-commit turns any failure mode into "orphan file"
(recoverable, just wastes space) instead of "file deleted but the DB transaction later
rolled back" (data loss); (2) it avoids adding a filesystem dependency to
`SwiftDataJournalRepository`'s initializer, which today takes only a `ModelContainer`
and is constructed directly in tests, `JournalChecks`, and `JournalSessionController`.
`removeIfUnreferenced`'s existing signature (it takes the caller's belief about what's
still referenced and independently verifies) is a second safety net if the
repository's `releasedChecksums` arithmetic is ever wrong.

**`analyzeDayOne`'s `includeDeleted: true` dedupe scan is left unchanged.** The
correct fix for the re-import bug is deleting the trashed row, not changing how
duplicates are detected — a trashed-but-not-purged entry must still block re-import
(that's the whole point of soft delete). A code comment is added at the call site
recording this decision so a future reader doesn't "fix" it the other way.

**`JournalStoreChangeExtractor` is fixed to classify by `entityName`, not by
`context.model(for:)`, for deleted identifiers.** Resolving an already-deleted
`PersistentIdentifier` via `context.model(for:)` is unreliable; today a deletion that
fails to resolve silently falls through to `default`, `sawCanonicalChange` stays
`false`, and `extract` returns `nil` — meaning a purge in one window produces **no**
refresh signal in any other window/scene. The fix reads `deletedIdentifiers`
separately and matches `identifier.entityName` against the canonical entity names
derived from `PilgrimJournalSchemaV1.canonicalModels` via `Schema.entityName(for:)` —
never touching `context.model(for:)` for a deleted identifier. Any canonical deletion
forces `requiresFullRefresh = true`, since a deleted row can't be mapped back to an
entry UUID for a targeted refresh.

## Risks / Trade-offs

**[Risk] A device holding an unexported local edit to a purged entry can re-create
that row on its next CloudKit export**, since SwiftData's native mirroring has no
"tombstone for a hard delete" concept — it only ever mirrors what's currently in the
local store. → **Mitigation**: this is a structural limit of the storage adapter
(see `CLAUDE.md`'s note that it may be swapped for `NSPersistentCloudKitContainer`),
not something this change can fix without inventing a new sync primitive. The
confirmation dialog explicitly warns "다른 기기가 동기화된 뒤에 실행하세요" and that
un-synced edits can revive the entry; the remedy if it happens is to purge again. This
mirrors the exact trade-off the original design already accepted for soft-delete
tombstones (`build-personal-journal-app/design.md`), just one level further.

**[Risk] Replace-restoring a backup taken before a purge brings the entry back live,
not trashed**, because `JournalRestoreExecutor` upserts via `repository.save(draft)`
and `JournalEntryDraft` has no `deletedAt` field. → **Mitigation**: documented in the
confirmation dialog and in `docs/user-guide.md` rather than "fixed," since the same
gap already exists for ordinary tombstones today (a pre-existing, unrelated
limitation) and closing it would mean adding `deletedAt` to `JournalEntryDraft` and
auditing every save path — out of scope for this change.

**[Risk] `JournalPurgeSummary.releasedChecksums` could be computed incorrectly by a
repository implementation**, releasing a file another entry still needs. →
**Mitigation**: `AttachmentFileStore.removeIfUnreferenced` independently re-verifies
against a freshly queried reference set before deleting; `AppModel` never calls
`FileManager.removeItem` directly. Tests assert the shared-checksum case explicitly.

**[Risk] No new canonical model means no audit trail of what was purged.** →
Accepted as a Non-Goal; `JournalPurgeSummary` is transient (returned to the caller,
not persisted) by design, matching the constraint of not touching CloudKit schema.

## Migration Plan

No data migration. No new SwiftData model, no new attribute on a canonical model, no
CloudKit schema change — the `docs/known-issues.md` schema-drift procedure does not
apply to this change. Rollout is a normal app update; older and newer clients can
coexist against the same CloudKit database (an older client simply has no UI for the
new delete, and correctly treats a purge from a newer client as a delete it must mirror
locally like any other CloudKit-originated row removal).

## Open Questions

None — all decisions above are resolved for this change; anything deferred is called
out explicitly as a Non-Goal or a documented, accepted risk.
