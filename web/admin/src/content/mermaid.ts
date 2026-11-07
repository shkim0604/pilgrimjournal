import type { ArchitectureSnapshot, SchemaStore } from './snapshot.ts';

/** Mermaid identifiers: word characters only. */
export function mermaidId(value: string): string {
  return value.replace(/[^A-Za-z0-9_]/g, '_') || '_';
}

/** `Optional<Data>` → `Data`, then anything Mermaid cannot read as a type word becomes `_`. */
function attributeType(type: string): string {
  const inner = /^Optional<(.+)>$/.exec(type)?.[1] ?? type;
  return mermaidId(inner);
}

export function erDiagram(store: SchemaStore): string {
  const lines = ['erDiagram'];
  for (const entity of store.entities) {
    const id = mermaidId(entity.name);
    if (entity.attributes.length === 0) {
      lines.push(`  ${id} {`, '  }');
      continue;
    }
    lines.push(`  ${id} {`);
    for (const attribute of entity.attributes) {
      const notes: string[] = [];
      if (attribute.optional) notes.push('optional');
      if (attribute.externalStorage) notes.push('external');
      if (attribute.transformable) notes.push('transformable');
      const key = attribute.unique ? ' UK' : '';
      const comment = notes.length > 0 ? ` "${notes.join(', ')}"` : '';
      lines.push(`    ${attributeType(attribute.type)} ${mermaidId(attribute.name)}${key}${comment}`);
    }
    lines.push('  }');
  }
  for (const entity of store.entities) {
    for (const relationship of entity.relationships) {
      const cardinality = relationship.toMany ? '||--o{' : '||--o|';
      lines.push(
        `  ${mermaidId(entity.name)} ${cardinality} ${mermaidId(relationship.destination)} : "${mermaidId(relationship.name)}"`,
      );
    }
  }
  return lines.join('\n');
}

/** SwiftPM target graph: libraries as boxes, executables as stadiums, tests as hexagons; edges point at dependencies. */
export function targetGraph(arch: ArchitectureSnapshot, includeTests: boolean): string {
  const targets = arch.targets.filter((target) => includeTests || target.kind !== 'test');
  const names = new Set(targets.map((target) => target.name));
  const lines = ['graph TD'];
  for (const target of targets) {
    const id = mermaidId(target.name);
    const label = `"${mermaidId(target.name)}"`;
    if (target.kind === 'library') lines.push(`  ${id}[${label}]`);
    else if (target.kind === 'executable') lines.push(`  ${id}([${label}])`);
    else lines.push(`  ${id}{{${label}}}`);
  }
  for (const target of targets) {
    for (const dependency of target.dependencies) {
      if (names.has(dependency)) lines.push(`  ${mermaidId(target.name)} --> ${mermaidId(dependency)}`);
    }
  }
  return lines.join('\n');
}
