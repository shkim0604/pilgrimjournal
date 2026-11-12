import { getConnInfo } from '@hono/node-server/conninfo';
import type { Context, MiddlewareHandler } from 'hono';
import { getCookie } from 'hono/cookie';
import type { DatabaseSync } from 'node:sqlite';
import { resolveSession, type SessionInfo } from './sessions.ts';

export const SESSION_COOKIE = 'pilgrim_admin';

export type AppEnv = { Variables: { session: SessionInfo & { token: string } } };

const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  // Mermaid writes inline <style> into the SVGs it renders; scripts stay 'self' only.
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "form-action 'self'",
].join('; ');

/** Security headers for every /admin response; a handler's own Cache-Control (static files) wins. */
export const securityHeaders: MiddlewareHandler = async (c, next) => {
  await next();
  const headers = c.res.headers;
  headers.set('Content-Security-Policy', CSP);
  headers.set('X-Frame-Options', 'DENY');
  headers.set('Referrer-Policy', 'same-origin');
  headers.set('X-Content-Type-Options', 'nosniff');
  if (!headers.has('Cache-Control')) headers.set('Cache-Control', 'no-store');
};

function originOf(value: string | undefined): string | null {
  if (!value) return null;
  try {
    return new URL(value).origin;
  } catch {
    return null;
  }
}

/** Rejects state-changing requests whose Origin (or, failing that, Referer) is not the console's own. */
export function originCheck(origin: string): MiddlewareHandler {
  return async (c, next) => {
    if (c.req.method !== 'GET' && c.req.method !== 'HEAD') {
      const source = originOf(c.req.header('origin')) ?? originOf(c.req.header('referer'));
      if (source !== origin) return c.text('Forbidden', 403);
    }
    await next();
  };
}

export function requireSession(db: DatabaseSync, now: () => number): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const token = getCookie(c, SESSION_COOKIE);
    const session = token ? resolveSession(db, token, now()) : null;
    if (!token || !session) return c.redirect('/admin/login', 302);
    c.set('session', { ...session, token });
    await next();
  };
}

export const requirePasswordChanged: MiddlewareHandler<AppEnv> = async (c, next) => {
  if (c.get('session').mustChangePassword) return c.redirect('/admin/change-password', 302);
  await next();
};

/** The caller's IP: Cloudflare's header only when the proxy is trusted, else the socket address. */
export function clientIp(c: Context, trustProxy: boolean): string {
  if (trustProxy) {
    const forwarded = c.req.header('cf-connecting-ip')?.trim();
    if (forwarded) return forwarded;
  }
  try {
    return getConnInfo(c).remote.address ?? 'unknown';
  } catch {
    return 'unknown';
  }
}
