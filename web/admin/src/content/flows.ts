// App flow diagrams for /admin/flows. They describe current app behaviour (CLAUDE.md, docs/privacy.md,
// docs/known-issues.md); update them together with the app when a flow changes.
// Labels are always quoted and never contain a double quote or angle brackets.

export type Flow = { id: string; title: string; summary: string; mermaid: string };

export const FLOWS: Flow[] = [
  {
    id: 'launch',
    title: '실행 · 인증 · 잠금 · iCloud 연결',
    summary:
      'Apple 로그인은 앱 접근용이고, 동기화는 기기의 시스템 iCloud 계정을 쓴다. 두 가지는 따로 판단한다.',
    mermaid: `flowchart TD
  start(["앱 실행"]) --> session{"Keychain에 Apple 로그인 세션?"}
  session -- "없음 또는 철회됨" --> siwa["Sign in with Apple (email scope만)"]
  siwa --> claim["로컬 기록을 이 Apple 사용자에게 귀속"]
  session -- "있음" --> lock{"앱 잠금 설정?"}
  claim --> lock
  lock -- "예" --> unlock["AppLockCoordinator: 비밀번호 또는 생체 인증"]
  lock -- "아니오" --> icloud
  unlock --> icloud{"시스템 iCloud 사용 가능?"}
  icloud -- "아니오" --> local["local-only로 계속 동작"]
  icloud -- "예" --> binding{"private DB의 binding record"}
  binding -- "없음" --> bind["사용자 ID 단방향 해시로 binding 생성"]
  binding -- "같은 해시" --> journal(["기록 화면"])
  binding -- "다른 해시" --> block["기록 화면 차단 (병합하지 않음)"]
  bind --> journal
  local --> journal`,
  },
  {
    id: 'dayone-import',
    title: 'Day One 가져오기',
    summary: 'ZIP은 안전하게 풀고, 규칙에 맞지 않는 기록은 미분류로 남긴다. 감사 기록은 기기 전용 저장소에 둔다.',
    mermaid: `flowchart TD
  pick(["Day One ZIP 선택"]) --> unzip["SafeZipArchive: 경로·크기 검사 후 추출"]
  unzip --> analyze["DayOneArchiveAnalyzer: JSON·첨부 구조 분석"]
  analyze --> warn{"구조 경고?"}
  warn -- "있음" --> report["경고 수만 표시 (원문은 기록하지 않음)"]
  warn -- "없음" --> classify
  report --> classify["ClassificationEngine: 규칙으로 유형 결정"]
  classify --> draft["도메인 draft 생성 (미분류 포함)"]
  draft --> save["Canonical store에 저장 (CloudKit 동기화)"]
  draft --> audit["ImportJob · ImportItem · SourceSnapshot (LocalAuxiliary, 기기 전용)"]
  save --> index["검색 인덱스 갱신 (SQLite FTS5, 기기 전용)"]`,
  },
  {
    id: 'sync',
    title: '편집 · 동기화 · 충돌 해결',
    summary: '모든 어댑터가 같은 결정적 규칙으로 충돌을 푼다: 시각, 기기 ID, UUID 순서.',
    mermaid: `flowchart TD
  edit(["기록 편집"]) --> revision["EntryRevision 생성 (timestamp, deviceID, UUID)"]
  revision --> canonical["Canonical store 저장"]
  canonical --> mirror["SwiftData CloudKit mirroring (private DB)"]
  mirror --> other["다른 기기에서 원격 변경 수신"]
  other --> resolve{"RevisionResolver"}
  resolve -- "1. 더 늦은 timestamp" --> winner["승자 revision 적용"]
  resolve -- "2. 같으면 deviceID" --> winner
  resolve -- "3. 같으면 UUID" --> winner
  winner --> keep["진 revision도 이력에 보존"]
  winner --> reindex["검색 인덱스 재계산 (불일치 시 전체 재구성)"]`,
  },
  {
    id: 'account-deletion',
    title: '계정 삭제',
    summary: '설정 › Apple 로그인 › 계정 삭제. iCloud 단계가 실패하면 로컬 데이터는 건드리지 않는다.',
    mermaid: `flowchart TD
  ask(["계정 삭제 확인"]) --> close["1. 열린 저장소 닫기 (mirroring 재업로드 방지)"]
  close --> cloud{"iCloud 연결됨?"}
  cloud -- "예" --> mine{"binding이 이 사용자 것?"}
  mine -- "아니오" --> stop["아무것도 지우지 않음"]
  mine -- "예" --> zones["2. binding record와 CloudKit zone 삭제"]
  zones -- "실패" --> retry["오류 표시, 로컬 데이터 유지"]
  zones -- "성공" --> files
  cloud -- "아니오" --> files["3. 이 사용자의 로컬 파일 삭제 (이 기기만)"]
  files --> defaults["4. UserDefaults suite와 iCloud KVS 키 삭제"]
  defaults --> keychain["5. Keychain 세션·앱 잠금 삭제, 로그인 화면으로"]`,
  },
];
