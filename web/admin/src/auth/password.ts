import { randomBytes, scrypt, timingSafeEqual, type ScryptOptions } from 'node:crypto';

const N = 32768;
const R = 8;
const P = 1;
const KEY_LENGTH = 64;
const SALT_LENGTH = 16;

function derive(plain: string, salt: Buffer, options: ScryptOptions, keyLength: number): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(plain.normalize('NFC'), salt, keyLength, options, (error, key) =>
      error ? reject(error) : resolve(key),
    );
  });
}

function params(n: number, r: number, p: number): ScryptOptions {
  return { N: n, r, p, maxmem: 128 * n * r * 2 + 1024 * 1024 };
}

/** Hashes a password as `scrypt$N$r$p$<salt b64>$<hash b64>`, NFC-normalising it first. */
export async function hashPassword(plain: string): Promise<string> {
  const salt = randomBytes(SALT_LENGTH);
  const hash = await derive(plain, salt, params(N, R, P), KEY_LENGTH);
  return ['scrypt', N, R, P, salt.toString('base64'), hash.toString('base64')].join('$');
}

/** Checks a password against a stored hash; a malformed stored value is simply a mismatch. */
export async function verifyPassword(plain: string, stored: string): Promise<boolean> {
  const parts = stored.split('$');
  if (parts.length !== 6 || parts[0] !== 'scrypt') return false;
  const [n, r, p] = parts.slice(1, 4).map(Number) as [number, number, number];
  if (![n, r, p].every((value) => Number.isInteger(value) && value > 0)) return false;
  // Refuse parameters far outside what this module writes, so a tampered row cannot pin the CPU.
  if (n > N * 4 || r > 32 || p > 16) return false;
  const salt = Buffer.from(parts[4]!, 'base64');
  const expected = Buffer.from(parts[5]!, 'base64');
  if (salt.length === 0 || expected.length === 0) return false;
  try {
    const actual = await derive(plain, salt, params(n, r, p), expected.length);
    return timingSafeEqual(actual, expected);
  } catch {
    return false;
  }
}

/** Spends the same work as one verification, so unknown usernames answer as slowly as wrong passwords. */
export async function burnPasswordCheck(plain: string): Promise<void> {
  await derive(plain, randomBytes(SALT_LENGTH), params(N, R, P), KEY_LENGTH);
}
