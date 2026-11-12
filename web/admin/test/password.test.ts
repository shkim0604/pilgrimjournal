import assert from 'node:assert/strict';
import { test } from 'node:test';
import { burnPasswordCheck, hashPassword, verifyPassword } from '../src/auth/password.ts';

test('round-trips a password', async () => {
  const stored = await hashPassword('correct horse battery');
  assert.equal(await verifyPassword('correct horse battery', stored), true);
});

test('rejects a wrong password', async () => {
  const stored = await hashPassword('correct horse battery');
  assert.equal(await verifyPassword('correct horse batterz', stored), false);
});

test('uses the pinned format', async () => {
  const stored = await hashPassword('pw');
  assert.match(stored, /^scrypt\$32768\$8\$1\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$/);
  const [, , , , salt, hash] = stored.split('$');
  assert.equal(Buffer.from(salt!, 'base64').length, 16);
  assert.equal(Buffer.from(hash!, 'base64').length, 64);
});

test('produces different salts for the same password', async () => {
  assert.notEqual(await hashPassword('same'), await hashPassword('same'));
});

test('returns false for malformed stored value', async () => {
  assert.equal(await verifyPassword('pw', 'nope'), false);
  assert.equal(await verifyPassword('pw', 'scrypt$1$2'), false);
  assert.equal(await verifyPassword('pw', 'scrypt$abc$8$1$AAAA$AAAA'), false);
});

test('verifies NFD input against NFC hash', async () => {
  const stored = await hashPassword('기도'.normalize('NFC'));
  assert.equal(await verifyPassword('기도'.normalize('NFD'), stored), true);
});

test('burnPasswordCheck resolves without throwing', async () => {
  await burnPasswordCheck('anything');
});
