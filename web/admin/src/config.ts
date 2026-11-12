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
};

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
  };
}
