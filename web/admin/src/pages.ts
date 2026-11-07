import type { Hono } from 'hono';
import { requirePasswordChanged, requireSession, type AppEnv } from './auth/middleware.ts';
import { readTrackingDocs } from './content/checklist.ts';
import { latestCiRun } from './content/github.ts';
import { consoleLinks } from './content/links.ts';
import { loadSnapshot } from './content/snapshot.ts';
import type { AppDeps } from './server.ts';
import { architecturePage } from './views/architecture.ts';
import { dashboardPage } from './views/dashboard.ts';
import { databasePage } from './views/database.ts';
import { flowsPage } from './views/flows.ts';

/** Console pages; every one sits behind a session with the password already changed. */
export function registerPages(app: Hono<AppEnv>, deps: AppDeps, now: () => number): void {
  const { config } = deps;
  const guard = [requireSession(deps.db, now), requirePasswordChanged] as const;

  app.get('/admin', ...guard, async (c) => {
    const docs = readTrackingDocs(config.repoRoot);
    const ci = config.github ? await latestCiRun(config.github, deps.fetch ?? fetch, now()) : null;
    return c.html(
      dashboardPage({
        checklist: docs.checklist,
        todo: docs.todo,
        snapshot: loadSnapshot(config.snapshotDir),
        ci,
        links: consoleLinks(config.github),
      }),
    );
  });

  app.get('/admin/database', ...guard, (c) =>
    c.html(databasePage(loadSnapshot(config.snapshotDir).schema, c.req.query('store'))),
  );

  app.get('/admin/architecture', ...guard, (c) =>
    c.html(architecturePage(loadSnapshot(config.snapshotDir).architecture)),
  );

  app.get('/admin/flows', ...guard, (c) => c.html(flowsPage()));
}
