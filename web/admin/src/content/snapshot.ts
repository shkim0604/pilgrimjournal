import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

export type Loaded<T> = { ok: true; value: T } | { ok: false; error: string };

export type SchemaAttribute = {
  name: string;
  type: string;
  optional: boolean;
  unique: boolean;
  externalStorage: boolean;
  transformable: boolean;
};
export type SchemaRelationship = {
  name: string;
  destination: string;
  toMany: boolean;
  deleteRule: string;
  inverse: string | null;
};
export type SchemaEntity = { name: string; attributes: SchemaAttribute[]; relationships: SchemaRelationship[] };
export type SchemaStore = { name: string; cloudKitSynced: boolean; entities: SchemaEntity[] };
export type SchemaSnapshot = { schemaVersion: string; stores: SchemaStore[] };

export type ArchitectureTarget = {
  name: string;
  kind: 'library' | 'executable' | 'test';
  dependencies: string[];
  linkedFrameworks: string[];
};
export type ArchitectureSnapshot = { targets: ArchitectureTarget[] };

export type Commit = { hash: string; date: string; subject: string };
export type CommitsSnapshot = { generatedAt: string; commits: Commit[] };

export type Snapshot = {
  schema: Loaded<SchemaSnapshot>;
  architecture: Loaded<ArchitectureSnapshot>;
  commits: Loaded<CommitsSnapshot>;
};

const isString = (v: unknown): v is string => typeof v === 'string';
const isBool = (v: unknown): v is boolean => typeof v === 'boolean';
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);
const isArrayOf = <T>(v: unknown, check: (x: unknown) => x is T): v is T[] => Array.isArray(v) && v.every(check);

function isAttribute(v: unknown): v is SchemaAttribute {
  return (
    isObject(v) &&
    isString(v.name) &&
    isString(v.type) &&
    isBool(v.optional) &&
    isBool(v.unique) &&
    isBool(v.externalStorage) &&
    isBool(v.transformable)
  );
}
function isRelationship(v: unknown): v is SchemaRelationship {
  return (
    isObject(v) &&
    isString(v.name) &&
    isString(v.destination) &&
    isBool(v.toMany) &&
    isString(v.deleteRule) &&
    (v.inverse === null || isString(v.inverse))
  );
}
function isEntity(v: unknown): v is SchemaEntity {
  return isObject(v) && isString(v.name) && isArrayOf(v.attributes, isAttribute) && isArrayOf(v.relationships, isRelationship);
}
function isStore(v: unknown): v is SchemaStore {
  return isObject(v) && isString(v.name) && isBool(v.cloudKitSynced) && isArrayOf(v.entities, isEntity);
}
function isSchema(v: unknown): v is SchemaSnapshot {
  return isObject(v) && isString(v.schemaVersion) && isArrayOf(v.stores, isStore);
}
function isTarget(v: unknown): v is ArchitectureTarget {
  return (
    isObject(v) &&
    isString(v.name) &&
    (v.kind === 'library' || v.kind === 'executable' || v.kind === 'test') &&
    isArrayOf(v.dependencies, isString) &&
    isArrayOf(v.linkedFrameworks, isString)
  );
}
function isArchitecture(v: unknown): v is ArchitectureSnapshot {
  return isObject(v) && isArrayOf(v.targets, isTarget);
}
function isCommit(v: unknown): v is Commit {
  return isObject(v) && isString(v.hash) && isString(v.date) && isString(v.subject);
}
function isCommits(v: unknown): v is CommitsSnapshot {
  return isObject(v) && isString(v.generatedAt) && isArrayOf(v.commits, isCommit);
}

const cache = new Map<string, { stamp: string; result: Loaded<unknown> }>();

function loadJson<T>(path: string, check: (v: unknown) => v is T): Loaded<T> {
  let stamp: string;
  try {
    const stat = statSync(path);
    stat.isFile();
    stamp = `${stat.mtimeMs}:${stat.size}`;
  } catch {
    return { ok: false, error: `${path} 파일이 없습니다` };
  }
  const cached = cache.get(path);
  if (cached && cached.stamp === stamp) return cached.result as Loaded<T>;

  let result: Loaded<T>;
  try {
    const parsed: unknown = JSON.parse(readFileSync(path, 'utf8'));
    result = check(parsed) ? { ok: true, value: parsed } : { ok: false, error: `${path} 형식이 예상과 다릅니다` };
  } catch (error) {
    result = { ok: false, error: `${path} 를 읽지 못했습니다: ${(error as Error).message}` };
  }
  cache.set(path, { stamp, result });
  return result;
}

/** Reads the committed snapshot files; each part fails independently so one bad file never breaks the others. */
export function loadSnapshot(dir: string): Snapshot {
  return {
    schema: loadJson(join(dir, 'schema.json'), isSchema),
    architecture: loadJson(join(dir, 'architecture.json'), isArchitecture),
    commits: loadJson(join(dir, 'commits.json'), isCommits),
  };
}
