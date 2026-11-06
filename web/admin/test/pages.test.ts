import assert from 'node:assert/strict';
import { join } from 'node:path';
import { test } from 'node:test';
import { get, loginReady, makeHarness, webAdminDir, writeSnapshotDir } from './appHelpers.ts';
import { tempDir } from './helpers.ts';
import { loadSnapshot } from '../src/content/snapshot.ts';

async function page(path: string, ...args: Parameters<typeof makeHarness>) {
  const h = await makeHarness(...args);
  const cookie = await loginReady(h);
  const res = await get(h, path, cookie);
  return { res, body: await res.text(), h };
}

function count(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}

test('dashboard shows release gate counts', async () => {
  const { res, body } = await page('/admin');
  assert.equal(res.status, 200);
  assert.ok(body.includes('출시 게이트'));
  assert.match(body, /미완료 <strong>\d+<\/strong>/);
  assert.ok(body.includes('남은 일'));
  const commits = loadSnapshot(join(webAdminDir, 'snapshot')).commits;
  assert.ok(commits.ok);
  assert.ok(body.includes(commits.value.commits[0]!.hash));
  assert.ok(body.includes('CloudKit Console'));
});

test('dashboard hides CI card without github config', async () => {
  const { body } = await page('/admin');
  assert.ok(!body.includes('data-card="ci"'));
});

test('dashboard shows CI card with stubbed fetch', async () => {
  const calls: string[] = [];
  const fetchStub = (async (input: string | URL | Request) => {
    calls.push(String(input));
    return new Response(
      JSON.stringify({
        workflow_runs: [
          {
            status: 'completed',
            conclusion: 'success',
            html_url: 'https://github.com/x/y/actions/runs/1',
            updated_at: '2026-11-06T00:00:00Z',
          },
        ],
      }),
      { status: 200, headers: { 'content-type': 'application/json' } },
    );
  }) as typeof fetch;
  const { body } = await page('/admin', { github: { token: 't', repo: 'x/y' } }, { fetch: fetchStub });
  assert.ok(body.includes('data-card="ci"'));
  assert.ok(body.includes('success'));
  assert.ok(body.includes('https://github.com/x/y/actions/runs/1'));
  assert.equal(calls[0], 'https://api.github.com/repos/x/y/actions/runs?branch=main&per_page=1');
});

test('dashboard keeps rendering when the CI request fails', async () => {
  const failing = (async () => new Response('nope', { status: 500 })) as unknown as typeof fetch;
  const { res, body } = await page('/admin', { github: { token: 't', repo: 'x/fail' } }, { fetch: failing });
  assert.equal(res.status, 200);
  assert.ok(body.includes('data-card="ci"'));
  assert.ok(body.includes('CI 상태를 가져오지 못했습니다'));
});

test('database lists canonical entities and switches store by query', async () => {
  const { body } = await page('/admin/database');
  assert.ok(body.includes('JournalEntryEntity'));
  assert.ok(!body.includes('ImportJobEntity'));
  const h = await makeHarness();
  const cookie = await loginReady(h);
  const local = await (await get(h, '/admin/database?store=LocalAuxiliary', cookie)).text();
  assert.ok(local.includes('ImportJobEntity'));
  assert.ok(!local.includes('JournalEntryEntity'));
});

test('database shows CloudKit schema warning', async () => {
  const { body } = await page('/admin/database');
  assert.ok(body.includes('initializeCloudKitSchema'));
});

test('database renders an ER diagram', async () => {
  const { body } = await page('/admin/database');
  assert.equal(count(body, '<pre class="mermaid">'), 1);
  assert.ok(body.includes('erDiagram'));
});

test('architecture renders target graph and module cards', async () => {
  const { body } = await page('/admin/architecture');
  assert.ok(count(body, '<pre class="mermaid">') >= 2);
  assert.ok(body.includes('JournalDomain'));
  assert.ok(body.includes('data-toggle-tests'));
  assert.ok(body.includes('/admin/static/mermaid.min.js'));
});

test('flows renders four diagrams', async () => {
  const { body } = await page('/admin/flows');
  assert.equal(count(body, '<pre class="mermaid">'), 4);
});

test('missing snapshot shows guidance instead of 500', async () => {
  const empty = tempDir();
  for (const path of ['/admin', '/admin/database', '/admin/architecture']) {
    const { res, body } = await page(path, { snapshotDir: empty });
    assert.equal(res.status, 200, path);
    assert.ok(body.includes('scripts/admin-snapshot.sh'), path);
  }
});

test('missing tracking docs show a parse warning', async () => {
  const { res, body } = await page('/admin', { repoRoot: tempDir() });
  assert.equal(res.status, 200);
  assert.ok(body.includes('파싱 실패'));
});

test('pages escape snapshot text', async () => {
  const evil = '<script>alert(1)</script>';
  const dir = writeSnapshotDir({
    'schema.json': {
      schemaVersion: '1.0.0',
      stores: [
        {
          name: 'Canonical',
          cloudKitSynced: true,
          entities: [{ name: evil, attributes: [], relationships: [] }],
        },
      ],
    },
    'architecture.json': { targets: [] },
    'commits.json': { generatedAt: 'x', commits: [{ hash: 'abc', date: 'd', subject: evil }] },
  });
  for (const path of ['/admin', '/admin/database']) {
    const { body } = await page(path, { snapshotDir: dir });
    assert.ok(!body.includes(evil), path);
    assert.ok(body.includes('&lt;script&gt;'), path);
  }
});

test('pages require a changed password', async () => {
  const h = await makeHarness();
  const { login } = await import('./appHelpers.ts');
  const cookie = await login(h);
  for (const path of ['/admin/database', '/admin/architecture', '/admin/flows']) {
    const res = await get(h, path, cookie);
    assert.equal(res.headers.get('location'), '/admin/change-password', path);
  }
});
