import { html } from 'hono/html';
import type { ChecklistItem, TodoItem } from '../content/checklist.ts';
import type { CiRun } from '../content/github.ts';
import type { ConsoleLink } from '../content/links.ts';
import type { Loaded, Snapshot } from '../content/snapshot.ts';
import { parseFailed, snapshotMissing } from './common.ts';
import { layout, type Html } from './layout.ts';

export type DashboardData = {
  checklist: Loaded<ChecklistItem[]>;
  todo: Loaded<TodoItem[]>;
  snapshot: Snapshot;
  ci: Loaded<CiRun> | null;
  links: ConsoleLink[];
};

function releaseGate(checklist: Loaded<ChecklistItem[]>): Html {
  if (!checklist.ok) return html`<section class="card"><h2>출시 게이트</h2>${parseFailed(checklist.error)}</section>`;
  const open = checklist.value.filter((item) => !item.done);
  const done = checklist.value.length - open.length;
  const bySection = new Map<string, ChecklistItem[]>();
  for (const item of open) bySection.set(item.section, [...(bySection.get(item.section) ?? []), item]);
  return html`<section class="card">
    <h2>출시 게이트</h2>
    <p class="stat">${open.length} <small>미완료 · 완료 ${done}</small></p>
    <p class="muted">docs/pre-release-checklist.md · 미완료 <strong>${open.length}</strong> / 전체 ${checklist.value.length}</p>
    ${[...bySection].map(
      ([section, items]) => html`<h3>${section || '(절 없음)'}</h3>
        <ul class="plain">${items.map((item) => html`<li>${item.title}</li>`)}</ul>`,
    )}
  </section>`;
}

function todoCard(todo: Loaded<TodoItem[]>): Html {
  if (!todo.ok) return html`<section class="card"><h2>남은 일</h2>${parseFailed(todo.error)}</section>`;
  return html`<section class="card">
    <h2>남은 일</h2>
    <p class="stat">${todo.value.length} <small>대기 중</small></p>
    <p class="muted">docs/implementation-todo.md</p>
    <ul class="plain">${todo.value.map((item) => html`<li>${item.title}</li>`)}</ul>
  </section>`;
}

function commitsCard(snapshot: Snapshot): Html {
  const commits = snapshot.commits;
  if (!commits.ok) return html`<section class="card"><h2>최근 커밋</h2>${snapshotMissing(commits.error)}</section>`;
  return html`<section class="card">
    <h2>최근 커밋</h2>
    <ul class="plain">
      ${commits.value.commits.slice(0, 10).map(
        (commit) => html`<li><code>${commit.hash}</code> ${commit.subject}
          <div class="muted">${commit.date.slice(0, 10)}</div></li>`,
      )}
    </ul>
  </section>`;
}

function snapshotCard(snapshot: Snapshot): Html {
  const { schema, commits } = snapshot;
  return html`<section class="card">
    <h2>스냅샷</h2>
    ${schema.ok
      ? html`<p>스키마 버전 <strong>${schema.value.schemaVersion}</strong></p>
          <ul class="plain">
            ${schema.value.stores.map(
              (store) => html`<li>${store.name}: 엔티티 ${store.entities.length}개
                ${store.cloudKitSynced ? html`<span class="tag">CloudKit 동기화</span>` : html`<span class="tag ok">기기 전용</span>`}</li>`,
            )}
          </ul>`
      : snapshotMissing(schema.error)}
    ${commits.ok ? html`<p class="muted">생성 시각 ${commits.value.generatedAt}</p>` : ''}
  </section>`;
}

function ciCard(ci: Loaded<CiRun>): Html {
  if (!ci.ok) {
    return html`<section class="card" data-card="ci"><h2>CI</h2>
      <p class="notice error">CI 상태를 가져오지 못했습니다: ${ci.error}</p></section>`;
  }
  const run = ci.value;
  const tone = run.conclusion === 'success' ? 'ok' : run.conclusion ? 'danger' : '';
  return html`<section class="card" data-card="ci">
    <h2>CI (main)</h2>
    <p><span class="tag ${tone}">${run.conclusion ?? run.status}</span> <span class="muted">${run.updatedAt}</span></p>
    ${run.url ? html`<p><a href="${run.url}" rel="noreferrer">실행 기록 보기</a></p>` : ''}
  </section>`;
}

function linksCard(links: ConsoleLink[]): Html {
  return html`<section class="card">
    <h2>바로가기</h2>
    <ul class="plain">
      ${links.map((link) => html`<li><a href="${link.url}" rel="noreferrer">${link.label}</a></li>`)}
    </ul>
  </section>`;
}

export function dashboardPage(data: DashboardData): Html {
  return layout({
    title: '대시보드',
    active: 'dashboard',
    body: html`<div class="grid">
        ${releaseGate(data.checklist)}
        <div>
          ${todoCard(data.todo)}
          ${data.ci ? ciCard(data.ci) : ''}
          ${snapshotCard(data.snapshot)}
          ${linksCard(data.links)}
        </div>
      </div>
      ${commitsCard(data.snapshot)}`,
  });
}
