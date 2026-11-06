import { html } from 'hono/html';
import type { Html } from './layout.ts';

/** Shown in place of a card whose snapshot file is missing or unreadable. */
export function snapshotMissing(error: string): Html {
  return html`<div class="notice error" role="status">
    <strong>스냅샷 없음</strong> — 저장소 루트에서 <code>scripts/admin-snapshot.sh</code>를 실행하고 커밋하세요.
    <div class="muted">${error}</div>
  </div>`;
}

/** Shown in place of a card whose tracking document could not be parsed. */
export function parseFailed(error: string): Html {
  return html`<div class="notice error" role="status"><strong>파싱 실패</strong> — ${error}</div>`;
}

export function diagram(source: string, attrs: Html | string = ''): Html {
  return html`<div class="diagram"${attrs}><pre class="mermaid">${source}</pre></div>`;
}
