import { html } from 'hono/html';
import { FLOWS } from '../content/flows.ts';
import { diagram } from './common.ts';
import { layout, type Html } from './layout.ts';

export function flowsPage(): Html {
  return layout({
    title: '앱 플로우',
    active: 'flows',
    scripts: true,
    body: html`<nav class="tabs" aria-label="흐름">
        ${FLOWS.map((flow) => html`<a href="#${flow.id}">${flow.title}</a>`)}
      </nav>
      ${FLOWS.map(
        (flow) => html`<section class="card" id="${flow.id}">
          <h2>${flow.title}</h2>
          <p class="muted">${flow.summary}</p>
          ${diagram(flow.mermaid)}
        </section>`,
      )}`,
  });
}
