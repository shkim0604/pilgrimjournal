import assert from 'node:assert/strict';
import { test } from 'node:test';
import {
  BOOT_PASS,
  BOOT_USER,
  NEW_PASS,
  ORIGIN,
  get,
  login,
  loginReady,
  makeHarness,
  post,
  sessionCookie,
} from './appHelpers.ts';

test('healthz returns ok', async () => {
  const h = await makeHarness();
  const res = await get(h, '/healthz');
  assert.equal(res.status, 200);
  assert.equal(await res.text(), 'ok');
});

test('root serves the support page', async () => {
  const h = await makeHarness();
  const res = await get(h, '/');
  assert.equal(res.status, 200);
  assert.match(await res.text(), /Pilgrim Journal/);
});

test('unauthenticated /admin redirects to /admin/login', async () => {
  const h = await makeHarness();
  const res = await get(h, '/admin');
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), '/admin/login');
});

test('login page renders a form', async () => {
  const h = await makeHarness();
  const res = await get(h, '/admin/login');
  assert.equal(res.status, 200);
  const body = await res.text();
  assert.match(body, /<form[^>]+method="post"/);
  assert.match(body, /name="username"/);
  assert.match(body, /name="password"/);
});

test('login sets HttpOnly Secure SameSite=Strict cookie on /admin path', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS });
  assert.equal(res.status, 302);
  const cookie = res.headers.get('set-cookie') ?? '';
  assert.match(cookie, /pilgrim_admin=/);
  assert.match(cookie, /HttpOnly/i);
  assert.match(cookie, /Secure/i);
  assert.match(cookie, /SameSite=Strict/i);
  assert.match(cookie, /Path=\/admin/);
});

test('cookie omits Secure when cookieSecure is false', async () => {
  const h = await makeHarness({ cookieSecure: false });
  const res = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS });
  assert.doesNotMatch(res.headers.get('set-cookie') ?? '', /Secure/i);
});

test('first login redirects to change-password and blocks other pages', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS });
  assert.equal(res.headers.get('location'), '/admin/change-password');
  const cookie = sessionCookie(res);
  const page = await get(h, '/admin', cookie);
  assert.equal(page.status, 302);
  assert.equal(page.headers.get('location'), '/admin/change-password');
  const form = await get(h, '/admin/change-password', cookie);
  assert.equal(form.status, 200);
});

test('rejects new password shorter than 12, equal to username, or equal to the bootstrap password', async () => {
  const h = await makeHarness({ bootstrap: { username: 'long-username-x', password: 'bootstrap-pass-1' } });
  const cookie = await login(h, 'long-username-x', 'bootstrap-pass-1');
  for (const next of ['short-pass1', 'long-username-x', 'bootstrap-pass-1']) {
    const res = await post(h, '/admin/change-password', { current: 'bootstrap-pass-1', next, confirm: next }, { cookie });
    assert.equal(res.status, 400, `expected 400 for "${next}"`);
  }
});

test('rejects wrong current password and mismatched confirmation', async () => {
  const h = await makeHarness();
  const cookie = await login(h);
  const wrong = await post(h, '/admin/change-password', { current: 'nope', next: NEW_PASS, confirm: NEW_PASS }, { cookie });
  assert.equal(wrong.status, 400);
  const mismatch = await post(
    h,
    '/admin/change-password',
    { current: BOOT_PASS, next: NEW_PASS, confirm: `${NEW_PASS}x` },
    { cookie },
  );
  assert.equal(mismatch.status, 400);
});

test('password change unlocks pages and the new password works', async () => {
  const h = await makeHarness();
  const cookie = await loginReady(h);
  const page = await get(h, '/admin', cookie);
  assert.notEqual(page.headers.get('location'), '/admin/change-password');
  const relogin = await post(h, '/admin/login', { username: BOOT_USER, password: NEW_PASS });
  assert.equal(relogin.status, 302);
  assert.equal(relogin.headers.get('location'), '/admin');
});

test('password change revokes other sessions', async () => {
  const h = await makeHarness();
  const a = await login(h);
  const b = await login(h);
  const res = await post(h, '/admin/change-password', { current: BOOT_PASS, next: NEW_PASS, confirm: NEW_PASS }, { cookie: a });
  assert.equal(res.status, 302);
  const old = await get(h, '/admin', b);
  assert.equal(old.headers.get('location'), '/admin/login');
  const previous = await get(h, '/admin', a);
  assert.equal(previous.headers.get('location'), '/admin/login', 'the pre-change token is replaced too');
});

test('wrong password and unknown user give the same message', async () => {
  const h = await makeHarness();
  const wrong = await post(h, '/admin/login', { username: BOOT_USER, password: 'wrong-password' });
  const unknown = await post(h, '/admin/login', { username: 'nobody', password: 'wrong-password' });
  assert.equal(wrong.status, 401);
  assert.equal(unknown.status, 401);
  const message = '아이디 또는 비밀번호가 올바르지 않습니다.';
  assert.ok((await wrong.text()).includes(message));
  assert.ok((await unknown.text()).includes(message));
});

test('sixth attempt after five failures returns 429', async () => {
  const h = await makeHarness();
  for (let i = 0; i < 5; i++) {
    const res = await post(h, '/admin/login', { username: BOOT_USER, password: 'wrong-password' });
    assert.equal(res.status, 401);
  }
  const locked = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS });
  assert.equal(locked.status, 429);
  assert.ok((await locked.text()).includes('잠시 후 다시 시도하세요'));
});

test('lockout uses CF-Connecting-IP only behind a trusted proxy', async () => {
  const h = await makeHarness({ trustProxy: true });
  for (let i = 0; i < 5; i++) {
    await post(h, '/admin/login', { username: BOOT_USER, password: 'wrong' }, { headers: { 'cf-connecting-ip': '198.51.100.1' } });
  }
  const sameIp = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS }, { headers: { 'cf-connecting-ip': '198.51.100.1' } });
  assert.equal(sameIp.status, 429);
  const otherIp = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS }, { headers: { 'cf-connecting-ip': '198.51.100.2' } });
  assert.equal(otherIp.status, 302);
});

test('trims username on login', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', { username: ` ${BOOT_USER} `, password: BOOT_PASS });
  assert.equal(res.status, 302);
});

test('rejects POST with foreign Origin', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS }, { origin: 'https://evil.test' });
  assert.equal(res.status, 403);
});

test('rejects POST without Origin or Referer', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', { username: BOOT_USER, password: BOOT_PASS }, { origin: null });
  assert.equal(res.status, 403);
});

test('accepts Referer from the admin origin when Origin is absent', async () => {
  const h = await makeHarness();
  const res = await post(
    h,
    '/admin/login',
    { username: BOOT_USER, password: BOOT_PASS },
    { origin: null, headers: { referer: `${ORIGIN}/admin/login` } },
  );
  assert.equal(res.status, 302);
});

test('accepts POST whose Origin equals ADMIN_ORIGIN regardless of Host', async () => {
  const h = await makeHarness();
  const res = await post(
    h,
    '/admin/login',
    { username: BOOT_USER, password: BOOT_PASS },
    { headers: { host: 'localhost:8420' } },
  );
  assert.notEqual(res.status, 403);
  assert.equal(res.status, 302);
});

test('expired session POST redirects to login', async () => {
  const h = await makeHarness();
  const cookie = await login(h);
  h.clock.now += 8 * 86_400_000;
  const res = await post(h, '/admin/change-password', { current: BOOT_PASS, next: NEW_PASS, confirm: NEW_PASS }, { cookie });
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), '/admin/login');
});

test('sets CSP and no-store on admin responses', async () => {
  const h = await makeHarness();
  const res = await get(h, '/admin/login');
  const csp = res.headers.get('content-security-policy') ?? '';
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /script-src 'self'(;|$)/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.equal(res.headers.get('x-frame-options'), 'DENY');
  assert.equal(res.headers.get('referrer-policy'), 'same-origin');
  assert.equal(res.headers.get('cache-control'), 'no-store');
});

test('logout clears the session', async () => {
  const h = await makeHarness();
  const cookie = await loginReady(h);
  const res = await post(h, '/admin/logout', {}, { cookie });
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), '/admin/login');
  const after = await get(h, '/admin', cookie);
  assert.equal(after.headers.get('location'), '/admin/login');
});

test('static serves mermaid and rejects unknown files', async () => {
  const h = await makeHarness();
  const mermaid = await get(h, '/admin/static/mermaid.min.js');
  assert.equal(mermaid.status, 200);
  assert.match(mermaid.headers.get('content-type') ?? '', /javascript/);
  const css = await get(h, '/admin/static/app.css');
  assert.equal(css.status, 200);
  assert.match(css.headers.get('content-type') ?? '', /text\/css/);
  assert.equal((await get(h, '/admin/static/../config.ts')).status, 404);
  assert.equal((await get(h, '/admin/static/config.ts')).status, 404);
});

test('unexpected error renders generic page without stack', async () => {
  const h = await makeHarness();
  h.app.get('/admin/boom', () => {
    throw new Error('kaboom at /secret/path.ts');
  });
  const res = await get(h, '/admin/boom');
  assert.equal(res.status, 500);
  const body = await res.text();
  assert.doesNotMatch(body, /kaboom|secret\/path|Error:/);
  assert.ok(h.logs.some((line) => line.includes('kaboom')));
});
