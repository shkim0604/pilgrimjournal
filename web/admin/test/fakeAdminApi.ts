// A stand-in for the group server's `/internal/admin/v1/*`, plugged in as `AppDeps.fetch`. It
// records every call and answers like server/Sources/PilgrimServerCore/Internal/InternalModule.swift.

export const API_BASE = 'http://pilgrim-api:3100';
export const API_TOKEN = 'test-admin-token-0123456789abcdef-0123456789';

export const REPORT_ID = '11111111-1111-4111-8111-111111111111';
export const POST_ID = '22222222-2222-4222-8222-222222222222';
export const AUTHOR_ID = '33333333-3333-4333-8333-333333333333';
export const REPORTER_ID = '44444444-4444-4444-8444-444444444444';
export const GROUP_ID = '55555555-5555-4555-8555-555555555555';
export const MEDIA_ID = '66666666-6666-4666-8666-666666666666';
export const NEXT_CURSOR = '77777777-7777-4777-8777-777777777777';

/** A tiny JPEG-looking payload: the signature is all the console checks. */
export const JPEG_BYTES = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46]);

export type Call = { method: string; url: URL; headers: Headers; body: unknown; redirect: string | undefined };

export function sampleReport(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: REPORT_ID,
    createdAt: '2026-11-14T13:05:00.123Z',
    status: 'open',
    reason: 'harassment',
    note: 'reporter note',
    targetType: 'post',
    targetId: POST_ID,
    groupId: GROUP_ID,
    groupName: '수요 기도모임',
    reporter: { id: REPORTER_ID, displayName: '신고한 사람' },
    targetUser: { id: AUTHOR_ID, displayName: '글쓴 사람' },
    snapshot: {
      authorId: AUTHOR_ID,
      authorName: '글쓴 사람',
      title: 'snapshot title',
      body: 'snapshot body text',
      items: [{ text: 'first prayer item', who: '어머니', topic: 'health' }],
      mediaIds: [MEDIA_ID],
      capturedAt: '2026-11-14T13:05:00.000Z',
    },
    ...overrides,
  };
}

export function livePost(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: POST_ID,
    groupId: GROUP_ID,
    kind: 'prayer',
    author: { id: AUTHOR_ID, displayName: '글쓴 사람' },
    isMine: false,
    title: 'live title',
    body: 'live body text',
    items: [{ text: 'live prayer item' }],
    timeZone: 'Asia/Seoul',
    createdAt: '2026-11-14T12:00:00.000Z',
    expiresAt: '2026-11-21T12:00:00.000Z',
    extensionCount: 0,
    media: [
      {
        id: MEDIA_ID,
        width: 800,
        height: 600,
        byteCount: 1000,
        url: 'https://pilgrim.delight-house.org/api/media-files/signed-url-secret',
        urlExpiresAt: '2026-11-14T13:15:00.000Z',
      },
    ],
    commentCount: 2,
    reactions: [],
    isUnread: false,
    ...overrides,
  };
}

type Handler = (call: Call) => Response | Promise<Response>;

export type FakeApi = {
  calls: Call[];
  fetch: typeof fetch;
  /** Overrides the answer for `METHOD /path` (path after the `/internal/admin/v1` prefix). */
  on(method: string, path: string, handler: Handler): void;
  report: Record<string, unknown>;
  liveTarget: Record<string, unknown> | null;
};

export function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } });
}

export function apiError(status: number, code: string): Response {
  return json({ error: { code, message: 'developer message <b>not shown</b>' } }, status);
}

export function fakeAdminApi(): FakeApi {
  const overrides = new Map<string, Handler>();
  const fake: FakeApi = {
    calls: [],
    report: sampleReport(),
    liveTarget: { exists: true, post: livePost() },
    on(method, path, handler) {
      overrides.set(`${method} ${path}`, handler);
    },
    fetch: (async (input: string | URL | Request, init: RequestInit = {}) => {
      const url = new URL(String(input));
      const method = init.method ?? 'GET';
      const headers = new Headers(init.headers);
      const body = typeof init.body === 'string' ? JSON.parse(init.body) : init.body ?? null;
      const call: Call = { method, url, headers, body, redirect: init.redirect };
      fake.calls.push(call);

      if (url.origin !== API_BASE || !url.pathname.startsWith('/internal/admin/v1/')) {
        return new Response('wrong host', { status: 599 });
      }
      if (headers.get('x-admin-token') !== API_TOKEN) return apiError(401, 'UNAUTHENTICATED');
      const path = url.pathname.slice('/internal/admin/v1'.length);
      const override = overrides.get(`${method} ${path}`);
      if (override) return override(call);

      if (method === 'GET' && path === '/reports') return json({ items: [fake.report], nextCursor: null });
      if (method === 'GET' && path === `/reports/${REPORT_ID}`) {
        return json({ report: fake.report, liveTarget: fake.liveTarget });
      }
      if (method === 'POST' && path === `/reports/${REPORT_ID}/resolve`) {
        return json({ ...fake.report, status: (body as { resolution: string }).resolution, resolvedBy: 'x' });
      }
      if (method === 'DELETE' && /^\/(posts|comments|stickers)\/[0-9a-f-]{36}$/.test(path)) {
        return new Response(null, { status: 204 });
      }
      if (method === 'POST' && /^\/users\/[0-9a-f-]{36}\/(suspend|unsuspend)$/.test(path)) {
        return new Response(null, { status: 204 });
      }
      if (method === 'GET' && path === `/media/${MEDIA_ID}`) {
        return new Response(JPEG_BYTES, {
          status: 200,
          headers: { 'content-type': 'image/jpeg', 'x-upstream-secret': 'leak', 'set-cookie': 'upstream=1' },
        });
      }
      return apiError(404, 'NOT_FOUND');
    }) as typeof fetch,
  };
  return fake;
}
