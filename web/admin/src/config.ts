import { isAbsolute, resolve } from 'node:path';

export type Config = {
  port: number;
  dbPath: string;
  origin: string;
  cookieSecure: boolean;
  trustProxy: boolean;
  repoRoot: string;
  snapshotDir: string;
  bootstrap: { username: string; password: string } | null;
  github: { token: string; repo: string } | null;
  /** The group server's operator API (`/internal/admin/v1`); null turns the 신고 pages off. */
  adminApi: { baseUrl: string; token: string } | null;
};

/** Where the console reaches the group server over the shared Docker network. */
export const DEFAULT_ADMIN_API_URL = 'http://pilgrim-api:3100';
/** The server's own minimum for `ADMIN_API_TOKEN` (design.md 14절). */
const MIN_ADMIN_TOKEN_BYTES = 32;

export class ConfigError extends Error {
  override name = 'ConfigError';
}

type Env = Record<string, string | undefined>;

function nonEmpty(env: Env, key: string): string | undefined {
  const value = env[key]?.trim();
  return value ? value : undefined;
}

function path(env: Env, key: string, fallback: string, baseDir: string): string {
  const value = nonEmpty(env, key) ?? fallback;
  return isAbsolute(value) ? value : resolve(baseDir, value);
}

function pair<A extends string, B extends string>(
  env: Env,
  first: [envKey: string, name: A],
  second: [envKey: string, name: B],
): Record<A | B, string> | null {
  // Passwords are taken verbatim (no trim); presence is checked on the raw value.
  const a = env[first[0]];
  const b = env[second[0]];
  const hasA = a !== undefined && a !== '';
  const hasB = b !== undefined && b !== '';
  if (!hasA && !hasB) return null;
  if (!hasA || !hasB) {
    throw new ConfigError(`${first[0]} and ${second[0]} must be set together`);
  }
  return { [first[1]]: a, [second[1]]: b } as Record<A | B, string>;
}

/**
 * `ADMIN_API_TOKEN` turns the operator API on; `ADMIN_API_URL` (default `http://pilgrim-api:3100`) is
 * the server's internal address. The token is taken verbatim and never leaves the console process.
 */
function adminApi(env: Env): Config['adminApi'] {
  const token = env.ADMIN_API_TOKEN;
  const url = nonEmpty(env, 'ADMIN_API_URL');
  if (token === undefined || token === '') {
    if (url) throw new ConfigError('ADMIN_API_URL is set but ADMIN_API_TOKEN is not');
    return null;
  }
  if (Buffer.byteLength(token, 'utf8') < MIN_ADMIN_TOKEN_BYTES) {
    throw new ConfigError(`ADMIN_API_TOKEN must be at least ${MIN_ADMIN_TOKEN_BYTES} bytes`);
  }
  const baseText = url ?? DEFAULT_ADMIN_API_URL;
  let base: URL;
  try {
    base = new URL(baseText);
  } catch {
    throw new ConfigError(`ADMIN_API_URL is not a URL: "${baseText}"`);
  }
  if ((base.protocol !== 'http:' && base.protocol !== 'https:') || base.username || base.password || base.search || base.hash) {
    throw new ConfigError('ADMIN_API_URL must be a plain http(s) origin such as http://pilgrim-api:3100');
  }
  return { baseUrl: `${base.origin}${base.pathname}`.replace(/\/+$/, ''), token };
}

/** Reads the console configuration from environment variables; relative paths resolve against `baseDir`. */
export function loadConfig(env: Env, baseDir: string): Config {
  const origin = nonEmpty(env, 'ADMIN_ORIGIN');
  if (!origin) {
    throw new ConfigError('ADMIN_ORIGIN is required (e.g. https://pilgrim.delight-house.org)');
  }

  const portText = nonEmpty(env, 'PORT') ?? '8420';
  const port = Number(portText);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new ConfigError(`PORT must be an integer between 1 and 65535, got "${portText}"`);
  }

  const bootstrap = pair(env, ['ADMIN_BOOTSTRAP_USERNAME', 'username'], ['ADMIN_BOOTSTRAP_PASSWORD', 'password']);
  if (bootstrap) bootstrap.username = bootstrap.username.trim();

  return {
    port,
    dbPath: path(env, 'ADMIN_DB_PATH', 'data/admin.sqlite', baseDir),
    origin: origin.replace(/\/+$/, ''),
    cookieSecure: nonEmpty(env, 'ADMIN_COOKIE_SECURE') !== 'false',
    trustProxy: nonEmpty(env, 'TRUST_PROXY') === 'true',
    repoRoot: path(env, 'ADMIN_REPO_ROOT', '../..', baseDir),
    snapshotDir: path(env, 'ADMIN_SNAPSHOT_DIR', 'snapshot', baseDir),
    bootstrap,
    github: pair(env, ['GITHUB_TOKEN', 'token'], ['GITHUB_REPO', 'repo']),
    adminApi: adminApi(env),
  };
}
