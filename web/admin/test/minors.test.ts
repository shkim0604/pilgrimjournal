import assert from 'node:assert/strict';
import { test } from 'node:test';
import { ConfigError, loadConfig } from '../src/config.ts';
import { targetGraph } from '../src/content/mermaid.ts';
import { BOOT_PASS, get, login, loginReady, makeHarness, post, writeSnapshotDir } from './appHelpers.ts';

test('password length is counted on the NFC form', async () => {
  const h = await makeHarness();
  const cookie = await login(h);
  // Six Hangul syllables: 6 characters in NFC, 18 code points when macOS sends NFD.
  const next = '하나둘셋넷다'.normalize('NFD');
  const res = await post(h, '/admin/change-password', { current: BOOT_PASS, next, confirm: next }, { cookie });
  assert.equal(res.status, 400);
});

test('an NFD spelling of the current password counts as the same password', async () => {
  const h = await makeHarness({ bootstrap: { username: 'tester', password: '기도노트비밀번호하나둘' } });
  const cookie = await login(h, 'tester', '기도노트비밀번호하나둘');
  const next = '기도노트비밀번호하나둘'.normalize('NFD');
  const res = await post(h, '/admin/change-password', { current: '기도노트비밀번호하나둘', next, confirm: next }, { cookie });
  assert.equal(res.status, 400);
});

test('ADMIN_ORIGIN is normalised to the browser origin form', () => {
  assert.equal(loadConfig({ ADMIN_ORIGIN: 'https://Pilgrim.Example' }, '/srv').origin, 'https://pilgrim.example');
  assert.equal(loadConfig({ ADMIN_ORIGIN: 'https://pilgrim.example:443/' }, '/srv').origin, 'https://pilgrim.example');
});

test('ADMIN_ORIGIN with a path or a non-http scheme is refused', () => {
  for (const value of ['https://pilgrim.example/admin', 'pilgrim.example', 'ftp://pilgrim.example', 'https://pilgrim.example/?x=1']) {
    assert.throws(() => loadConfig({ ADMIN_ORIGIN: value }, '/srv'), ConfigError, value);
  }
});

test('a malformed form body gets 400 and no stack in the log', async () => {
  const h = await makeHarness();
  const res = await post(h, '/admin/login', {}, { headers: { 'content-type': 'multipart/form-data; boundary=zzz' } });
  assert.equal(res.status, 400);
  assert.ok(h.logs.every((line) => !line.includes('    at ')), h.logs.join('\n'));
});

test('a malformed form body on an authenticated form also gets 400', async () => {
  const h = await makeHarness();
  const cookie = await loginReady(h);
  const res = await post(h, '/admin/change-password', {}, { cookie, headers: { 'content-type': 'multipart/form-data; boundary=zzz' } });
  assert.equal(res.status, 400);
});

test('an unknown SwiftPM target kind still loads and renders the architecture page', async () => {
  const dir = writeSnapshotDir({
    'architecture.json': {
      targets: [
        { name: 'Core', kind: 'library', dependencies: [], linkedFrameworks: [] },
        { name: 'Macros', kind: 'macro', dependencies: ['Core'], linkedFrameworks: [] },
      ],
    },
  });
  const h = await makeHarness({ snapshotDir: dir });
  const cookie = await loginReady(h);
  const body = await (await get(h, '/admin/architecture', cookie)).text();
  assert.ok(body.includes('Macros'));
  assert.ok(!body.includes('형식이 예상과 다릅니다'));
  assert.ok(targetGraph({ targets: [{ name: 'Macros', kind: 'macro', dependencies: [], linkedFrameworks: [] }] }, false).includes('Macros["Macros"]'));
});
