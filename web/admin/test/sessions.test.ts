import assert from 'node:assert/strict';
import { test } from 'node:test';
import { insertAdmin } from '../src/auth/admins.ts';
import {
  SESSION_IDLE_MS,
  SESSION_MAX_MS,
  createSession,
  deleteOtherSessions,
  deleteSession,
  resolveSession,
} from '../src/auth/sessions.ts';
import { tempDatabase } from './helpers.ts';

const t0 = 1_800_000_000_000;

function setup() {
  const db = tempDatabase();
  const adminId = insertAdmin(db, 'someone', 'hash', true, t0);
  return { db, adminId };
}

test('creates and resolves a session', () => {
  const { db, adminId } = setup();
  const token = createSession(db, adminId, t0);
  assert.deepEqual(resolveSession(db, token, t0 + 1000), {
    adminId,
    username: 'someone',
    mustChangePassword: true,
  });
  assert.equal(resolveSession(db, 'not-a-token', t0), null);
});

test('stores only the token hash', () => {
  const { db, adminId } = setup();
  const token = createSession(db, adminId, t0);
  const rows = db.prepare('SELECT token_hash FROM sessions').all();
  assert.equal(rows.length, 1);
  const stored = String(rows[0]!.token_hash);
  assert.notEqual(stored, token);
  assert.match(stored, /^[0-9a-f]{64}$/);
  assert.ok(token.length >= 43);
});

test('expires after idle timeout', () => {
  const { db, adminId } = setup();
  const token = createSession(db, adminId, t0);
  assert.equal(resolveSession(db, token, t0 + SESSION_IDLE_MS + 1), null);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM sessions').get()?.n, 0);
});

test('sliding activity extends idle but not max', () => {
  const { db, adminId } = setup();
  const token = createSession(db, adminId, t0);
  const step = 11 * 3600_000;
  let now = t0;
  while (now + step < t0 + SESSION_MAX_MS) {
    now += step;
    assert.ok(resolveSession(db, token, now), `session should be alive at +${now - t0}ms`);
  }
  assert.equal(resolveSession(db, token, t0 + SESSION_MAX_MS + 1), null);
});

test('deleteSession logs out', () => {
  const { db, adminId } = setup();
  const token = createSession(db, adminId, t0);
  deleteSession(db, token);
  assert.equal(resolveSession(db, token, t0), null);
});

test('deleteOtherSessions keeps only the given token', () => {
  const { db, adminId } = setup();
  const keep = createSession(db, adminId, t0);
  const other = createSession(db, adminId, t0);
  deleteOtherSessions(db, adminId, keep);
  assert.ok(resolveSession(db, keep, t0));
  assert.equal(resolveSession(db, other, t0), null);
});
