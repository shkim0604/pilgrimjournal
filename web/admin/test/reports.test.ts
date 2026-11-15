import assert from 'node:assert/strict';
import { test } from 'node:test';
import { AdminApiError, actorHeader, createAdminApi } from '../src/moderation/adminApi.ts';
import { decodeDetail, isIndefinite } from '../src/moderation/types.ts';
import { BOOT_USER, get, login, loginReady, makeHarness, post, type Harness } from './appHelpers.ts';
import {
  API_BASE,
  API_TOKEN,
  AUTHOR_ID,
  JPEG_BYTES,
  MEDIA_ID,
  NEXT_CURSOR,
  POST_ID,
  REPORTER_ID,
  REPORT_ID,
  apiError,
  fakeAdminApi,
  json,
  livePost,
  sampleReport,
  type FakeApi,
} from './fakeAdminApi.ts';

async function setup(): Promise<{ h: Harness; api: FakeApi; cookie: string }> {
  const api = fakeAdminApi();
  const h = await makeHarness({ adminApi: { baseUrl: API_BASE, token: API_TOKEN } }, { fetch: api.fetch });
  const cookie = await loginReady(h);
  return { h, api, cookie };
}

function only<T>(items: T[], what: string): T {
  assert.equal(items.length, 1, `expected one ${what}, got ${items.length}`);
  return items[0]!;
}

// MARK: - Client

test('client sends the token and actor, never a Cloudflare header, and refuses redirects', async () => {
  const api = fakeAdminApi();
  const client = createAdminApi({ baseUrl: API_BASE, token: API_TOKEN }, api.fetch);
  await client.listReports('operator', { status: 'open', limit: 50 });
  const call = only(api.calls, 'call');
  assert.equal(call.url.href, `${API_BASE}/internal/admin/v1/reports?status=open&limit=50`);
  assert.equal(call.headers.get('x-admin-token'), API_TOKEN);
  assert.equal(call.headers.get('x-admin-actor'), 'operator');
  assert.equal(call.headers.get('cf-ray'), null);
  assert.equal(call.headers.get('cf-connecting-ip'), null);
  assert.equal(call.headers.get('cookie'), null);
  assert.equal(call.redirect, 'error');
});

test('actor header keeps ASCII names and percent-encodes others within 100 characters', () => {
  assert.equal(actorHeader(' admin '), 'admin');
  assert.equal(actorHeader('관리자'), encodeURIComponent('관리자'));
  assert.equal(actorHeader('a'.repeat(150)).length, 100);
});

test('client errors carry the status and code but not the server message', async () => {
  const api = fakeAdminApi();
  api.on('GET', '/reports', () => apiError(403, 'FORBIDDEN'));
  const client = createAdminApi({ baseUrl: API_BASE, token: API_TOKEN }, api.fetch);
  await assert.rejects(client.listReports('op', {}), (error: unknown) => {
    assert.ok(error instanceof AdminApiError);
    assert.equal(error.status, 403);
    assert.equal(error.code, 'FORBIDDEN');
    assert.ok(!error.message.includes('developer message'));
    assert.ok(!error.message.includes(API_TOKEN));
    return true;
  });
});

test('client reports a network failure as status 0', async () => {
  const failing = (async () => {
    throw new TypeError('fetch failed');
  }) as unknown as typeof fetch;
  const client = createAdminApi({ baseUrl: API_BASE, token: API_TOKEN }, failing);
  await assert.rejects(client.reportDetail('op', REPORT_ID), (error: unknown) => {
    assert.ok(error instanceof AdminApiError);
    assert.equal(error.status, 0);
    return true;
  });
});

test('client rejects a malformed response instead of rendering it', async () => {
  const api = fakeAdminApi();
  api.on('GET', `/reports/${REPORT_ID}`, () => json({ report: { ...sampleReport(), id: '../../users' } }));
  const client = createAdminApi({ baseUrl: API_BASE, token: API_TOKEN }, api.fetch);
  await assert.rejects(client.reportDetail('op', REPORT_ID), AdminApiError);
});

test('decoding drops media IDs that are not UUIDs and recognises indefinite suspension', () => {
  const detail = decodeDetail({
    report: sampleReport({
      snapshot: { mediaIds: [MEDIA_ID, 'javascript:alert(1)'], capturedAt: 'x' },
      targetUser: { id: AUTHOR_ID, displayName: 'x', suspendedUntil: '4001-01-01T00:00:00.000Z' },
    }),
    liveTarget: null,
  });
  assert.deepEqual(detail.report.snapshot.mediaIds, [MEDIA_ID]);
  assert.ok(isIndefinite(detail.report.targetUser!.suspendedUntil!));
  assert.ok(!isIndefinite('2026-12-01T00:00:00.000Z'));
});

test('client refuses media that is not a JPEG', async () => {
  const api = fakeAdminApi();
  api.on('GET', `/media/${MEDIA_ID}`, () => new Response('<svg onload=alert(1)>', { headers: { 'content-type': 'image/jpeg' } }));
  const client = createAdminApi({ baseUrl: API_BASE, token: API_TOKEN }, api.fetch);
  await assert.rejects(client.media('op', MEDIA_ID), AdminApiError);
});

// MARK: - Pages

test('reports page is behind the session and shows a notice when the API is not configured', async () => {
  const h = await makeHarness();
  assert.equal((await get(h, '/admin/reports')).headers.get('location'), '/admin/login');
  assert.equal((await get(h, `/admin/media/${MEDIA_ID}`)).headers.get('location'), '/admin/login');
  const firstLogin = await login(h);
  assert.equal((await get(h, '/admin/reports', firstLogin)).headers.get('location'), '/admin/change-password');

  const disabled = await makeHarness();
  const res = await get(disabled, '/admin/reports', await loginReady(disabled));
  assert.equal(res.status, 200);
  const body = await res.text();
  assert.ok(body.includes('신고 기능이 꺼져 있습니다'));
  assert.ok(body.includes('href="/admin/reports" aria-current="page"'));
});

test('report list asks for open reports with the admin as actor and links to the detail', async () => {
  const { h, api, cookie } = await setup();
  const res = await get(h, '/admin/reports', cookie);
  assert.equal(res.status, 200);
  const body = await res.text();
  const call = only(api.calls, 'call');
  assert.equal(call.url.searchParams.get('status'), 'open');
  assert.equal(call.url.searchParams.get('limit'), '50');
  assert.equal(call.headers.get('x-admin-actor'), BOOT_USER);
  assert.ok(body.includes(`href="/admin/reports/${REPORT_ID}"`));
  assert.ok(body.includes('수요 기도모임'));
  assert.ok(body.includes('괴롭힘'));
  assert.ok(body.includes('snapshot title'));
  assert.ok(!body.includes(API_TOKEN));
});

test('report list switches status and pages with the cursor', async () => {
  const { h, api, cookie } = await setup();
  api.on('GET', '/reports', () => json({ items: [sampleReport({ status: 'dismissed' })], nextCursor: NEXT_CURSOR }));
  const body = await (await get(h, `/admin/reports?status=dismissed&cursor=${NEXT_CURSOR}`, cookie)).text();
  const call = only(api.calls, 'call');
  assert.equal(call.url.searchParams.get('status'), 'dismissed');
  assert.equal(call.url.searchParams.get('cursor'), NEXT_CURSOR);
  assert.ok(body.includes(`/admin/reports?status=dismissed&amp;cursor=${NEXT_CURSOR}`));

  await get(h, '/admin/reports?status=bogus&cursor=not-a-uuid', cookie);
  const second = api.calls[1]!;
  assert.equal(second.url.searchParams.get('status'), 'open');
  assert.equal(second.url.searchParams.get('cursor'), null);
});

test('report pages escape user-written content', async () => {
  const { h, api, cookie } = await setup();
  const evil = '<script>alert(1)</script>';
  const attr = '"><img src=x onerror=alert(1)>';
  api.report = sampleReport({
    note: evil,
    groupName: evil,
    reporter: { id: REPORTER_ID, displayName: attr },
    targetUser: { id: AUTHOR_ID, displayName: evil },
    snapshot: {
      authorName: evil,
      title: evil,
      body: attr,
      items: [{ text: evil, who: evil, topic: attr }],
      book: { title: evil, author: attr },
      mediaIds: [],
      capturedAt: evil,
    },
  });
  api.liveTarget = { exists: true, post: livePost({ title: evil, body: attr }) };
  for (const path of ['/admin/reports', `/admin/reports/${REPORT_ID}`]) {
    const body = await (await get(h, path, cookie)).text();
    assert.ok(!body.includes(evil), path);
    assert.ok(!body.includes(attr), path);
    assert.ok(body.includes('&lt;script&gt;'), path);
  }
});

test('report detail shows the snapshot, the live original and photos through the proxy', async () => {
  const { h, cookie } = await setup();
  const res = await get(h, `/admin/reports/${REPORT_ID}`, cookie);
  assert.equal(res.status, 200);
  const body = await res.text();
  assert.ok(body.includes('snapshot body text'));
  assert.ok(body.includes('first prayer item'));
  assert.ok(body.includes('live body text'));
  assert.ok(body.includes(`src="/admin/media/${MEDIA_ID}"`));
  // The server's signed public URL is never put in the page.
  assert.ok(!body.includes('signed-url-secret'));
  assert.ok(body.includes(`action="/admin/reports/${REPORT_ID}/delete"`));
  assert.ok(body.includes(`action="/admin/reports/${REPORT_ID}/suspend"`));
  assert.ok(body.includes(`action="/admin/reports/${REPORT_ID}/resolve"`));
  assert.ok(!body.includes(API_TOKEN));
});

test('report detail says when the original is gone and shows indefinite suspension', async () => {
  const { h, api, cookie } = await setup();
  api.liveTarget = { exists: false };
  api.report = sampleReport({
    targetUser: { id: AUTHOR_ID, displayName: '글쓴 사람', suspendedUntil: '4001-01-01T00:00:00.000Z' },
  });
  const body = await (await get(h, `/admin/reports/${REPORT_ID}`, cookie)).text();
  assert.ok(body.includes('원본이 지워졌거나'));
  assert.ok(body.includes('무기한 정지'));
  assert.ok(body.includes(`action="/admin/reports/${REPORT_ID}/unsuspend"`));
  assert.ok(!body.includes(`action="/admin/reports/${REPORT_ID}/delete"`));
});

test('report detail shows a fixed notice from the query and ignores unknown keys', async () => {
  const { h, cookie } = await setup();
  const ok = await (await get(h, `/admin/reports/${REPORT_ID}?notice=deleted`, cookie)).text();
  assert.ok(ok.includes('신고된 항목을 지웠습니다'));
  const unknown = await (await get(h, `/admin/reports/${REPORT_ID}?notice=%3Cscript%3E`, cookie)).text();
  assert.ok(!unknown.includes('<script>'));
  assert.ok(!unknown.includes('notice error'));
});

test('report detail maps API failures to fixed messages', async () => {
  const { h, api, cookie } = await setup();
  const missing = await get(h, '/admin/reports/99999999-9999-4999-8999-999999999999', cookie);
  assert.equal(missing.status, 404);
  assert.ok((await missing.text()).includes('대상을 찾지 못했습니다'));

  api.on('GET', `/reports/${REPORT_ID}`, () => apiError(401, 'UNAUTHENTICATED'));
  const denied = await get(h, `/admin/reports/${REPORT_ID}`, cookie);
  assert.equal(denied.status, 502);
  const body = await denied.text();
  assert.ok(body.includes('ADMIN_API_TOKEN이 같은지'));
  assert.ok(!body.includes('developer message'));

  assert.equal((await get(h, '/admin/reports/not-a-uuid', cookie)).status, 404);
  assert.ok(h.logs.some((line) => line.includes('report detail failed: HTTP 401')));
  assert.ok(h.logs.every((line) => !line.includes(API_TOKEN)));
});

test('media proxy returns the JPEG without the server headers', async () => {
  const { h, cookie } = await setup();
  const res = await get(h, `/admin/media/${MEDIA_ID}`, cookie);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get('content-type'), 'image/jpeg');
  assert.equal(res.headers.get('x-upstream-secret'), null);
  assert.equal(res.headers.get('set-cookie'), null);
  assert.match(res.headers.get('cache-control') ?? '', /no-store/);
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.deepEqual(new Uint8Array(await res.arrayBuffer()), JPEG_BYTES);

  assert.equal((await get(h, '/admin/media/..%2Fstatus', cookie)).status, 404);
  assert.equal((await get(h, '/admin/media/99999999-9999-4999-8999-999999999999', cookie)).status, 404);
});

// MARK: - Actions

function actionCalls(api: FakeApi) {
  return api.calls.filter((call) => call.method !== 'GET');
}

test('resolve forwards the resolution and note with the actor', async () => {
  const { h, api, cookie } = await setup();
  const res = await post(h, `/admin/reports/${REPORT_ID}/resolve`, { resolution: 'dismissed', note: '  중복 신고  ' }, { cookie });
  assert.equal(res.status, 302);
  assert.equal(res.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=resolved`);
  const call = only(actionCalls(api), 'action');
  assert.equal(call.url.pathname, `/internal/admin/v1/reports/${REPORT_ID}/resolve`);
  assert.deepEqual(call.body, { resolution: 'dismissed', note: '중복 신고' });
  assert.equal(call.headers.get('x-admin-actor'), BOOT_USER);
  assert.equal(call.headers.get('content-type'), 'application/json');
});

test('resolve rejects an unknown resolution without calling the server', async () => {
  const { h, api, cookie } = await setup();
  const res = await post(h, `/admin/reports/${REPORT_ID}/resolve`, { resolution: 'deleted' }, { cookie });
  assert.equal(res.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=invalid`);
  assert.equal(api.calls.length, 0);
});

test('delete needs the confirm box and removes the report target with reportId', async () => {
  const { h, api, cookie } = await setup();
  const unconfirmed = await post(h, `/admin/reports/${REPORT_ID}/delete`, {}, { cookie });
  assert.equal(unconfirmed.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=confirmRequired`);
  assert.equal(api.calls.length, 0);

  // A forged target in the form is ignored: the console deletes what the report points at.
  const res = await post(
    h,
    `/admin/reports/${REPORT_ID}/delete`,
    { confirm: 'yes', kind: 'sticker', targetId: MEDIA_ID },
    { cookie },
  );
  assert.equal(res.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=deleted`);
  const call = only(actionCalls(api), 'action');
  assert.equal(call.method, 'DELETE');
  assert.equal(call.url.pathname, `/internal/admin/v1/posts/${POST_ID}`);
  assert.equal(call.url.searchParams.get('reportId'), REPORT_ID);
  assert.equal(call.headers.get('x-admin-actor'), BOOT_USER);
});

test('delete of a comment and a sticker report uses their own routes', async () => {
  for (const [type, route] of [
    ['comment', 'comments'],
    ['sticker', 'stickers'],
  ] as const) {
    const { h, api, cookie } = await setup();
    api.report = sampleReport({ targetType: type });
    await post(h, `/admin/reports/${REPORT_ID}/delete`, { confirm: 'yes' }, { cookie });
    assert.equal(only(actionCalls(api), 'action').url.pathname, `/internal/admin/v1/${route}/${POST_ID}`);
  }
});

test('delete of a user report is refused', async () => {
  const { h, api, cookie } = await setup();
  api.report = sampleReport({ targetType: 'user' });
  const res = await post(h, `/admin/reports/${REPORT_ID}/delete`, { confirm: 'yes' }, { cookie });
  assert.equal(res.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=invalid`);
  assert.equal(actionCalls(api).length, 0);
});

test('suspend sends the reason and an until computed from the clock', async () => {
  const { h, api, cookie } = await setup();
  const res = await post(
    h,
    `/admin/reports/${REPORT_ID}/suspend`,
    { who: 'target', duration: '7', reason: ' 반복된 괴롭힘 ', confirm: 'yes' },
    { cookie },
  );
  assert.equal(res.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=suspended`);
  const call = only(actionCalls(api), 'action');
  assert.equal(call.url.pathname, `/internal/admin/v1/users/${AUTHOR_ID}/suspend`);
  assert.deepEqual(call.body, {
    reason: '반복된 괴롭힘',
    until: new Date(h.clock.now + 7 * 86_400_000).toISOString(),
  });
});

test('indefinite suspension omits until; the reporter can be suspended too', async () => {
  const { h, api, cookie } = await setup();
  await post(
    h,
    `/admin/reports/${REPORT_ID}/suspend`,
    { who: 'reporter', duration: 'indefinite', reason: '허위 신고 반복', confirm: 'yes' },
    { cookie },
  );
  const call = only(actionCalls(api), 'action');
  assert.equal(call.url.pathname, `/internal/admin/v1/users/${REPORTER_ID}/suspend`);
  assert.deepEqual(call.body, { reason: '허위 신고 반복' });
});

test('suspend validates the confirm box, reason, duration and person before calling the server', async () => {
  const { h, api, cookie } = await setup();
  const cases: [Record<string, string>, string][] = [
    [{ who: 'target', duration: '7', reason: 'x' }, 'confirmRequired'],
    [{ who: 'target', duration: '7', reason: '   ', confirm: 'yes' }, 'reasonRequired'],
    [{ who: 'target', duration: '7', reason: 'x'.repeat(501), confirm: 'yes' }, 'reasonRequired'],
    [{ who: 'target', duration: '365', reason: 'x', confirm: 'yes' }, 'invalid'],
    [{ who: 'someone', duration: '7', reason: 'x', confirm: 'yes' }, 'invalid'],
  ];
  for (const [fields, notice] of cases) {
    const res = await post(h, `/admin/reports/${REPORT_ID}/suspend`, fields, { cookie });
    assert.equal(res.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=${notice}`, JSON.stringify(fields));
  }
  assert.equal(actionCalls(api).length, 0);
});

test('unsuspend lifts the target user', async () => {
  const { h, api, cookie } = await setup();
  const res = await post(h, `/admin/reports/${REPORT_ID}/unsuspend`, { who: 'target' }, { cookie });
  assert.equal(res.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=unsuspended`);
  const call = only(actionCalls(api), 'action');
  assert.equal(call.url.pathname, `/internal/admin/v1/users/${AUTHOR_ID}/unsuspend`);
  assert.equal(call.body, null);
});

test('an action the server refuses comes back as a fixed notice', async () => {
  const { h, api, cookie } = await setup();
  api.on('DELETE', `/posts/${POST_ID}`, () => apiError(404, 'NOT_FOUND'));
  const gone = await post(h, `/admin/reports/${REPORT_ID}/delete`, { confirm: 'yes' }, { cookie });
  assert.equal(gone.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=notFound`);

  api.on('POST', `/reports/${REPORT_ID}/resolve`, () => apiError(403, 'FORBIDDEN'));
  const tunnel = await post(h, `/admin/reports/${REPORT_ID}/resolve`, { resolution: 'actioned' }, { cookie });
  assert.equal(tunnel.headers.get('location'), `/admin/reports/${REPORT_ID}?notice=forbidden`);
  assert.ok(h.logs.every((line) => !line.includes(API_TOKEN)));
});

test('actions are protected by the session and the Origin check', async () => {
  const { h, api, cookie } = await setup();
  const noSession = await post(h, `/admin/reports/${REPORT_ID}/resolve`, { resolution: 'actioned' });
  assert.equal(noSession.headers.get('location'), '/admin/login');
  const crossSite = await post(
    h,
    `/admin/reports/${REPORT_ID}/resolve`,
    { resolution: 'actioned' },
    { cookie, origin: 'https://evil.test' },
  );
  assert.equal(crossSite.status, 403);
  assert.equal(api.calls.length, 0);
});
