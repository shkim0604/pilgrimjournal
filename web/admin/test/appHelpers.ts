import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ensureBootstrapAdmin } from '../src/auth/bootstrap.ts';
import type { Config } from '../src/config.ts';
import { createApp, type AppDeps } from '../src/server.ts';
import { tempDatabase, tempDir } from './helpers.ts';

export const ORIGIN = 'https://pilgrim.test';
export const BOOT_USER = 'tester';
export const BOOT_PASS = 'initial-pass-1';
export const NEW_PASS = 'a-long-new-password';

export const webAdminDir = fileURLToPath(new URL('../', import.meta.url));
export const repoRoot = join(webAdminDir, '..', '..');

export type Harness = {
  app: ReturnType<typeof createApp>;
  deps: AppDeps;
  clock: { now: number };
  logs: string[];
};

export async function makeHarness(overrides: Partial<Config> = {}, extra: Partial<AppDeps> = {}): Promise<Harness> {
  const db = tempDatabase();
  const config: Config = {
    port: 8420,
    dbPath: ':memory:',
    origin: ORIGIN,
    cookieSecure: true,
    trustProxy: false,
    repoRoot,
    snapshotDir: join(webAdminDir, 'snapshot'),
    bootstrap: { username: BOOT_USER, password: BOOT_PASS },
    github: null,
    ...overrides,
  };
  await ensureBootstrapAdmin(db, config.bootstrap, () => {});
  const clock = { now: 1_800_000_000_000 };
  const logs: string[] = [];
  const deps: AppDeps = { db, config, now: () => clock.now, log: (m) => logs.push(m), ...extra };
  return { app: createApp(deps), deps, clock, logs };
}

export function form(fields: Record<string, string>): URLSearchParams {
  return new URLSearchParams(fields);
}

export async function post(
  h: Harness,
  path: string,
  fields: Record<string, string>,
  opts: { cookie?: string; origin?: string | null; headers?: Record<string, string> } = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    'content-type': 'application/x-www-form-urlencoded',
    ...opts.headers,
  };
  if (opts.origin !== null) headers.origin = opts.origin ?? ORIGIN;
  if (opts.cookie) headers.cookie = opts.cookie;
  return h.app.request(path, { method: 'POST', headers, body: form(fields) });
}

export async function get(h: Harness, path: string, cookie?: string): Promise<Response> {
  return h.app.request(path, cookie ? { headers: { cookie } } : {});
}

/** Extracts `pilgrim_admin=<token>` from a response's Set-Cookie header. */
export function sessionCookie(res: Response): string {
  const header = res.headers.get('set-cookie') ?? '';
  const match = /pilgrim_admin=([^;]*)/.exec(header);
  if (!match || !match[1]) throw new Error(`no session cookie in: ${header}`);
  return `pilgrim_admin=${match[1]}`;
}

export async function login(h: Harness, username = BOOT_USER, password = BOOT_PASS): Promise<string> {
  const res = await post(h, '/admin/login', { username, password });
  if (res.status !== 302) throw new Error(`login failed with ${res.status}`);
  return sessionCookie(res);
}

/** Logs in with the bootstrap password and completes the forced change; returns the new session cookie. */
export async function loginReady(h: Harness): Promise<string> {
  const first = await login(h);
  const res = await post(
    h,
    '/admin/change-password',
    { current: BOOT_PASS, next: NEW_PASS, confirm: NEW_PASS },
    { cookie: first },
  );
  if (res.status !== 302) throw new Error(`password change failed with ${res.status}`);
  return sessionCookie(res);
}

export function writeSnapshotDir(files: Record<string, unknown>): string {
  const dir = tempDir('pilgrim-admin-snap-');
  mkdirSync(dir, { recursive: true });
  for (const [name, value] of Object.entries(files)) {
    writeFileSync(join(dir, name), typeof value === 'string' ? value : JSON.stringify(value));
  }
  return dir;
}
