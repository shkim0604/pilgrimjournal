import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  LOGIN_LOCK_MS,
  LOGIN_MAX_FAILURES,
  LOGIN_MAX_PER_ADDRESS,
  LOGIN_WINDOW_MS,
  beginAttempt,
  clearFailures,
  ipKey,
  isLocked,
  loginKey,
  pruneFailures,
  recordFailure,
} from '../src/auth/rateLimit.ts';
import { tempDatabase } from './helpers.ts';

const t0 = 1_800_000_000_000;
const key = loginKey('203.0.113.7', 'someone');

function fail(db: ReturnType<typeof tempDatabase>, times: number, start = t0) {
  for (let i = 0; i < times; i++) recordFailure(db, key, start + i * 1000);
}

test('pins the spec values', () => {
  assert.equal(LOGIN_MAX_FAILURES, 5);
  assert.equal(LOGIN_WINDOW_MS, 15 * 60_000);
  assert.equal(LOGIN_LOCK_MS, 15 * 60_000);
});

test('locks after five failures within the window', () => {
  const db = tempDatabase();
  fail(db, 5);
  assert.equal(isLocked(db, key, t0 + 5000), true);
});

test('four failures do not lock', () => {
  const db = tempDatabase();
  fail(db, 4);
  assert.equal(isLocked(db, key, t0 + 4000), false);
});

test('unlocks after lock period', () => {
  const db = tempDatabase();
  fail(db, 5);
  const lockedAt = t0 + 4000;
  assert.equal(isLocked(db, key, lockedAt + LOGIN_LOCK_MS - 1), true);
  assert.equal(isLocked(db, key, lockedAt + LOGIN_LOCK_MS + 1), false);
});

test('failures outside the window restart the count', () => {
  const db = tempDatabase();
  fail(db, 4);
  recordFailure(db, key, t0 + 16 * 60_000);
  assert.equal(isLocked(db, key, t0 + 16 * 60_000), false);
});

test('clearFailures resets', () => {
  const db = tempDatabase();
  fail(db, 4);
  clearFailures(db, key);
  recordFailure(db, key, t0 + 5000);
  assert.equal(isLocked(db, key, t0 + 5000), false);
});

test('beginAttempt honours a custom cap', () => {
  const db = tempDatabase();
  const addr = ipKey('203.0.113.7');
  for (let i = 0; i < LOGIN_MAX_PER_ADDRESS; i++) assert.equal(beginAttempt(db, addr, t0 + i, LOGIN_MAX_PER_ADDRESS), true);
  assert.equal(beginAttempt(db, addr, t0 + 100, LOGIN_MAX_PER_ADDRESS), false);
  assert.notEqual(addr, loginKey('203.0.113.7', ''));
});

test('pruneFailures removes only rows past their window with no live lock', () => {
  const db = tempDatabase();
  recordFailure(db, 'stale', t0);
  fail(db, 5, t0); // `key` is locked until t0 + 4000 + LOGIN_LOCK_MS
  recordFailure(db, 'fresh', t0 + LOGIN_WINDOW_MS);
  const keys = () => db.prepare('SELECT key FROM login_failures ORDER BY key').all().map((row) => String(row.key));

  pruneFailures(db, t0 + LOGIN_WINDOW_MS + 1);
  assert.deepEqual(keys(), [key, 'fresh']);
  pruneFailures(db, t0 + 4000 + LOGIN_LOCK_MS);
  assert.deepEqual(keys(), ['fresh']);
});

test('keys differ per ip and username', () => {
  assert.notEqual(loginKey('203.0.113.7', 'a'), loginKey('203.0.113.8', 'a'));
  assert.notEqual(loginKey('203.0.113.7', 'a'), loginKey('203.0.113.7', 'b'));
  const db = tempDatabase();
  fail(db, 5);
  assert.equal(isLocked(db, loginKey('203.0.113.7', 'other'), t0 + 5000), false);
});
