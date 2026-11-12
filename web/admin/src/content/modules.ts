// Module descriptions for /admin/architecture, condensed from CLAUDE.md "Architecture".
// A target in architecture.json without an entry here is shown as "설명 없음".

export type ModuleInfo = { role: string; keyTypes: string[] };

export const MODULES: Record<string, ModuleInfo> = {
  JournalDomain: {
    role: '플랫폼 의존이 없는 도메인 타입과 로직. 저장소 계약(프로토콜)과 모든 어댑터가 공유하는 결정적 충돌 해결.',
    keyTypes: ['JournalRepository', 'RevisionResolver', 'ClassificationEngine', 'KindCatalog', 'KindDeletionService'],
  },
  JournalData: {
    role: 'SwiftData + CloudKit 어댑터. Canonical(동기화)과 LocalAuxiliary(기기 전용) 두 저장소, 앱 잠금, iCloud identity binding.',
    keyTypes: [
      'JournalContainerFactory',
      'AppLockService',
      'CloudIdentityBindingService',
      'CloudAccountMonitor',
      'CloudKitSchemaInitializer',
    ],
  },
  DayOneImport: {
    role: 'Day One ZIP을 안전하게 풀고 도메인 draft로 바꾼다. 백업이 쓰는 ZIP 기본 도구도 여기 있다.',
    keyTypes: ['SafeZipArchive', 'DayOneArchiveAnalyzer', 'StoredZipWriter', 'ZipChecksum'],
  },
  JournalSearch: {
    role: '로컬 SQLite FTS5 검색 인덱스. 파생 데이터라 동기화·백업하지 않고 불일치 시 다시 만든다.',
    keyTypes: ['trigram / unicode61 tokenizer', 'LIKE fallback (2자 이하)'],
  },
  JournalSharing: {
    role: '노트북·기록을 iCloud CKShare로 가족과 공유. SwiftData와 따로, 공유 단위마다 pilgrim-share zone을 두고 CKSyncEngine으로 동기화한다.',
    keyTypes: ['SharedSyncEngineHost', 'SharedSpaceService', 'SharedSpaceStore', 'ThreeWayTextMerge', 'SharedEntryMerge'],
  },
  JournalBackup: {
    role: '전체 로컬 백업 내보내기·가져오기.',
    keyTypes: ['BackupRestoreRepository'],
  },
  PilgrimJournal: {
    role: 'SwiftUI 앱. 기록 화면이 열리기 전에 Apple 로그인과 앱 잠금이 접근을 막는다.',
    keyTypes: ['AppModel', 'AppLockCoordinator', 'AppleAuthenticationCoordinator', 'LiveMarkdownTextEditor'],
  },
  JournalChecks: {
    role: 'scripts/check.sh가 실행하는 런타임 검증 실행 파일.',
    keyTypes: [],
  },
  ShareCardEval: {
    role: '공유 카드 추출을 기기 내 Foundation Models로 평가. macOS 26 + Apple Intelligence 필요, CI 제외.',
    keyTypes: [],
  },
  AdminSnapshot: {
    role: '이 관리 콘솔이 읽는 SwiftData 스키마 스냅샷을 만든다 (scripts/admin-snapshot.sh).',
    keyTypes: [],
  },
};

/** Where each kind of data lives; shown on the architecture page. */
export const STORAGE_DIAGRAM = `flowchart LR
  app(["PilgrimJournal 앱"])
  subgraph device ["기기"]
    canonical[("Canonical store")]
    aux[("LocalAuxiliary store: import audit, source snapshot")]
    search[("검색 인덱스: SQLite FTS5")]
    keychain[("Keychain: Apple 세션, 앱 잠금 verifier")]
  end
  subgraph icloud ["사용자의 iCloud"]
    privatedb[("CloudKit private DB")]
    sharezones[("private DB의 pilgrim-share zone: 내가 공유한 것")]
    shareddb[("CloudKit shared DB: 공유받은 것")]
    kvs[("iCloud KVS: 노트북·유형 이름 목록")]
  end
  app --> canonical
  app --> aux
  app --> search
  app --> keychain
  app --> kvs
  canonical -- "mirroring" --> privatedb
  app -- "CKSyncEngine" --> sharezones
  app -- "CKSyncEngine" --> shareddb`;
