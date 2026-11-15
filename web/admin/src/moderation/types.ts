// The operator API's JSON (server/PilgrimAPI/Sources/PilgrimAPI/Admin/Admin.swift and the
// Posts/Comments/Stickers/Media/Common DTOs it embeds), decoded defensively: report content is
// user-written and the response is parsed before anything is rendered or used to build a URL.
// Every ID that ends up in a path is checked to be a UUID here.

export const REPORT_STATUSES = ['open', 'dismissed', 'actioned'] as const;
export type ReportStatus = (typeof REPORT_STATUSES)[number];
export const RESOLUTIONS = ['dismissed', 'actioned'] as const;
export type Resolution = (typeof RESOLUTIONS)[number];
/** Report targets the console can delete (`DELETE /posts|comments|stickers/:id`). */
export const DELETABLE_TARGETS = ['post', 'comment', 'sticker'] as const;
export type DeletableTarget = (typeof DELETABLE_TARGETS)[number];

export type UserRef = { id: string; displayName: string | null; suspendedUntil: string | null };
export type UserSummary = { id: string; displayName: string };
export type PrayerItem = { text: string; topic: string | null; who: string | null };
export type BookInfo = { title: string; author: string | null };
export type MediaRef = { id: string; width: number | null; height: number | null };

export type ReportSnapshot = {
  authorId: string | null;
  authorName: string | null;
  title: string | null;
  body: string | null;
  items: PrayerItem[] | null;
  book: BookInfo | null;
  mediaIds: string[];
  capturedAt: string | null;
};

export type AdminReport = {
  id: string;
  createdAt: string;
  status: string;
  reason: string;
  note: string | null;
  targetType: string;
  targetId: string;
  groupId: string | null;
  groupName: string | null;
  reporter: UserRef | null;
  targetUser: UserRef | null;
  snapshot: ReportSnapshot;
  resolvedAt: string | null;
  resolvedBy: string | null;
};

export type LiveSticker = {
  id: string;
  name: string | null;
  media: MediaRef | null;
  createdBy: UserSummary | null;
  createdAt: string | null;
};

export type LivePost = {
  id: string;
  kind: string;
  author: UserSummary | null;
  title: string | null;
  body: string | null;
  items: PrayerItem[] | null;
  book: BookInfo | null;
  createdAt: string | null;
  expiresAt: string | null;
  media: MediaRef[];
  commentCount: number | null;
};

export type LiveComment = {
  id: string;
  postId: string | null;
  author: UserSummary | null;
  body: string;
  media: MediaRef[];
  sticker: LiveSticker | null;
  stickerRemoved: boolean;
  createdAt: string | null;
};

export type AdminTarget = {
  exists: boolean;
  post: LivePost | null;
  comment: LiveComment | null;
  sticker: LiveSticker | null;
};

export type AdminReportDetail = { report: AdminReport; liveTarget: AdminTarget | null };
export type ReportPage = { items: AdminReport[]; nextCursor: string | null };

export class DecodeError extends Error {
  override name = 'DecodeError';
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The lowercase UUID, or null when `value` is not one. */
export function uuid(value: unknown): string | null {
  return typeof value === 'string' && UUID.test(value) ? value.toLowerCase() : null;
}

type Obj = Record<string, unknown>;

function isObj(value: unknown): value is Obj {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function obj(value: unknown, what: string): Obj {
  if (!isObj(value)) throw new DecodeError(`${what}: expected an object`);
  return value;
}

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

function num(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function requiredId(value: unknown, what: string): string {
  const id = uuid(value);
  if (!id) throw new DecodeError(`${what}: expected a UUID`);
  return id;
}

function list<T>(value: unknown, decode: (item: unknown) => T | null): T[] {
  if (!Array.isArray(value)) return [];
  return value.map(decode).filter((item): item is T => item !== null);
}

function userRef(value: unknown): UserRef | null {
  if (!isObj(value)) return null;
  const id = uuid(value.id);
  return id ? { id, displayName: str(value.displayName), suspendedUntil: str(value.suspendedUntil) } : null;
}

function userSummary(value: unknown): UserSummary | null {
  if (!isObj(value)) return null;
  const id = uuid(value.id);
  return id ? { id, displayName: str(value.displayName) ?? '' } : null;
}

function prayerItem(value: unknown): PrayerItem | null {
  if (!isObj(value)) return null;
  const text = str(value.text);
  return text === null ? null : { text, topic: str(value.topic), who: str(value.who) };
}

function prayerItems(value: unknown): PrayerItem[] | null {
  return Array.isArray(value) ? list(value, prayerItem) : null;
}

function book(value: unknown): BookInfo | null {
  if (!isObj(value)) return null;
  const title = str(value.title);
  return title === null ? null : { title, author: str(value.author) };
}

function mediaRef(value: unknown): MediaRef | null {
  if (!isObj(value)) return null;
  const id = uuid(value.id);
  return id ? { id, width: num(value.width), height: num(value.height) } : null;
}

function snapshot(value: unknown): ReportSnapshot {
  const o = isObj(value) ? value : {};
  return {
    authorId: uuid(o.authorId),
    authorName: str(o.authorName),
    title: str(o.title),
    body: str(o.body),
    items: prayerItems(o.items),
    book: book(o.book),
    mediaIds: list(o.mediaIds, uuid),
    capturedAt: str(o.capturedAt),
  };
}

export function decodeReport(value: unknown): AdminReport {
  const o = obj(value, 'report');
  return {
    id: requiredId(o.id, 'report.id'),
    createdAt: str(o.createdAt) ?? '',
    status: str(o.status) ?? '',
    reason: str(o.reason) ?? '',
    note: str(o.note),
    targetType: str(o.targetType) ?? '',
    targetId: requiredId(o.targetId, 'report.targetId'),
    groupId: uuid(o.groupId),
    groupName: str(o.groupName),
    reporter: userRef(o.reporter),
    targetUser: userRef(o.targetUser),
    snapshot: snapshot(o.snapshot),
    resolvedAt: str(o.resolvedAt),
    resolvedBy: str(o.resolvedBy),
  };
}

function sticker(value: unknown): LiveSticker | null {
  if (!isObj(value)) return null;
  const id = uuid(value.id);
  if (!id) return null;
  return {
    id,
    name: str(value.name),
    media: mediaRef(value.media),
    createdBy: userSummary(value.createdBy),
    createdAt: str(value.createdAt),
  };
}

function post(value: unknown): LivePost | null {
  if (!isObj(value)) return null;
  const id = uuid(value.id);
  if (!id) return null;
  return {
    id,
    kind: str(value.kind) ?? '',
    author: userSummary(value.author),
    title: str(value.title),
    body: str(value.body),
    items: prayerItems(value.items),
    book: book(value.book),
    createdAt: str(value.createdAt),
    expiresAt: str(value.expiresAt),
    media: list(value.media, mediaRef),
    commentCount: num(value.commentCount),
  };
}

function comment(value: unknown): LiveComment | null {
  if (!isObj(value)) return null;
  const id = uuid(value.id);
  if (!id) return null;
  return {
    id,
    postId: uuid(value.postId),
    author: userSummary(value.author),
    body: str(value.body) ?? '',
    media: list(value.media, mediaRef),
    sticker: sticker(value.sticker),
    stickerRemoved: value.stickerRemoved === true,
    createdAt: str(value.createdAt),
  };
}

function target(value: unknown): AdminTarget | null {
  if (!isObj(value)) return null;
  return {
    exists: value.exists === true,
    post: post(value.post),
    comment: comment(value.comment),
    sticker: sticker(value.sticker),
  };
}

export function decodeDetail(value: unknown): AdminReportDetail {
  const o = obj(value, 'report detail');
  return { report: decodeReport(o.report), liveTarget: target(o.liveTarget) };
}

export function decodePage(value: unknown): ReportPage {
  const o = obj(value, 'report page');
  if (!Array.isArray(o.items)) throw new DecodeError('report page: expected items');
  return { items: o.items.map(decodeReport), nextCursor: str(o.nextCursor) };
}

/** The server writes an indefinite suspension as `Date.distantFuture` (year 4001). */
export function isIndefinite(suspendedUntil: string): boolean {
  const year = new Date(suspendedUntil).getUTCFullYear();
  return Number.isFinite(year) && year >= 4000;
}
