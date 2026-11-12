import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { Loaded } from './snapshot.ts';

export type ChecklistItem = { title: string; done: boolean; section: string };
export type TodoItem = { title: string };

const CHECKBOX = /^- \[( |x|X)\] (.*)$/;
const BOLD = /\*\*(.+?)\*\*/;
const SECTION = /^## (.+?)\s*$/;

function titleOf(text: string): string {
  const bold = BOLD.exec(text);
  return (bold ? bold[1]! : text).trim();
}

/** Top-level `- [ ]` / `- [x]` lines (indented sub-items ignored), each tagged with its `## ` section. */
export function parseChecklist(markdown: string): Loaded<ChecklistItem[]> {
  const items: ChecklistItem[] = [];
  let section = '';
  for (const line of markdown.split(/\r?\n/)) {
    const heading = SECTION.exec(line);
    if (heading) {
      section = heading[1]!;
      continue;
    }
    const box = CHECKBOX.exec(line);
    if (box) items.push({ title: titleOf(box[2]!), done: box[1] !== ' ', section });
  }
  return items.length > 0 ? { ok: true, value: items } : { ok: false, error: '체크박스 항목을 찾지 못했습니다' };
}

/** Top-level `- **title**` items in the `## 대기 중` section. */
export function parseTodo(markdown: string): Loaded<TodoItem[]> {
  const items: TodoItem[] = [];
  let inPending = false;
  let sawPending = false;
  for (const line of markdown.split(/\r?\n/)) {
    const heading = SECTION.exec(line);
    if (heading) {
      inPending = heading[1] === '대기 중';
      sawPending ||= inPending;
      continue;
    }
    if (inPending && line.startsWith('- **')) items.push({ title: titleOf(line.slice(2)) });
  }
  if (!sawPending) return { ok: false, error: '"## 대기 중" 절을 찾지 못했습니다' };
  return items.length > 0 ? { ok: true, value: items } : { ok: false, error: '"대기 중" 항목을 찾지 못했습니다' };
}

function readDoc<T>(path: string, parse: (markdown: string) => Loaded<T>): Loaded<T> {
  try {
    return parse(readFileSync(path, 'utf8'));
  } catch (error) {
    return { ok: false, error: `${path} 를 읽지 못했습니다: ${(error as Error).message}` };
  }
}

export function readTrackingDocs(repoRoot: string): { checklist: Loaded<ChecklistItem[]>; todo: Loaded<TodoItem[]> } {
  return {
    checklist: readDoc(join(repoRoot, 'docs/pre-release-checklist.md'), parseChecklist),
    todo: readDoc(join(repoRoot, 'docs/implementation-todo.md'), parseTodo),
  };
}
