import assert from 'node:assert/strict';
import { test } from 'node:test';
import { FLOWS } from '../src/content/flows.ts';
import { erDiagram, targetGraph } from '../src/content/mermaid.ts';
import { STORAGE_DIAGRAM } from '../src/content/modules.ts';

const store = {
  name: 'Canonical',
  cloudKitSynced: true,
  entities: [
    {
      name: 'EntryEntity',
      attributes: [
        { name: 'title', type: 'Optional<String>', optional: true, unique: false, externalStorage: false, transformable: false },
        { name: 'id', type: 'UUID', optional: false, unique: true, externalStorage: false, transformable: false },
      ],
      relationships: [
        { name: 'revisions', destination: 'RevisionEntity', toMany: true, deleteRule: 'cascade', inverse: 'entry' },
      ],
    },
    { name: 'RevisionEntity', attributes: [], relationships: [] },
  ],
};

test('erDiagram includes every entity and relationship', () => {
  const text = erDiagram(store);
  assert.match(text, /^erDiagram/);
  assert.ok(text.includes('EntryEntity {'));
  assert.ok(text.includes('RevisionEntity'));
  assert.match(text, /EntryEntity \|\|--o\{ RevisionEntity : "revisions"/);
  assert.match(text, /String title "optional"/);
  assert.match(text, /UUID id UK/);
});

test('identifiers are sanitized', () => {
  const text = erDiagram({
    ...store,
    entities: [{ name: 'Bad Name<x>', attributes: [{ ...store.entities[0]!.attributes[0]!, name: 'we"ird', type: 'Array<[Int]>' }], relationships: [] }],
  });
  assert.ok(!text.includes('<'));
  assert.ok(!text.includes('"ird'));
  assert.ok(text.includes('Bad_Name_x_'));
});

test('targetGraph shapes targets by kind and hides tests on request', () => {
  const arch = {
    targets: [
      { name: 'Core', kind: 'library' as const, dependencies: [], linkedFrameworks: [] },
      { name: 'App', kind: 'executable' as const, dependencies: ['Core'], linkedFrameworks: ['CloudKit'] },
      { name: 'CoreTests', kind: 'test' as const, dependencies: ['Core'], linkedFrameworks: [] },
    ],
  };
  const all = targetGraph(arch, true);
  assert.ok(all.includes('App(["App"])'));
  assert.ok(all.includes('Core["Core"]'));
  assert.ok(all.includes('CoreTests{{"CoreTests"}}'));
  assert.ok(all.includes('App --> Core'));
  const core = targetGraph(arch, false);
  assert.ok(!core.includes('CoreTests'));
});

test('flow labels contain no inner double quotes', () => {
  assert.equal(FLOWS.length, 4);
  assert.deepEqual(
    FLOWS.map((flow) => flow.id),
    ['launch', 'dayone-import', 'sync', 'account-deletion'],
  );
  for (const source of [...FLOWS.map((flow) => flow.mermaid), STORAGE_DIAGRAM]) {
    // Every quote opens or closes a label, so per line they must pair up.
    for (const line of source.split('\n')) {
      assert.equal(count(line, '"') % 2, 0, `unbalanced quotes in: ${line}`);
      assert.ok(!/[<>]/.test(line.replace(/-->|--o|o--|<--|-\.->|==>/g, '')), `angle bracket in: ${line}`);
    }
  }
});

function count(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}
