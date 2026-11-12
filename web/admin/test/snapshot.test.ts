import assert from 'node:assert/strict';
import { utimesSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { loadSnapshot } from '../src/content/snapshot.ts';
import { webAdminDir, writeSnapshotDir } from './appHelpers.ts';
import { tempDir } from './helpers.ts';

test('loads committed snapshot', () => {
  const snapshot = loadSnapshot(join(webAdminDir, 'snapshot'));
  assert.ok(snapshot.schema.ok);
  assert.ok(snapshot.architecture.ok);
  assert.ok(snapshot.commits.ok);
  const [canonical, local] = snapshot.schema.value.stores;
  assert.equal(canonical!.name, 'Canonical');
  assert.equal(canonical!.cloudKitSynced, true);
  assert.equal(canonical!.entities.length, 5);
  assert.ok(canonical!.entities.some((e) => e.name === 'JournalEntryEntity'));
  assert.equal(local!.name, 'LocalAuxiliary');
  assert.equal(local!.entities.length, 3);
  const domain = snapshot.architecture.value.targets.find((t) => t.name === 'JournalDomain');
  assert.equal(domain?.kind, 'library');
  assert.ok(snapshot.commits.value.commits.length > 0);
});

test('reports missing files', () => {
  const snapshot = loadSnapshot(tempDir());
  assert.equal(snapshot.schema.ok, false);
  assert.equal(snapshot.architecture.ok, false);
  assert.equal(snapshot.commits.ok, false);
});

test('reports malformed JSON', () => {
  const dir = writeSnapshotDir({ 'schema.json': '{not json', 'architecture.json': { targets: 'nope' } });
  const snapshot = loadSnapshot(dir);
  assert.equal(snapshot.schema.ok, false);
  assert.equal(snapshot.architecture.ok, false);
});

test('reloads after the file changes', () => {
  const dir = writeSnapshotDir({ 'commits.json': { generatedAt: '2026-01-01T00:00:00Z', commits: [] } });
  const first = loadSnapshot(dir);
  assert.ok(first.commits.ok);
  assert.equal(first.commits.value.commits.length, 0);
  const later = new Date(Date.now() + 5000);
  const path = join(dir, 'commits.json');
  writeFileSync(
    path,
    JSON.stringify({ generatedAt: '2026-01-02T00:00:00Z', commits: [{ hash: 'abc1234', date: 'd', subject: 's' }] }),
  );
  // Make sure the mtime moves even on coarse-grained filesystems.
  utimesSync(path, later, later);
  const second = loadSnapshot(dir);
  assert.ok(second.commits.ok);
  assert.equal(second.commits.value.commits.length, 1);
});
