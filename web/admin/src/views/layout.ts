import { html } from 'hono/html';

export type Html = ReturnType<typeof html>;
export type Section = 'dashboard' | 'database' | 'architecture' | 'flows';

const sections: { id: Section; href: string; label: string }[] = [
  { id: 'dashboard', href: '/admin', label: '대시보드' },
  { id: 'database', href: '/admin/database', label: '데이터베이스' },
  { id: 'architecture', href: '/admin/architecture', label: '아키텍처' },
  { id: 'flows', href: '/admin/flows', label: '앱 플로우' },
];

/** Page shell shared by every console page. `nav: false` hides the navigation (login, password change). */
export function layout(opts: { title: string; active?: Section; body: Html; nav?: boolean; scripts?: boolean }): Html {
  const showNav = opts.nav ?? true;
  return html`<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <meta name="robots" content="noindex, nofollow">
  <title>${opts.title} · Pilgrim 관리</title>
  <link rel="stylesheet" href="/admin/static/app.css">
</head>
<body>
  <header class="top">
    <a class="brand" href="/admin">Pilgrim 관리</a>
    ${showNav
      ? html`<nav class="sections" aria-label="섹션">
          ${sections.map(
            (s) => html`<a href="${s.href}"${s.id === opts.active ? html` aria-current="page"` : ''}>${s.label}</a>`,
          )}
        </nav>
        <form class="logout" method="post" action="/admin/logout"><button type="submit">로그아웃</button></form>`
      : ''}
  </header>
  <main>
    <h1>${opts.title}</h1>
    ${opts.body}
  </main>
  ${opts.scripts
    ? html`<script src="/admin/static/mermaid.min.js"></script>
  <script src="/admin/static/app.js"></script>`
    : ''}
</body>
</html>`;
}
