import { html } from 'hono/html';
import { targetGraph } from '../content/mermaid.ts';
import { MODULES, STORAGE_DIAGRAM } from '../content/modules.ts';
import type { ArchitectureSnapshot, ArchitectureTarget, Loaded } from '../content/snapshot.ts';
import { diagram, snapshotMissing } from './common.ts';
import { layout, type Html } from './layout.ts';

const KIND_LABELS: Record<ArchitectureTarget['kind'], string> = {
  library: '라이브러리',
  executable: '실행 파일',
  test: '테스트',
};

function moduleCard(target: ArchitectureTarget): Html {
  const info = MODULES[target.name];
  return html`<section class="card">
    <h2>${target.name} <span class="tag">${KIND_LABELS[target.kind]}</span></h2>
    ${info ? html`<p>${info.role}</p>` : html`<p class="muted">설명 없음 — <code>src/content/modules.ts</code>에 추가하세요.</p>`}
    ${info && info.keyTypes.length > 0
      ? html`<p class="muted">핵심: ${info.keyTypes.map((type, i) => html`${i > 0 ? ', ' : ''}<code>${type}</code>`)}</p>`
      : ''}
    <p class="muted">의존: ${target.dependencies.length > 0 ? target.dependencies.join(', ') : '없음'}${target.linkedFrameworks.length > 0
      ? html` · 링크: ${target.linkedFrameworks.join(', ')}`
      : ''}</p>
  </section>`;
}

export function architecturePage(arch: Loaded<ArchitectureSnapshot>): Html {
  const storage = html`<section class="card"><h2>데이터가 사는 곳</h2>${diagram(STORAGE_DIAGRAM)}
    <p class="muted">검색 인덱스와 LocalAuxiliary는 파생·기기 전용 데이터라 동기화하지 않습니다. 자체 서버는 없습니다.</p></section>`;
  if (!arch.ok) {
    return layout({
      title: '아키텍처',
      active: 'architecture',
      body: html`${snapshotMissing(arch.error)}${storage}`,
      scripts: true,
    });
  }
  const nonTest = arch.value.targets.filter((target) => target.kind !== 'test');
  const body = html`<section class="card">
      <h2>SwiftPM 타깃 의존 그래프</h2>
      <p class="muted">화살표는 의존하는 쪽에서 의존 대상으로 향합니다. 사각형은 라이브러리, 둥근 상자는 실행 파일, 육각형은 테스트.</p>
      <p><button type="button" class="link" data-toggle-tests aria-pressed="false">테스트 타깃 보기</button></p>
      ${diagram(targetGraph(arch.value, false), html` data-graph="core"`)}
      ${diagram(targetGraph(arch.value, true), html` data-graph="all" data-initially-hidden`)}
    </section>
    ${storage}
    <div class="grid">${nonTest.map(moduleCard)}</div>`;
  return layout({ title: '아키텍처', active: 'architecture', body, scripts: true });
}
