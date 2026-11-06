import type { Hono } from 'hono';
import { html } from 'hono/html';
import { requirePasswordChanged, requireSession, type AppEnv } from './auth/middleware.ts';
import type { AppDeps } from './server.ts';
import { layout } from './views/layout.ts';

/** Console pages; every one sits behind a session with the password already changed. */
export function registerPages(app: Hono<AppEnv>, deps: AppDeps, now: () => number): void {
  const guard = [requireSession(deps.db, now), requirePasswordChanged] as const;

  app.get('/admin', ...guard, (c) =>
    c.html(layout({ title: '대시보드', active: 'dashboard', body: html`<p>준비 중</p>` })),
  );
}
