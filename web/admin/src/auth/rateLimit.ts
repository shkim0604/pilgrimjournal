import type { DatabaseSync } from 'node:sqlite';

export const LOGIN_WINDOW_MS = 15 * 60_000;
export const LOGIN_MAX_FAILURES = 5;
export const LOGIN_LOCK_MS = 15 * 60_000;

/** Expands an IPv6 address to its eight hextets, or returns null when it is not one. */
function ipv6Hextets(ip: string): string[] | null {
  if (!ip.includes(':')) return null;
  const [head = '', tail] = ip.split('::');
  const left = head ? head.split(':') : [];
  const right = tail ? tail.split(':') : [];
  if (tail === undefined && left.length !== 8) return null;
  const fill = Array.from({ length: 8 - left.length - right.length }, () => '0');
  const parts = tail === undefined ? left : [...left, ...fill, ...right];
  if (parts.length !== 8 || !parts.every((p) => /^[0-9a-f]{1,4}$/i.test(p))) return null;
  return parts.map((p) => parseInt(p, 16).toString(16));
}

/**
 * The address part of a lockout key. IPv4-mapped IPv6 becomes plain IPv4, and other IPv6
 * addresses collapse to their /64 so rotating addresses inside one allocation shares a key.
 */
export function addressKey(ip: string): string {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip);
  if (mapped) return mapped[1]!;
  const hextets = ipv6Hextets(ip);
  return hextets ? `${hextets.slice(0, 4).join(':')}::/64` : ip;
}

export function loginKey(ip: string, username: string): string {
  return `${addressKey(ip)}|${username}`;
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

/**
 * Counts the attempt before the password is checked, so concurrent requests cannot all slip in
 * ahead of the lock. Returns false when the key is locked; a successful login calls clearFailures.
 */
export function beginAttempt(db: DatabaseSync, key: string, now: number): boolean {
  if (isLocked(db, key, now)) return false;
  recordFailure(db, key, now);
  return true;
}

export function clearFailures(db: DatabaseSync, key: string): void {
  db.prepare('DELETE FROM login_failures WHERE key = ?').run(key);
}
