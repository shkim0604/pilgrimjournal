import type { Context, Hono, MiddlewareHandler } from 'hono';
import { readForm, type AppEnv } from './auth/middleware.ts';
import { AdminApiError, createAdminApi, type AdminApi } from './moderation/adminApi.ts';
import {
  DELETABLE_TARGETS,
  REPORT_STATUSES,
  RESOLUTIONS,
  uuid,
  type DeletableTarget,
  type ReportStatus,
  type Resolution,
  type UserRef,
} from './moderation/types.ts';
import type { AppDeps } from './server.ts';
import {
  isNoticeKey,
  reportDetailPage,
  reportListPage,
  reportsDisabledPage,
  reportsErrorPage,
  type NoticeKey,
} from './views/reports.ts';

// The 신고 pages (design.md 14절, tasks.md W1). Every page and action sits behind the console
// session (with the password changed) and the console's Origin check; the group server is called
// server-side only, with the signed-in admin's username as `X-Admin-Actor`.

const PAGE_LIMIT = 50;
const MAX_TEXT = 500;
const DAY_MS = 86_400_000;
const DURATIONS: Record<string, number | null> = { '1': 1, '7': 7, '30': 30, indefinite: null };

type Guard = readonly [MiddlewareHandler<AppEnv>, MiddlewareHandler<AppEnv>];

function includes<T extends string>(values: readonly T[], value: string): value is T {
  return (values as readonly string[]).includes(value);
}

function field(body: Record<string, unknown>, name: string): string {
  const value = body[name];
  return typeof value === 'string' ? value : '';
}

/** The fixed message for a failed call; nothing from the server's body is shown. */
function failureNotice(error: unknown): NoticeKey {
  if (!(error instanceof AdminApiError)) throw error;
  switch (error.status) {
    case 401:
      return 'unauthorized';
    case 403:
      return 'forbidden';
    case 404:
      return 'notFound';
    case 400:
    case 422:
      return 'invalid';
    default:
      return 'unavailable';
  }
}

export function registerReportPages(app: Hono<AppEnv>, deps: AppDeps, guard: Guard): void {
  const { config } = deps;
  const now = deps.now ?? Date.now;
  const log = deps.log ?? ((message: string) => console.log(message));
  const api: AdminApi | null = config.adminApi ? createAdminApi(config.adminApi, deps.fetch ?? fetch) : null;

  const actor = (c: Context<AppEnv>) => c.get('session').username;

  /** Logs the failure (status and code only: no token, no report content) and picks its notice. */
  const failed = (what: string, error: unknown): NoticeKey => {
    const key = failureNotice(error);
    const apiError = error as AdminApiError;
    log(`admin api ${what} failed: ${apiError.message}`);
    return key;
  };

  const back = (c: Context<AppEnv>, reportId: string, notice: NoticeKey) =>
    c.redirect(`/admin/reports/${reportId}?notice=${notice}`, 302);

  app.get('/admin/reports', ...guard, async (c) => {
    if (!api) return c.html(reportsDisabledPage());
    const requested = c.req.query('status') ?? 'open';
    const status: ReportStatus = includes(REPORT_STATUSES, requested) ? requested : 'open';
    const cursor = uuid(c.req.query('cursor')) ?? undefined;
    try {
      const page = await api.listReports(actor(c), { status, cursor, limit: PAGE_LIMIT });
      return c.html(reportListPage({ status, page }));
    } catch (error) {
      return c.html(reportsErrorPage(failed('list reports', error)), 502);
    }
  });

  app.get('/admin/reports/:id', ...guard, async (c) => {
    if (!api) return c.html(reportsDisabledPage(), 503);
    const id = uuid(c.req.param('id'));
    if (!id) return c.notFound();
    const notice = c.req.query('notice');
    try {
      const detail = await api.reportDetail(actor(c), id);
      return c.html(reportDetailPage(detail, isNoticeKey(notice) ? notice : undefined));
    } catch (error) {
      const key = failed('report detail', error);
      return c.html(reportsErrorPage(key), key === 'notFound' ? 404 : 502);
    }
  });

  app.get('/admin/media/:id', ...guard, async (c) => {
    if (!api) return c.notFound();
    const id = uuid(c.req.param('id'));
    if (!id) return c.notFound();
    try {
      const bytes = await api.media(actor(c), id);
      // Only the bytes are passed on; none of the server's headers are copied.
      return c.body(bytes as Uint8Array<ArrayBuffer>, 200, {
        'Content-Type': 'image/jpeg',
        'Cache-Control': 'private, no-store',
        'Content-Disposition': 'inline',
      });
    } catch (error) {
      const key = failed('media', error);
      return c.text(key === 'notFound' ? 'Not Found' : 'Bad Gateway', key === 'notFound' ? 404 : 502);
    }
  });

  // Every action looks the report up again and acts on what the server says it points at, so a
  // form can only ever touch the report's own target, author or reporter.
  const action = (
    path: string,
    run: (ctx: { c: Context<AppEnv>; api: AdminApi; reportId: string; body: Record<string, unknown> }) => Promise<NoticeKey>,
  ) => {
    app.post(`/admin/reports/:id/${path}`, ...guard, async (c) => {
      if (!api) return c.html(reportsDisabledPage(), 503);
      const reportId = uuid(c.req.param('id'));
      if (!reportId) return c.notFound();
      const body = await readForm(c);
      if (!body) return c.text('Bad Request', 400);
      let notice: NoticeKey;
      try {
        notice = await run({ c, api, reportId, body });
      } catch (error) {
        notice = failed(path, error);
      }
      return back(c, reportId, notice);
    });
  };

  action('resolve', async ({ c, api, reportId, body }) => {
    const resolution = field(body, 'resolution');
    const note = field(body, 'note').trim();
    if (!includes<Resolution>(RESOLUTIONS, resolution) || [...note].length > MAX_TEXT) return 'invalid';
    await api.resolveReport(actor(c), reportId, { resolution, note: note || undefined });
    return 'resolved';
  });

  action('delete', async ({ c, api, reportId, body }) => {
    if (field(body, 'confirm') !== 'yes') return 'confirmRequired';
    const { report } = await api.reportDetail(actor(c), reportId);
    if (!includes<DeletableTarget>(DELETABLE_TARGETS, report.targetType)) return 'invalid';
    await api.deleteTarget(actor(c), report.targetType, report.targetId, report.id);
    return 'deleted';
  });

  const person = async (c: Context<AppEnv>, api: AdminApi, reportId: string, who: string): Promise<UserRef | null> => {
    if (who !== 'target' && who !== 'reporter') return null;
    const { report } = await api.reportDetail(actor(c), reportId);
    return who === 'target' ? report.targetUser : report.reporter;
  };

  action('suspend', async ({ c, api, reportId, body }) => {
    if (field(body, 'confirm') !== 'yes') return 'confirmRequired';
    const reason = field(body, 'reason').trim();
    if (!reason || [...reason].length > MAX_TEXT) return 'reasonRequired';
    const duration = field(body, 'duration');
    if (!Object.hasOwn(DURATIONS, duration)) return 'invalid';
    const days = DURATIONS[duration];
    const user = await person(c, api, reportId, field(body, 'who'));
    if (!user) return 'invalid';
    // No `until` means indefinite; the server answers it as Date.distantFuture.
    const until = days == null ? undefined : new Date(now() + days * DAY_MS).toISOString();
    await api.suspendUser(actor(c), user.id, { reason, until });
    return 'suspended';
  });

  action('unsuspend', async ({ c, api, reportId, body }) => {
    const user = await person(c, api, reportId, field(body, 'who'));
    if (!user) return 'invalid';
    await api.unsuspendUser(actor(c), user.id);
    return 'unsuspended';
  });
}
