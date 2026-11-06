import type { DatabaseSync } from 'node:sqlite';
import type { Config } from '../config.ts';
import { countAdmins, insertAdmin } from './admins.ts';
import { hashPassword } from './password.ts';

export class BootstrapError extends Error {
  override name = 'BootstrapError';
}

/**
 * Creates the first admin from ADMIN_BOOTSTRAP_* only while no admin exists, flagged to change the
 * password on first login. Once an account exists the bootstrap values are never used again.
 */
export async function ensureBootstrapAdmin(
  db: DatabaseSync,
  bootstrap: Config['bootstrap'],
  log: (message: string) => void,
  now: number = Date.now(),
): Promise<'seeded' | 'ignored' | 'existing'> {
  if (countAdmins(db) > 0) {
    if (!bootstrap) return 'existing';
    log('bootstrap ignored: admin already exists');
    return 'ignored';
  }
  if (!bootstrap) {
    throw new BootstrapError(
      'No admin account exists. Set ADMIN_BOOTSTRAP_USERNAME and ADMIN_BOOTSTRAP_PASSWORD for the first start.',
    );
  }
  insertAdmin(db, bootstrap.username, await hashPassword(bootstrap.password), true, now);
  log(`bootstrap: created admin "${bootstrap.username}"; password change required on first login`);
  if ([...bootstrap.password].length < 12 || bootstrap.password === bootstrap.username) {
    log(
      'WARNING: the bootstrap password is weak and documented in .env.example. Log in and change it ' +
        'before the console is reachable from the internet (see docs/development.md, 관리 콘솔).',
    );
  }
  return 'seeded';
}
