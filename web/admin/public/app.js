// Renders Mermaid diagrams and wires the architecture page's test-target toggle.
// Loaded as an external file because the console's CSP forbids inline scripts.
(async () => {
  const mermaid = window.mermaid;
  if (!mermaid) return;
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  mermaid.initialize({
    startOnLoad: false,
    securityLevel: 'strict',
    theme: dark ? 'dark' : 'neutral',
    fontFamily: '-apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Noto Sans KR", sans-serif',
  });
  try {
    // Render while everything is visible: Mermaid cannot measure hidden elements.
    await mermaid.run({ querySelector: 'pre.mermaid' });
  } catch (error) {
    console.error('Mermaid render failed', error);
  }

  for (const element of document.querySelectorAll('[data-initially-hidden]')) element.hidden = true;

  const toggle = document.querySelector('[data-toggle-tests]');
  if (toggle) {
    const core = document.querySelector('[data-graph="core"]');
    const all = document.querySelector('[data-graph="all"]');
    toggle.addEventListener('click', () => {
      const showAll = toggle.getAttribute('aria-pressed') !== 'true';
      toggle.setAttribute('aria-pressed', String(showAll));
      toggle.textContent = showAll ? '테스트 타깃 숨기기' : '테스트 타깃 보기';
      if (core) core.hidden = showAll;
      if (all) all.hidden = !showAll;
    });
  }
})();
