import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { openDatabase } from '../src/db.ts';

function tempPath(): string {
  return join(mkdtempSync(join(tmpdir(), 'pilgrim-admin-db-')), 'nested', 'admin.sqlite');
}

test('creates tables and sets user_version 1', () => {
  const db = openDatabase(tempPath());
  const tables = db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    .all()
    .map((row) => row.name);
  assert.deepEqual(tables, ['admins', 'login_failures', 'sessions']);
  assert.equal(db.prepare('PRAGMA user_version').get()?.user_version, 1);
  db.close();
});

test('is idempotent on reopen', () => {
  const path = tempPath();
  openDatabase(path).close();
  const db = openDatabase(path);
  assert.equal(db.prepare('PRAGMA user_version').get()?.user_version, 1);
  db.close();
});

test('enables foreign keys', () => {
  const db = openDatabase(tempPath());
  assert.equal(db.prepare('PRAGMA foreign_keys').get()?.foreign_keys, 1);
  db.close();
});
