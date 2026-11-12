import { html } from 'hono/html';
import { erDiagram, mermaidId } from '../content/mermaid.ts';
import type { Loaded, SchemaEntity, SchemaSnapshot } from '../content/snapshot.ts';
import { diagram, snapshotMissing } from './common.ts';
import { layout, type Html } from './layout.ts';

const STORE_LABELS: Record<string, string> = {
  Canonical: 'Canonical (CloudKit 동기화)',
  LocalAuxiliary: 'LocalAuxiliary (기기 전용)',
};

const schemaWarning = html`<div class="notice">
  <strong>CloudKit 스키마는 자동으로 따라오지 않습니다.</strong>
  Development 환경은 non-nil 값으로 실제 내보낸 필드만 압니다. Canonical 모델이나 optional 속성을 추가했다면
  <code>initializeCloudKitSchema()</code>(CloudKitSchemaInitializer)를 실행하고 CloudKit Console에서 Production으로
  배포해야 합니다. 그러지 않으면 Production이 새 필드가 든 record를 오류 없이 거부합니다.
</div>`;

function flag(on: boolean, label: string): Html | string {
  return on ? html`<span class="tag">${label}</span> ` : '';
}

function entityCard(entity: SchemaEntity): Html {
  return html`<section class="card" id="${`entity-${mermaidId(entity.name)}`}">
    <h2>${entity.name}</h2>
    <div class="table-wrap"><table>
      <thead><tr><th>속성</th><th>타입</th><th>특성</th></tr></thead>
      <tbody>
        ${entity.attributes.map(
          (attribute) => html`<tr>
            <td><code>${attribute.name}</code></td>
            <td><code>${attribute.type}</code></td>
            <td>${flag(attribute.optional, 'optional')}${flag(attribute.unique, 'unique')}${flag(
              attribute.externalStorage,
              'external storage',
            )}${flag(attribute.transformable, 'transformable')}</td>
          </tr>`,
        )}
      </tbody>
    </table></div>
    ${entity.relationships.length > 0
      ? html`<h3>관계</h3><div class="table-wrap"><table>
          <thead><tr><th>이름</th><th>대상</th><th>종류</th><th>삭제 규칙</th><th>inverse</th></tr></thead>
          <tbody>
            ${entity.relationships.map(
              (relationship) => html`<tr>
                <td><code>${relationship.name}</code></td>
                <td>${relationship.destination}</td>
                <td>${relationship.toMany ? 'to-many' : 'to-one'}</td>
                <td>${relationship.deleteRule}</td>
                <td>${relationship.inverse ?? '—'}</td>
              </tr>`,
            )}
          </tbody>
        </table></div>`
      : html`<p class="muted">SwiftData 관계 없음 — 다른 엔티티는 ID 속성 값으로 참조합니다.</p>`}
  </section>`;
}

export function databasePage(schema: Loaded<SchemaSnapshot>, requestedStore: string | undefined): Html {
  if (!schema.ok) {
    return layout({ title: '데이터베이스', active: 'database', body: html`${schemaWarning}${snapshotMissing(schema.error)}` });
  }
  const stores = schema.value.stores;
  const store = stores.find((s) => s.name === requestedStore) ?? stores[0];
  const body = html`${schemaWarning}
    <nav class="tabs" aria-label="저장소">
      ${stores.map(
        (s) => html`<a href="/admin/database?store=${encodeURIComponent(s.name)}"${s === store
          ? html` aria-current="page"`
          : ''}>${STORE_LABELS[s.name] ?? s.name}</a>`,
      )}
    </nav>
    ${store
      ? html`<p class="muted">스키마 버전 ${schema.value.schemaVersion} · 엔티티 ${store.entities.length}개 ·
            ${store.cloudKitSynced ? 'CloudKit private DB로 동기화' : '기기에만 저장, 동기화·백업하지 않음'}</p>
          <section class="card"><h2>ER 다이어그램</h2>${diagram(erDiagram(store))}</section>
          ${store.entities.map(entityCard)}`
      : html`<p class="notice error">스냅샷에 저장소가 없습니다.</p>`}`;
  return layout({ title: '데이터베이스', active: 'database', body, scripts: true });
}
