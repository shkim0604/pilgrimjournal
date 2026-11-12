import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseChecklist, parseTodo, readTrackingDocs } from '../src/content/checklist.ts';
import { repoRoot } from './appHelpers.ts';

const fixture = `# 출시 전 확인 리스트

## 미룬 항목

- [ ] **A 항목** (2026-10-16, 설명이
  다음 줄로 이어짐)
  - [ ] B 하위 항목
- [x] C 항목 (굵게 없음)
- D 체크박스 아님

## 완료

- [x] **E 완료** 메모
`;

test('counts only top-level checkboxes', () => {
  const result = parseChecklist(fixture);
  assert.ok(result.ok);
  assert.deepEqual(
    result.value.map((item) => [item.title, item.done]),
    [
      ['A 항목', false],
      ['C 항목 (굵게 없음)', true],
      ['E 완료', true],
    ],
  );
});

test('uses section heading', () => {
  const result = parseChecklist(fixture);
  assert.ok(result.ok);
  assert.equal(result.value[0]!.section, '미룬 항목');
  assert.equal(result.value[2]!.section, '완료');
});

test('accepts uppercase X as done', () => {
  const result = parseChecklist('## S\n\n- [X] **done**\n');
  assert.ok(result.ok);
  assert.equal(result.value[0]!.done, true);
});

test('fails when nothing parses', () => {
  const result = parseChecklist('# 제목만\n\n문단\n');
  assert.equal(result.ok, false);
});

test('parseTodo reads bold items under 대기 중 only', () => {
  const result = parseTodo(`# TODO

## 대기 중

- **첫 일** (2026-10-16) 설명
  - **들여쓴 하위** 무시
- **둘째 일** — 설명

## 완료

- **끝난 일**
`);
  assert.ok(result.ok);
  assert.deepEqual(
    result.value.map((item) => item.title),
    ['첫 일', '둘째 일'],
  );
});

test('parseTodo fails without the 대기 중 section', () => {
  assert.equal(parseTodo('# TODO\n\n## 완료\n\n- **x**\n').ok, false);
});

test('parses the real repo docs', () => {
  const docs = readTrackingDocs(repoRoot);
  assert.ok(docs.checklist.ok, docs.checklist.ok ? '' : docs.checklist.error);
  assert.ok(docs.todo.ok, docs.todo.ok ? '' : docs.todo.error);
  assert.ok(docs.checklist.value.length > 0);
  assert.ok(docs.todo.value.length > 0);
  assert.ok(docs.checklist.value.some((item) => !item.done));
});

test('reports a missing docs directory', () => {
  const docs = readTrackingDocs('/nonexistent-pilgrim-root');
  assert.equal(docs.checklist.ok, false);
  assert.equal(docs.todo.ok, false);
});
