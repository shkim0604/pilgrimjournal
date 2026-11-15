import { html } from 'hono/html';
import {
  DELETABLE_TARGETS,
  REPORT_STATUSES,
  isIndefinite,
  type AdminReport,
  type AdminReportDetail,
  type BookInfo,
  type LiveComment,
  type LivePost,
  type LiveSticker,
  type MediaRef,
  type PrayerItem,
  type ReportPage,
  type ReportStatus,
  type UserRef,
} from '../moderation/types.ts';
import { layout, type Html } from './layout.ts';

// Every value from a report (snapshot, note, names, group name) is user-written. It is only ever
// interpolated through `html`, which escapes it; nothing here uses `raw`.

const STATUS_LABELS: Record<string, string> = { open: '열림', dismissed: '기각', actioned: '조치함' };
const REASON_LABELS: Record<string, string> = {
  spam: '스팸',
  harassment: '괴롭힘',
  inappropriate: '부적절한 내용',
  selfHarm: '자해·자살 위험',
  other: '기타',
};
const TARGET_LABELS: Record<string, string> = { post: '글', comment: '댓글', sticker: '스티커', user: '사용자' };
const POST_KIND_LABELS: Record<string, string> = { prayer: '기도제목', bookReport: '독후감', testimony: '간증' };

/** Result messages after an action, picked by a fixed key so nothing from the URL is echoed. */
export const NOTICES = {
  resolved: { tone: 'ok', text: '신고를 처리했습니다.' },
  deleted: { tone: 'ok', text: '신고된 항목을 지웠습니다.' },
  suspended: { tone: 'ok', text: '사용자를 정지했습니다.' },
  unsuspended: { tone: 'ok', text: '사용자 정지를 풀었습니다.' },
  confirmRequired: { tone: 'error', text: '확인란을 체크해야 실행됩니다.' },
  reasonRequired: { tone: 'error', text: '정지 사유를 적어야 합니다(500자 이하).' },
  invalid: { tone: 'error', text: '요청 값이 올바르지 않습니다.' },
  notFound: { tone: 'error', text: '대상을 찾지 못했습니다. 이미 지워졌을 수 있습니다.' },
  unauthorized: { tone: 'error', text: '그룹 서버가 토큰을 거부했습니다. 콘솔과 서버의 ADMIN_API_TOKEN이 같은지 확인하세요.' },
  forbidden: { tone: 'error', text: '그룹 서버가 요청을 거부했습니다. ADMIN_API_URL이 Cloudflare를 거치지 않는 내부 주소인지 확인하세요.' },
  unavailable: { tone: 'error', text: '그룹 서버에 연결하지 못했습니다. 잠시 후 다시 시도하세요.' },
} as const;
export type NoticeKey = keyof typeof NOTICES;

export function isNoticeKey(value: string | undefined): value is NoticeKey {
  return value !== undefined && Object.hasOwn(NOTICES, value);
}

const kst = new Intl.DateTimeFormat('ko-KR', {
  timeZone: 'Asia/Seoul',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

/** An API timestamp in Korea time, or the raw text when it does not parse. */
export function formatDate(value: string | null): string {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : kst.format(date);
}

function label(map: Record<string, string>, value: string): string {
  return Object.hasOwn(map, value) ? map[value]! : value;
}

function noticeBox(key: NoticeKey | undefined): Html | string {
  if (!key) return '';
  const notice = NOTICES[key];
  return html`<p class="notice ${notice.tone}" role="${notice.tone === 'error' ? 'alert' : 'status'}">${notice.text}</p>`;
}

function statusTag(status: string): Html {
  const tone = status === 'open' ? 'danger' : status === 'actioned' ? 'ok' : '';
  return html`<span class="tag ${tone}">${label(STATUS_LABELS, status)}</span>`;
}

function suspension(user: UserRef): Html {
  if (!user.suspendedUntil) return html`<span class="tag ok">정지 안 됨</span>`;
  if (isIndefinite(user.suspendedUntil)) return html`<span class="tag danger">무기한 정지</span>`;
  return html`<span class="tag danger">정지 중 · ${formatDate(user.suspendedUntil)}까지</span>`;
}

function userCell(user: UserRef | null): Html {
  if (!user) return html`<span class="muted">탈퇴했거나 없음</span>`;
  return html`${user.displayName || html`<span class="muted">(이름 없음)</span>`}`;
}

/** A one-line preview of what was reported, cut to `max` characters. */
function preview(report: AdminReport, max = 60): string {
  const s = report.snapshot;
  const text = s.title || s.body || s.items?.[0]?.text || s.book?.title || '';
  const chars = [...text.replace(/\s+/g, ' ').trim()];
  return chars.length > max ? `${chars.slice(0, max).join('')}…` : chars.join('');
}

const multiline = 'white-space: pre-wrap; margin: 0 0 8px;';
const inlineControl = 'display: inline; width: auto; margin: 0 6px 0 0;';

export function mediaUrl(id: string): string {
  return `/admin/media/${encodeURIComponent(id)}`;
}

function photos(ids: string[]): Html | string {
  if (ids.length === 0) return '';
  return html`<div style="display: flex; flex-wrap: wrap; gap: 8px; margin: 8px 0;">
    ${ids.map(
      (id) => html`<a href="${mediaUrl(id)}" target="_blank" rel="noreferrer"><img src="${mediaUrl(id)}" alt="첨부 사진" loading="lazy"
        style="max-width: 240px; max-height: 240px; border-radius: 8px; border: 1px solid var(--rule);"></a>`,
    )}
  </div>`;
}

function mediaIds(media: MediaRef[]): string[] {
  return media.map((m) => m.id);
}

function prayerItems(items: PrayerItem[] | null): Html | string {
  if (!items || items.length === 0) return '';
  return html`<ol>
    ${items.map(
      (item) => html`<li><span style="white-space: pre-wrap;">${item.text}</span>${item.who || item.topic
        ? html` <span class="muted">(${[item.who, item.topic].filter(Boolean).join(' · ')})</span>`
        : ''}</li>`,
    )}
  </ol>`;
}

function bookLine(book: BookInfo | null): Html | string {
  if (!book) return '';
  return html`<p>책: <strong>${book.title}</strong>${book.author ? html` · ${book.author}` : ''}</p>`;
}

function textBlock(title: string | null, body: string | null): Html {
  return html`${title ? html`<h3>${title}</h3>` : ''}${body ? html`<p style="${multiline}">${body}</p>` : ''}`;
}

// MARK: - List

function statusTabs(active: ReportStatus): Html {
  return html`<nav class="tabs" aria-label="신고 상태">
    ${REPORT_STATUSES.map(
      (status) => html`<a href="/admin/reports?status=${status}"${status === active
        ? html` aria-current="page"`
        : ''}>${STATUS_LABELS[status]}</a>`,
    )}
  </nav>`;
}

export function reportsDisabledPage(): Html {
  return layout({
    title: '신고',
    active: 'reports',
    body: html`<div class="notice">
      <strong>신고 기능이 꺼져 있습니다.</strong> 콘솔 <code>.env</code>에 그룹 서버와 같은
      <code>ADMIN_API_TOKEN</code>을 넣고(필요하면 <code>ADMIN_API_URL</code>도) 다시 시작하세요.
    </div>`,
  });
}

export function reportsErrorPage(key: NoticeKey): Html {
  return layout({
    title: '신고',
    active: 'reports',
    body: html`${noticeBox(key)}<p><a href="/admin/reports">신고 목록으로</a></p>`,
  });
}

export function reportListPage(data: { status: ReportStatus; page: ReportPage }): Html {
  const { status, page } = data;
  const rows = page.items.map(
    (report) => html`<tr>
      <td><a href="/admin/reports/${report.id}">${formatDate(report.createdAt)}</a></td>
      <td>${statusTag(report.status)}</td>
      <td>${label(REASON_LABELS, report.reason)}</td>
      <td>${label(TARGET_LABELS, report.targetType)}</td>
      <td>${report.groupName ?? html`<span class="muted">—</span>`}</td>
      <td>${userCell(report.targetUser)}</td>
      <td>${userCell(report.reporter)}</td>
      <td>${preview(report)}</td>
    </tr>`,
  );
  const body = html`${statusTabs(status)}
    <section class="card">
      ${page.items.length === 0
        ? html`<p class="muted">${STATUS_LABELS[status]} 상태의 신고가 없습니다.</p>`
        : html`<div class="table-wrap"><table>
            <thead><tr><th>접수</th><th>상태</th><th>사유</th><th>대상</th><th>그룹</th><th>작성자</th><th>신고자</th><th>내용</th></tr></thead>
            <tbody>${rows}</tbody>
          </table></div>`}
      ${page.nextCursor
        ? html`<p><a href="/admin/reports?status=${status}&amp;cursor=${encodeURIComponent(page.nextCursor)}">다음 페이지</a></p>`
        : ''}
    </section>
    <p class="muted">신고 스냅샷은 90일 동안 보관됩니다. 사진은 원본이 남아 있을 때만 보입니다.</p>`;
  return layout({ title: '신고', active: 'reports', body });
}

// MARK: - Detail

function reportCard(report: AdminReport): Html {
  return html`<section class="card">
    <h2>신고 정보</h2>
    <div class="table-wrap"><table><tbody>
      <tr><th>상태</th><td>${statusTag(report.status)}${report.resolvedAt
        ? html` <span class="muted">${formatDate(report.resolvedAt)} · ${report.resolvedBy ?? '—'}</span>`
        : ''}</td></tr>
      <tr><th>사유</th><td>${label(REASON_LABELS, report.reason)}</td></tr>
      <tr><th>신고자 메모</th><td>${report.note ? html`<span style="white-space: pre-wrap;">${report.note}</span>` : html`<span class="muted">없음</span>`}</td></tr>
      <tr><th>대상</th><td>${label(TARGET_LABELS, report.targetType)} <code>${report.targetId}</code></td></tr>
      <tr><th>그룹</th><td>${report.groupName ?? '—'}${report.groupId ? html` <code>${report.groupId}</code>` : ''}</td></tr>
      <tr><th>접수</th><td>${formatDate(report.createdAt)}</td></tr>
      <tr><th>작성자</th><td>${userCell(report.targetUser)}${report.targetUser
        ? html` ${suspension(report.targetUser)} <code>${report.targetUser.id}</code>`
        : ''}</td></tr>
      <tr><th>신고자</th><td>${userCell(report.reporter)}${report.reporter
        ? html` ${suspension(report.reporter)} <code>${report.reporter.id}</code>`
        : ''}</td></tr>
    </tbody></table></div>
  </section>`;
}

function snapshotCard(report: AdminReport): Html {
  const s = report.snapshot;
  const empty = !s.title && !s.body && !s.items?.length && !s.book && s.mediaIds.length === 0;
  return html`<section class="card" data-card="snapshot">
    <h2>신고 당시 스냅샷</h2>
    <p class="muted">작성자 ${s.authorName ?? '—'} · 캡처 ${formatDate(s.capturedAt)}</p>
    ${empty ? html`<p class="muted">저장된 내용이 없습니다.</p>` : ''}
    ${textBlock(s.title, s.body)}
    ${bookLine(s.book)}
    ${prayerItems(s.items)}
    ${photos(s.mediaIds)}
  </section>`;
}

function livePost(post: LivePost): Html {
  return html`<p class="muted">${label(POST_KIND_LABELS, post.kind)} · 작성자 ${post.author?.displayName || '—'} ·
      ${formatDate(post.createdAt)} 작성 · ${formatDate(post.expiresAt)} 만료${post.commentCount === null
        ? ''
        : html` · 댓글 ${post.commentCount}개`}</p>
    ${textBlock(post.title, post.body)}
    ${bookLine(post.book)}
    ${prayerItems(post.items)}
    ${photos(mediaIds(post.media))}`;
}

function liveSticker(sticker: LiveSticker): Html {
  return html`<p class="muted">스티커 ${sticker.name ?? '(이름 없음)'} · 만든 사람 ${sticker.createdBy?.displayName || '—'} ·
      ${formatDate(sticker.createdAt)}</p>
    ${photos(sticker.media ? [sticker.media.id] : [])}`;
}

function liveComment(comment: LiveComment): Html {
  return html`<p class="muted">작성자 ${comment.author?.displayName || '—'} · ${formatDate(comment.createdAt)}</p>
    ${comment.body ? html`<p style="${multiline}">${comment.body}</p>` : ''}
    ${photos(mediaIds(comment.media))}
    ${comment.sticker ? html`<h3>붙인 스티커</h3>${liveSticker(comment.sticker)}` : ''}
    ${comment.stickerRemoved ? html`<p class="muted">지워진 스티커를 썼던 댓글입니다.</p>` : ''}`;
}

function liveCard(detail: AdminReportDetail): Html {
  const live = detail.liveTarget;
  let content: Html;
  if (!live || !live.exists) {
    content = html`<p class="muted">원본이 지워졌거나 더 이상 없습니다. 스냅샷만 남아 있습니다.</p>`;
  } else if (live.post) {
    content = livePost(live.post);
  } else if (live.comment) {
    content = liveComment(live.comment);
  } else if (live.sticker) {
    content = liveSticker(live.sticker);
  } else {
    content = html`<p class="muted">대상 ${label(TARGET_LABELS, detail.report.targetType)}이(가) 아직 있습니다.</p>`;
  }
  return html`<section class="card" data-card="live"><h2>현재 원본</h2>${content}</section>`;
}

function confirmBox(text: string): Html {
  return html`<label style="font-weight: 500;"><input type="checkbox" name="confirm" value="yes" required style="${inlineControl}">${text}</label>`;
}

function deleteForm(detail: AdminReportDetail): Html | string {
  const type = detail.report.targetType;
  if (!(DELETABLE_TARGETS as readonly string[]).includes(type)) return '';
  if (!detail.liveTarget?.exists) return html`<h3>${label(TARGET_LABELS, type)} 삭제</h3><p class="muted">이미 지워졌습니다.</p>`;
  return html`<form method="post" action="/admin/reports/${detail.report.id}/delete">
    <h3>${label(TARGET_LABELS, type)} 삭제</h3>
    <p class="muted">되돌릴 수 없습니다. ${type === 'post' ? '댓글·반응·사진도 함께 지워집니다.' : type === 'sticker' ? '이 스티커를 쓴 댓글은 "지워진 스티커"로 보입니다.' : '댓글의 사진도 함께 지워집니다.'}</p>
    ${confirmBox('지우는 것을 확인했습니다')}
    <button type="submit">지우기</button>
  </form>`;
}

function suspendForms(who: 'target' | 'reporter', user: UserRef | null, reportId: string): Html | string {
  if (!user) return '';
  const title = who === 'target' ? '작성자' : '신고자';
  const name = user.displayName || '(이름 없음)';
  const unsuspend = user.suspendedUntil
    ? html`<form method="post" action="/admin/reports/${reportId}/unsuspend">
        <input type="hidden" name="who" value="${who}">
        <button type="submit">${title} 정지 풀기</button>
      </form>`
    : '';
  return html`<div style="margin: 0 0 16px;">
    <h3>${title} 정지 · ${name} ${suspension(user)}</h3>
    ${unsuspend}
    <form method="post" action="/admin/reports/${reportId}/suspend">
      <input type="hidden" name="who" value="${who}">
      <label>기간
        <select name="duration" style="display: block; margin-top: 4px; padding: 8px; font: inherit;">
          <option value="1">1일</option>
          <option value="7" selected>7일</option>
          <option value="30">30일</option>
          <option value="indefinite">무기한</option>
        </select>
      </label>
      <label>사유 (서버 기록에 남음, 500자 이하)
        <input name="reason" maxlength="500" required>
      </label>
      ${confirmBox('정지하면 이 사람은 그룹 기능을 쓸 수 없습니다. 글은 따로 지워야 합니다')}
      <button type="submit">${user.suspendedUntil ? '정지 기간 바꾸기' : '정지'}</button>
    </form>
  </div>`;
}

function resolveForm(report: AdminReport): Html {
  return html`<form method="post" action="/admin/reports/${report.id}/resolve">
    <h3>${report.status === 'open' ? '처리 완료' : '처리 결과 바꾸기'}</h3>
    <label>운영자 메모 (선택, 500자 이하, 서버 기록에만 남음)
      <input name="note" maxlength="500">
    </label>
    <button type="submit" name="resolution" value="actioned">조치함으로 닫기</button>
    <button type="submit" name="resolution" value="dismissed">기각</button>
  </form>`;
}

export function reportDetailPage(detail: AdminReportDetail, notice?: NoticeKey): Html {
  const report = detail.report;
  const body = html`<p><a href="/admin/reports?status=${(REPORT_STATUSES as readonly string[]).includes(report.status)
      ? report.status
      : 'open'}">← 신고 목록</a></p>
    ${noticeBox(notice)}
    <div class="grid">
      ${snapshotCard(report)}
      ${liveCard(detail)}
    </div>
    <div style="height: 16px;"></div>
    ${reportCard(report)}
    <section class="card" data-card="actions">
      <h2>조치</h2>
      ${deleteForm(detail)}
      ${suspendForms('target', report.targetUser, report.id)}
      ${suspendForms('reporter', report.reporter, report.id)}
      ${resolveForm(report)}
    </section>`;
  return layout({ title: '신고 상세', active: 'reports', body });
}
