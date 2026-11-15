import type { Config } from '../config.ts';
import {
  decodeDetail,
  decodePage,
  decodeReport,
  type AdminReport,
  type AdminReportDetail,
  type DeletableTarget,
  type ReportPage,
  type ReportStatus,
  type Resolution,
} from './types.ts';

// Server-side client for the group server's operator routes (`/internal/admin/v1/*`, design.md 14절).
// It runs only inside the console process: `ADMIN_API_TOKEN` is set on the outgoing request and
// never appears in a page, a redirect, a response header or a log line. The console calls the
// server over the private Docker network; no incoming request header (Cf-Ray, Cf-Connecting-IP, the
// session cookie) is ever forwarded, so the server's tunnel guard never sees a Cloudflare header.

export const ADMIN_API_PREFIX = '/internal/admin/v1';
const TIMEOUT_MS = 10_000;
/** Group photos are at most 500 KB (PhotoLimits.maxPhotoBytes); anything far larger is not ours. */
const MAX_MEDIA_BYTES = 2 * 1024 * 1024;
const MAX_ACTOR_LENGTH = 100;

/** A failed call. `status` is the HTTP status (0 for a network failure or an unusable response). */
export class AdminApiError extends Error {
  override name = 'AdminApiError';
  readonly status: number;
  readonly code: string | null;

  constructor(status: number, code: string | null, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/**
 * The `X-Admin-Actor` value for a console user: the username as is when it is printable ASCII,
 * otherwise percent-encoded (fetch headers cannot carry non-Latin-1 text). The server requires
 * 1–100 characters.
 */
export function actorHeader(username: string): string {
  const trimmed = username.trim();
  const value = /^[\x20-\x7e]+$/.test(trimmed) ? trimmed : encodeURIComponent(trimmed);
  return value.slice(0, MAX_ACTOR_LENGTH);
}

export type AdminApi = {
  listReports(actor: string, query: { status?: ReportStatus; cursor?: string; limit?: number }): Promise<ReportPage>;
  reportDetail(actor: string, reportId: string): Promise<AdminReportDetail>;
  resolveReport(actor: string, reportId: string, body: { resolution: Resolution; note?: string }): Promise<AdminReport>;
  deleteTarget(actor: string, kind: DeletableTarget, targetId: string, reportId: string): Promise<void>;
  suspendUser(actor: string, userId: string, body: { reason: string; until?: string }): Promise<void>;
  unsuspendUser(actor: string, userId: string): Promise<void>;
  /** The original JPEG of a group photo or sticker. */
  media(actor: string, mediaId: string): Promise<Uint8Array>;
};

const DELETE_PATHS: Record<DeletableTarget, string> = { post: 'posts', comment: 'comments', sticker: 'stickers' };

function isJpeg(bytes: Uint8Array): boolean {
  return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}

async function errorFrom(response: Response): Promise<AdminApiError> {
  let code: string | null = null;
  try {
    const body = (await response.json()) as { error?: { code?: unknown } };
    if (typeof body?.error?.code === 'string') code = body.error.code;
  } catch {
    // Not the server's error body (e.g. a proxy page); the status is enough.
  }
  return new AdminApiError(response.status, code, `HTTP ${response.status}${code ? ` ${code}` : ''}`);
}

export function createAdminApi(config: NonNullable<Config['adminApi']>, fetchFn: typeof fetch): AdminApi {
  const call = async (
    method: 'GET' | 'POST' | 'DELETE',
    path: string,
    actor: string,
    opts: { query?: Record<string, string | undefined>; json?: unknown; accept?: string } = {},
  ): Promise<Response> => {
    const url = new URL(`${config.baseUrl}${ADMIN_API_PREFIX}${path}`);
    for (const [key, value] of Object.entries(opts.query ?? {})) {
      if (value !== undefined) url.searchParams.set(key, value);
    }
    // Built from scratch on every call: nothing from the browser's request is copied in.
    const headers = new Headers({
      Accept: opts.accept ?? 'application/json',
      'X-Admin-Token': config.token,
      'X-Admin-Actor': actorHeader(actor),
    });
    if (opts.json !== undefined) headers.set('Content-Type', 'application/json');
    let response: Response;
    try {
      response = await fetchFn(url, {
        method,
        headers,
        body: opts.json === undefined ? undefined : JSON.stringify(opts.json),
        // A redirect would carry the token somewhere else; the operator routes never redirect.
        redirect: 'error',
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
    } catch (error) {
      throw new AdminApiError(0, null, `request failed: ${(error as Error).name}`);
    }
    if (!response.ok) throw await errorFrom(response);
    return response;
  };

  const json = async (response: Response): Promise<unknown> => {
    try {
      return await response.json();
    } catch {
      throw new AdminApiError(0, null, 'response is not JSON');
    }
  };

  const decoded = <T>(decode: (value: unknown) => T, value: unknown): T => {
    try {
      return decode(value);
    } catch (error) {
      throw new AdminApiError(0, null, `unexpected response: ${(error as Error).message}`);
    }
  };

  const id = (value: string) => encodeURIComponent(value);

  return {
    async listReports(actor, query) {
      const response = await call('GET', '/reports', actor, {
        query: {
          status: query.status,
          cursor: query.cursor,
          limit: query.limit === undefined ? undefined : String(query.limit),
        },
      });
      return decoded(decodePage, await json(response));
    },

    async reportDetail(actor, reportId) {
      return decoded(decodeDetail, await json(await call('GET', `/reports/${id(reportId)}`, actor)));
    },

    async resolveReport(actor, reportId, body) {
      const response = await call('POST', `/reports/${id(reportId)}/resolve`, actor, { json: body });
      return decoded(decodeReport, await json(response));
    },

    async deleteTarget(actor, kind, targetId, reportId) {
      await call('DELETE', `/${DELETE_PATHS[kind]}/${id(targetId)}`, actor, { query: { reportId } });
    },

    async suspendUser(actor, userId, body) {
      await call('POST', `/users/${id(userId)}/suspend`, actor, { json: body });
    },

    async unsuspendUser(actor, userId) {
      await call('POST', `/users/${id(userId)}/unsuspend`, actor);
    },

    async media(actor, mediaId) {
      const response = await call('GET', `/media/${id(mediaId)}`, actor, { accept: 'image/jpeg' });
      const type = response.headers.get('content-type') ?? '';
      const length = Number(response.headers.get('content-length') ?? '0');
      if (!type.toLowerCase().startsWith('image/jpeg') || length > MAX_MEDIA_BYTES) {
        await response.body?.cancel();
        throw new AdminApiError(0, null, 'media is not a JPEG of the expected size');
      }
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.length > MAX_MEDIA_BYTES || !isJpeg(bytes)) {
        throw new AdminApiError(0, null, 'media is not a JPEG of the expected size');
      }
      return bytes;
    },
  };
}
