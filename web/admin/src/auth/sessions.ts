import { createHash, randomBytes } from 'node:crypto';
import type { DatabaseSync } from 'node:sqlite';

export const SESSION_IDLE_MS = 12 * 3600_000;
export const SESSION_MAX_MS = 7 * 86_400_000;

export type SessionInfo = { adminId: number; username: string; mustChangePassword: boolean };

function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

/** Issues a new random token; only its SHA-256 is stored. */
export function createSession(db: DatabaseSync, adminId: number, now: number): string {
  const token = randomBytes(32).toString('base64url');
  db.prepare('INSERT INTO sessions (token_hash, admin_id, created_at, last_seen_at) VALUES (?, ?, ?, ?)').run(
    hashToken(token),
    adminId,
    now,
    now,
  );
  return token;
}

/** Returns the session's admin, sliding its idle window; expired sessions are deleted and yield null. */
export function resolveSession(db: DatabaseSync, token: string, now: number): SessionInfo | null {
  const tokenHash = hashToken(token);
  const row = db
    .prepare(
      `SELECT s.admin_id, s.created_at, s.last_seen_at, a.username, a.must_change_password
       FROM sessions s JOIN admins a ON a.id = s.admin_id WHERE s.token_hash = ?`,
    )
    .get(tokenHash);
  if (!row) return null;

  const createdAt = Number(row.created_at);
  const lastSeenAt = Number(row.last_seen_at);
  if (now - lastSeenAt > SESSION_IDLE_MS || now - createdAt > SESSION_MAX_MS) {
    db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(tokenHash);
    return null;
  }
  db.prepare('UPDATE sessions SET last_seen_at = ? WHERE token_hash = ?').run(now, tokenHash);
  return {
    adminId: Number(row.admin_id),
    username: String(row.username),
    mustChangePassword: Number(row.must_change_password) === 1,
  };
}

export function deleteSession(db: DatabaseSync, token: string): void {
  db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(hashToken(token));
}

export function deleteOtherSessions(db: DatabaseSync, adminId: number, keepToken: string): void {
  db.prepare('DELETE FROM sessions WHERE admin_id = ? AND token_hash != ?').run(adminId, hashToken(keepToken));
}
