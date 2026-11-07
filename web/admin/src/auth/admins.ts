import type { DatabaseSync } from 'node:sqlite';

export type Admin = {
  id: number;
  username: string;
  passwordHash: string;
  mustChangePassword: boolean;
};

type AdminRow = {
  id: number;
  username: string;
  password_hash: string;
  must_change_password: number;
};

function toAdmin(row: AdminRow | undefined): Admin | null {
  if (!row) return null;
  return {
    id: Number(row.id),
    username: row.username,
    passwordHash: row.password_hash,
    mustChangePassword: Number(row.must_change_password) === 1,
  };
}

const columns = 'id, username, password_hash, must_change_password';

export function countAdmins(db: DatabaseSync): number {
  return Number(db.prepare('SELECT COUNT(*) AS n FROM admins').get()?.n ?? 0);
}

export function findAdminByUsername(db: DatabaseSync, username: string): Admin | null {
  return toAdmin(
    db.prepare(`SELECT ${columns} FROM admins WHERE username = ?`).get(username) as AdminRow | undefined,
  );
}

export function findAdminById(db: DatabaseSync, id: number): Admin | null {
  return toAdmin(db.prepare(`SELECT ${columns} FROM admins WHERE id = ?`).get(id) as AdminRow | undefined);
}

export function insertAdmin(
  db: DatabaseSync,
  username: string,
  passwordHash: string,
  mustChange: boolean,
  now: number,
): number {
  const result = db
    .prepare(
      'INSERT INTO admins (username, password_hash, must_change_password, created_at, updated_at) VALUES (?, ?, ?, ?, ?)',
    )
    .run(username, passwordHash, mustChange ? 1 : 0, now, now);
  return Number(result.lastInsertRowid);
}

/** Replaces the password and clears the forced-change flag. */
export function updateAdminPassword(db: DatabaseSync, id: number, passwordHash: string, now: number): void {
  db.prepare('UPDATE admins SET password_hash = ?, must_change_password = 0, updated_at = ? WHERE id = ?').run(
    passwordHash,
    now,
    id,
  );
}
