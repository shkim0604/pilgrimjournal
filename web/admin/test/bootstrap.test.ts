import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { countAdmins, findAdminByUsername, updateAdminPassword } from '../src/auth/admins.ts';
import { BootstrapError, ensureBootstrapAdmin } from '../src/auth/bootstrap.ts';
import { hashPassword, verifyPassword } from '../src/auth/password.ts';
import { tempDatabase } from './helpers.ts';

const bootstrap = { username: 'seed-user', password: 'seed-password-value' };

test('seeds admin with must_change_password on empty db', async () => {
  const db = tempDatabase();
  const result = await ensureBootstrapAdmin(db, bootstrap, () => {});
  assert.equal(result, 'seeded');
  assert.equal(countAdmins(db), 1);
  const admin = findAdminByUsername(db, 'seed-user');
  assert.ok(admin);
  assert.equal(admin.mustChangePassword, true);
  assert.equal(await verifyPassword('seed-password-value', admin.passwordHash), true);
});

test('does not reset password when admin exists', async () => {
  const db = tempDatabase();
  await ensureBootstrapAdmin(db, bootstrap, () => {});
  const admin = findAdminByUsername(db, 'seed-user')!;
  const changed = await hashPassword('a-much-better-password');
  updateAdminPassword(db, admin.id, changed, Date.now());

  const logs: string[] = [];
  const result = await ensureBootstrapAdmin(db, bootstrap, (message) => logs.push(message));

  assert.equal(result, 'ignored');
  const after = findAdminByUsername(db, 'seed-user')!;
  assert.equal(after.passwordHash, changed);
  assert.equal(after.mustChangePassword, false);
  assert.deepEqual(logs, ['bootstrap ignored: admin already exists']);
  assert.ok(logs.every((line) => !line.includes(bootstrap.password)));
});

test('returns existing when admin exists and no bootstrap is configured', async () => {
  const db = tempDatabase();
  await ensureBootstrapAdmin(db, bootstrap, () => {});
  assert.equal(await ensureBootstrapAdmin(db, null, () => {}), 'existing');
});

test('throws BootstrapError on empty db without bootstrap', async () => {
  const db = tempDatabase();
  await assert.rejects(ensureBootstrapAdmin(db, null, () => {}), BootstrapError);
});

test('src has no default credential literals', () => {
  const srcDir = fileURLToPath(new URL('../src/', import.meta.url));
  const files = readdirSync(srcDir, { recursive: true, encoding: 'utf8' }).filter((f) => f.endsWith('.ts'));
  assert.ok(files.length > 0);
  for (const file of files) {
    const text = readFileSync(join(srcDir, file), 'utf8');
    assert.doesNotMatch(text, /['"`]admin['"`]/, `${file} contains a default credential literal`);
  }
});
