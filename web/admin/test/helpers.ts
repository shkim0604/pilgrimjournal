import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { DatabaseSync } from 'node:sqlite';
import { openDatabase } from '../src/db.ts';

export function tempDir(prefix = 'pilgrim-admin-'): string {
  return mkdtempSync(join(tmpdir(), prefix));
}

export function tempDatabase(): DatabaseSync {
  return openDatabase(join(tempDir(), 'admin.sqlite'));
}
