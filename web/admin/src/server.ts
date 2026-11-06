import { Hono, type Context } from 'hono';
import { bodyLimit } from 'hono/body-limit';
import { deleteCookie, setCookie } from 'hono/cookie';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import type { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { findAdminById, findAdminByUsername, updateAdminPassword } from './auth/admins.ts';
import {
  SESSION_COOKIE,
  clientIp,
  originCheck,
  requireSession,
  securityHeaders,
  type AppEnv,
} from './auth/middleware.ts';
import { burnPasswordCheck, hashPassword, verifyPassword } from './auth/password.ts';
import { beginAttempt, clearFailures, loginKey } from './auth/rateLimit.ts';
import { SESSION_MAX_MS, createSession, deleteOtherSessions, deleteSession } from './auth/sessions.ts';
import type { Config } from './config.ts';
import { registerPages } from './pages.ts';
import { changePasswordPage, errorPage, loginPage } from './views/auth.ts';

export type AppDeps = {
  db: DatabaseSync;
  config: Config;
  now?: () => number;
  fetch?: typeof fetch;
  log?: (message: string) => void;
};

const MIN_PASSWORD_LENGTH = 12;
const LOGIN_FAILED = '아이디 또는 비밀번호가 올바르지 않습니다.';
const LOCKED = '로그인 시도가 너무 많습니다. 잠시 후 다시 시도하세요.';
const TOO_LONG = '입력이 너무 깁니다.';
const MAX_USERNAME_LENGTH = 64;
const MAX_PASSWORD_LENGTH = 1024;
const MAX_BODY_BYTES = 16 * 1024;

const webAdminDir = fileURLToPath(new URL('../', import.meta.url));

// Only these names are served; nothing is joined from the request path.
const staticFiles: Record<string, { path: string; type: string }> = {
  'app.css': { path: join(webAdminDir, 'public/app.css'), type: 'text/css; charset=utf-8' },
  'app.js': { path: join(webAdminDir, 'public/app.js'), type: 'text/javascript; charset=utf-8' },
  'mermaid.min.js': {
    path: join(webAdminDir, 'node_modules/mermaid/dist/mermaid.min.js'),
    type: 'text/javascript; charset=utf-8',
  },
};

function field(body: Record<string, unknown>, name: string): string {
  const value = body[name];
  return typeof value === 'string' ? value : '';
}

/** Returns a reason string when the new password breaks a rule, or null when it is acceptable. */
function passwordProblem(next: string, confirm: string, current: string, username: string, config: Config): string | null {
  if (next !== confirm) return '새 비밀번호와 확인이 다릅니다.';
  if ([...next].length < MIN_PASSWORD_LENGTH) return `새 비밀번호는 ${MIN_PASSWORD_LENGTH}자 이상이어야 합니다.`;
  if (next === username) return '새 비밀번호는 아이디와 달라야 합니다.';
  if (next === current) return '새 비밀번호는 현재 비밀번호와 달라야 합니다.';
  if (config.bootstrap && next === config.bootstrap.password) return '초기 비밀번호는 다시 쓸 수 없습니다.';
  return null;
}

export function createApp(deps: AppDeps): Hono<AppEnv> {
  const { db, config } = deps;
  const now = deps.now ?? Date.now;
  const log = deps.log ?? ((message: string) => console.log(message));
  const app = new Hono<AppEnv>();

  const issueCookie = (c: Context, token: string) =>
    setCookie(c, SESSION_COOKIE, token, {
      httpOnly: true,
      secure: config.cookieSecure,
      sameSite: 'Strict',
      path: '/admin',
      maxAge: Math.floor(SESSION_MAX_MS / 1000),
    });

  app.onError((error, c) => {
    log(`error ${c.req.method} ${c.req.path}: ${error.stack ?? String(error)}`);
    return c.html(errorPage(500), 500);
  });
  app.notFound((c) => c.html(errorPage(404), 404));

  app.get('/healthz', (c) => c.text('ok'));
  app.get('/', async (c) => c.html(await readFile(join(config.repoRoot, 'site/index.html'), 'utf8')));

  app.use(
    '/admin/*',
    securityHeaders,
    bodyLimit({ maxSize: MAX_BODY_BYTES, onError: (c) => c.text('Payload Too Large', 413) }),
    originCheck(config.origin),
  );

  app.get('/admin/static/:file', async (c) => {
    const entry = Object.hasOwn(staticFiles, c.req.param('file')) ? staticFiles[c.req.param('file')] : undefined;
    if (!entry) return c.notFound();
    try {
      const body = await readFile(entry.path);
      c.header('Content-Type', entry.type);
      c.header('Cache-Control', 'private, max-age=3600');
      return c.body(body);
    } catch {
      return c.notFound();
    }
  });

  app.get('/admin/login', (c) => c.html(loginPage()));

  app.post('/admin/login', async (c) => {
    const body = await c.req.parseBody();
    const username = field(body, 'username').trim();
    const password = field(body, 'password');
    // No real account has names or passwords this long; refuse before anything is stored or echoed.
    if ([...username].length > MAX_USERNAME_LENGTH || password.length > MAX_PASSWORD_LENGTH) {
      return c.html(loginPage({ error: TOO_LONG }), 400);
    }
    const key = loginKey(clientIp(c, config.trustProxy), username);

    // Counted synchronously before the scrypt await, so a concurrent burst gets at most five tries.
    if (!beginAttempt(db, key, now())) return c.html(loginPage({ error: LOCKED, username }), 429);

    const admin = findAdminByUsername(db, username);
    const ok = admin ? await verifyPassword(password, admin.passwordHash) : (await burnPasswordCheck(password), false);
    if (!admin || !ok) return c.html(loginPage({ error: LOGIN_FAILED, username }), 401);

    clearFailures(db, key);
    issueCookie(c, createSession(db, admin.id, now()));
    return c.redirect(admin.mustChangePassword ? '/admin/change-password' : '/admin', 302);
  });

  app.post('/admin/logout', requireSession(db, now), (c) => {
    deleteSession(db, c.get('session').token);
    deleteCookie(c, SESSION_COOKIE, { path: '/admin', secure: config.cookieSecure });
    return c.redirect('/admin/login', 302);
  });

  app.get('/admin/change-password', requireSession(db, now), (c) =>
    c.html(changePasswordPage({ forced: c.get('session').mustChangePassword })),
  );

  app.post('/admin/change-password', requireSession(db, now), async (c) => {
    const session = c.get('session');
    const forced = session.mustChangePassword;
    const admin = findAdminById(db, session.adminId);
    if (!admin) return c.redirect('/admin/login', 302);

    const body = await c.req.parseBody();
    const current = field(body, 'current');
    const next = field(body, 'next');
    const confirm = field(body, 'confirm');

    if (!(await verifyPassword(current, admin.passwordHash))) {
      return c.html(changePasswordPage({ forced, error: '현재 비밀번호가 올바르지 않습니다.' }), 400);
    }
    const problem = passwordProblem(next, confirm, current, admin.username, config);
    if (problem) return c.html(changePasswordPage({ forced, error: problem }), 400);

    updateAdminPassword(db, admin.id, await hashPassword(next), now());
    deleteOtherSessions(db, admin.id, session.token);
    deleteSession(db, session.token);
    issueCookie(c, createSession(db, admin.id, now()));
    log(`password changed for admin "${admin.username}"; other sessions revoked`);
    return c.redirect('/admin', 302);
  });

  registerPages(app, deps, now);
  return app;
}
