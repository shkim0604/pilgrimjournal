import type { Config } from '../config.ts';
import type { Loaded } from './snapshot.ts';

export type CiRun = { status: string; conclusion: string | null; url: string; updatedAt: string };

const CACHE_MS = 5 * 60_000;
const cache = new Map<string, { at: number; result: Loaded<CiRun> }>();

/** The latest GitHub Actions run on main, cached for five minutes; any failure is reported, never thrown. */
export async function latestCiRun(
  github: NonNullable<Config['github']>,
  fetchFn: typeof fetch,
  now: number,
): Promise<Loaded<CiRun>> {
  const cached = cache.get(github.repo);
  if (cached && now - cached.at < CACHE_MS) return cached.result;

  let result: Loaded<CiRun>;
  try {
    const response = await fetchFn(`https://api.github.com/repos/${github.repo}/actions/runs?branch=main&per_page=1`, {
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: `Bearer ${github.token}`,
        'User-Agent': 'pilgrim-admin-console',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const body = (await response.json()) as { workflow_runs?: Record<string, unknown>[] };
    const run = body.workflow_runs?.[0];
    if (!run) throw new Error('workflow run 없음');
    result = {
      ok: true,
      value: {
        status: String(run.status ?? ''),
        conclusion: run.conclusion == null ? null : String(run.conclusion),
        url: String(run.html_url ?? ''),
        updatedAt: String(run.updated_at ?? ''),
      },
    };
  } catch (error) {
    result = { ok: false, error: (error as Error).message };
  }
  cache.set(github.repo, { at: now, result });
  return result;
}
