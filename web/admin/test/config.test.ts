import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { test } from 'node:test';
import { ConfigError, loadConfig } from '../src/config.ts';

const base = '/srv/admin';
const minimal = { ADMIN_ORIGIN: 'https://pilgrim.test' };

test('throws ConfigError when ADMIN_ORIGIN is missing', () => {
  assert.throws(() => loadConfig({}, base), ConfigError);
});

test('applies defaults', () => {
  const config = loadConfig(minimal, base);
  assert.equal(config.port, 8420);
  assert.equal(config.cookieSecure, true);
  assert.equal(config.trustProxy, false);
  assert.equal(config.dbPath, resolve(base, 'data/admin.sqlite'));
  assert.equal(config.repoRoot, resolve(base, '../..'));
  assert.equal(config.snapshotDir, resolve(base, 'snapshot'));
  assert.equal(config.bootstrap, null);
  assert.equal(config.github, null);
});

test('strips trailing slash from origin', () => {
  assert.equal(loadConfig({ ADMIN_ORIGIN: 'https://x.test/' }, base).origin, 'https://x.test');
});

test('throws when only one bootstrap variable is set', () => {
  assert.throws(
    () => loadConfig({ ...minimal, ADMIN_BOOTSTRAP_USERNAME: 'someone' }, base),
    ConfigError,
  );
  assert.throws(
    () => loadConfig({ ...minimal, ADMIN_BOOTSTRAP_PASSWORD: 'secret' }, base),
    ConfigError,
  );
});

test('reads bootstrap pair', () => {
  const config = loadConfig(
    { ...minimal, ADMIN_BOOTSTRAP_USERNAME: 'someone', ADMIN_BOOTSTRAP_PASSWORD: 'secret' },
    base,
  );
  assert.deepEqual(config.bootstrap, { username: 'someone', password: 'secret' });
});

test('reads flags, port, absolute paths and github pair', () => {
  const config = loadConfig(
    {
      ...minimal,
      PORT: '9000',
      ADMIN_COOKIE_SECURE: 'false',
      TRUST_PROXY: 'true',
      ADMIN_DB_PATH: '/data/admin.sqlite',
      GITHUB_TOKEN: 't',
      GITHUB_REPO: 'o/r',
    },
    base,
  );
  assert.equal(config.port, 9000);
  assert.equal(config.cookieSecure, false);
  assert.equal(config.trustProxy, true);
  assert.equal(config.dbPath, '/data/admin.sqlite');
  assert.deepEqual(config.github, { token: 't', repo: 'o/r' });
});

test('rejects an invalid port', () => {
  assert.throws(() => loadConfig({ ...minimal, PORT: 'abc' }, base), ConfigError);
});
