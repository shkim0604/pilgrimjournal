import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ensureBootstrapAdmin } from '../src/auth/bootstrap.ts';
import { loginKey } from '../src/auth/rateLimit.ts';
import { BOOT_PASS, BOOT_USER, makeHarness, post } from './appHelpers.ts';
import { tempDatabase } from './helpers.ts';

test('concurrent wrong logins evaluate at most five attempts', async () => {
  const h = await makeHarness();
  const responses = await Promise.all(
    Array.from({ length: 20 }, () => post(h, '/admin/login', { username: BOOT_USER, password: 'wrong-password' })),
  );
  const statuses = responses.map((res) => res.status);
  assert.equal(statuses.filter((s) => s === 401).length, 5);
  assert.equal(statuses.filter((s) => s === 429).length, 15);
});

test('a correct password at the end of a concurrent burst is still locked out', async () => {
  const h = await makeHarness();
  const burst = Array.from({ length: 10 }, () => post(h, '/admin/login', { username: BOOT_USER, password: 'wrong-password' }));
  burst.push(post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS }));
  const statuses = (await Promise.all(burst)).map((res) => res.status);
  assert.equal(statuses.at(-1), 429);
});

test('IPv6 addresses in the same /64 share a lockout key', () => {
  assert.equal(loginKey('2001:db8:1:2:aaaa::1', 'u'), loginKey('2001:db8:1:2:bbbb:cccc:dddd:2', 'u'));
  assert.equal(loginKey('2001:db8:1:2::1', 'u'), loginKey('2001:0db8:0001:0002:ffff::9', 'u'));
  assert.notEqual(loginKey('2001:db8:1:2::1', 'u'), loginKey('2001:db8:1:3::1', 'u'));
  assert.equal(loginKey('::ffff:203.0.113.7', 'u'), loginKey('203.0.113.7', 'u'));
  assert.notEqual(loginKey('203.0.113.7', 'u'), loginKey('203.0.113.8', 'u'));
});

test('IPv6 rotation within a /64 hits the lockout', async () => {
  const h = await makeHarness({ trustProxy: true });
  for (let i = 1; i <= 5; i++) {
    await post(h, '/admin/login', { username: BOOT_USER, password: 'wrong' }, { headers: { 'cf-connecting-ip': `2001:db8:1:2::${i}` } });
  }
  const next = await post(
    h,
    '/admin/login',
    { username: BOOT_USER, password: BOOT_PASS },
    { headers: { 'cf-connecting-ip': '2001:db8:1:2::99' } },
  );
  assert.equal(next.status, 429);
});

test('oversized POST body is rejected with 413', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', { username: BOOT_USER, password: 'x'.repeat(20_000) });
  assert.equal(res.status, 413);
});

test('overlong username is rejected without storing it', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', { username: 'u'.repeat(200), password: 'whatever' });
  assert.equal(res.status, 400);
  const keys = h.deps.db.prepare('SELECT key FROM login_failures').all();
  assert.ok(keys.every((row) => String(row.key).length < 150));
  assert.ok(!(await res.text()).includes('u'.repeat(200)));
});

test('seeding a weak bootstrap password logs a warning', async () => {
  const logs: string[] = [];
  await ensureBootstrapAdmin(tempDatabase(), { username: 'admin-user', password: 'short' }, (m) => logs.push(m));
  assert.ok(logs.some((line) => line.includes('WARNING')));
  assert.ok(logs.every((line) => !line.includes('short')));
});

test('seeding a strong bootstrap password does not warn', async () => {
  const logs: string[] = [];
  await ensureBootstrapAdmin(tempDatabase(), { username: 'admin-user', password: 'a-strong-bootstrap-pw' }, (m) => logs.push(m));
  assert.ok(logs.every((line) => !line.includes('WARNING')));
});
