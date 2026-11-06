import type { DatabaseSync } from 'node:sqlite';

export const LOGIN_WINDOW_MS = 15 * 60_000;
export const LOGIN_MAX_FAILURES = 5;
export const LOGIN_LOCK_MS = 15 * 60_000;

export function loginKey(ip: string, username: string): string {
  return `${ip}|${username}`;
}

export function isLocked(db: DatabaseSync, key: string, now: number): boolean {
  const row = db.prepare('SELECT locked_until FROM login_failures WHERE key = ?').get(key);
  return row?.locked_until != null && Number(row.locked_until) > now;
}

/** Counts a failure in the current window (restarting it once expired) and locks on the fifth. */
export function recordFailure(db: DatabaseSync, key: string, now: number): void {
  const row = db.prepare('SELECT count, first_failed_at FROM login_failures WHERE key = ?').get(key);
  const inWindow = row != null && now - Number(row.first_failed_at) <= LOGIN_WINDOW_MS;
  const count = inWindow ? Number(row.count) + 1 : 1;
  const firstFailedAt = inWindow ? Number(row.first_failed_at) : now;
  const lockedUntil = count >= LOGIN_MAX_FAILURES ? now + LOGIN_LOCK_MS : null;
  db.prepare(
    `INSERT INTO login_failures (key, count, first_failed_at, locked_until) VALUES (?, ?, ?, ?)
     ON CONFLICT(key) DO UPDATE SET count = excluded.count, first_failed_at = excluded.first_failed_at,
       locked_until = excluded.locked_until`,
  ).run(key, count, firstFailedAt, lockedUntil);
}

export function clearFailures(db: DatabaseSync, key: string): void {
  db.prepare('DELETE FROM login_failures WHERE key = ?').run(key);
}
