# 구현 TODO (미룬 기능·개선)

출시 게이트가 아닌, "나중에 만들 것"을 모아둔 문서. 실기기 검증 항목은
`docs/pre-release-checklist.md`를 본다. 그룹·공유·구독 같은 장기 방향은
`docs/roadmap.md`에 따로 둔다.

## 대기 중

- **기도제목 나누기 — 1차에서 미룬 것** (2026-11-12, 브랜치 `feat/prayer-request-share`) —
  1차는 일기에서 기도제목을 제안·번역해 시스템 공유 시트로 넘기는 것까지다(아래 완료).
  남은 것:
  - 간증·독후감 카드, 이미지 카드, 데드라인 추출.
  - 고른 기도제목을 기도노트 체크리스트에 저장.
  - iCloud 공유 노트북이나 그룹 서버에 올리기(`docs/roadmap.md`).
  - 저장 뒤 자동으로 제안하는 배너.
  - 영어 프롬프트를 21개 일기로 평가(지금은 한국어 위주로 확인했다).
  - 한→영 번역이 문장 앞의 사람 명사를 호칭(부르는 말)으로 잘못 읽는 문제.

- **관리 콘솔 Mac mini 배포** (2026-11-06, 브랜치 `feat/admin-console`) — 사용자 작업.
  Mac mini에서 `docker compose -f web/admin/docker-compose.yml up -d --build`, Cloudflare
  Zero Trust에 public hostname `pilgrim.delight-house.org` 등록, 첫 로그인 후 비밀번호 변경.
  절차는 `docs/development.md` "관리 콘솔". 로컬 Docker 실행과 브라우저 확인까지는 끝났다.

- **가족 공유 노트북 (진행 중, 2026-11-03 착수)** — 노트북이나 노트 하나를 iCloud
  `CKShare`로 가족과 공유하고, 사이드바 "공유됨" 섹션에서 함께 본다(무료, 사진 포함).
  SwiftData는 CloudKit 공유를 못 하므로, 공유는 private 기록장과 따로 공유 단위마다
  `pilgrim-share-<uuid>` zone + zone 전체 share를 두고 `CKSyncEngine`으로 동기화한다.
  - 끝남: 줄 단위 3-way merge(`ThreeWayTextMerge`), 엔트리 병합(`SharedEntryMerge` —
    같은 줄 충돌은 나중 편집이 이기고 진 쪽은 이력용으로 반환), 공유 단위 타입
    (`SharedSpaceRecord`, `SharedKindSnapshot`), `JournalSharing` 타깃의 레코드 매핑
    (내용은 `encryptedValues`, Day One 원본 정보는 공유하지 않음)·`SharedSyncEngineHost`·
    `SharedSpaceService`(공유 생성·수락·중지·나가기), 공유 단위별 SwiftData 캐시
    (`SwiftDataSharedEntryCacheProvider`)와 동기화 상태·병합을 맡는 `SharedSpaceStore`,
    실제 화면(노트북·기록의 "공유…" 메뉴, 사이드바 "공유됨", 공유 노트북 열기·편집·
    새 노트, 공유 끝내기·나가기·내 기록장에 복사, 열려 있는 편집기와 원격 변경 병합,
    iOS 초대 수락 `CKSharingSupported`), 계정 삭제 시 받은 공유 나가기와 공유한 zone
    삭제(2026-11-07, `docs/privacy.md` "계정 삭제"). 단위·시뮬레이터 테스트만 통과, 실제
    CloudKit 동작은 미검증.
  - 다음: 실기기 2대 확인(`docs/development.md` "공유 노트북 실기기 확인"), 상대 편집
    위치 표시, 사진, 공유 노트 휴지통, macOS 초대 수락, 참여자 이름 표시("엄마가 수정"),
    검색·백업 경계, `docs/privacy.md`("shared DB 사용 안 함") 수정.
  - 상대 편집 위치는 CloudKit으로만 표시한다(2~10초 지연, 문단 단위, 2026-11-05 결정).
    Apple 메모 같은 실시간 커서는 Apple 전용 동기화라 다른 앱이 쓸 수 없고, SharePlay
    실시간 커서와 자체 실시간 서버는 하지 않기로 했다.
  - 새 record type(`SharedEntry`, `SharedRevision`)은 Production 배포가 필요하다
    (`docs/known-issues.md` "CloudKit 스키마 드리프트").

- **계정 삭제 후 다른 기기를 위한 삭제 표시 record** (2026-10-16, 1.1.0 (29)에서 미룸)
  계정 삭제(`AccountDeletionService`)는 이 기기와 iCloud만 지운다. 같은 계정으로 쓰던
  다른 기기에 로컬 사본이 남아 있으면 그 기기에서 앱을 열 때 Core Data mirroring이
  zone을 다시 만들고 전부 다시 올린다. 지금은 확인 화면에서 "다른 기기에서 먼저 앱을
  삭제하세요"라고 경고만 한다. 개선안:
  - 삭제 시 기본 zone에 `PilgrimJournalAccountDeletion` 같은 record(삭제 시각과
    Apple 사용자 해시만)를 남기고, 앱 시작·`CKAccountChanged` 시 store를 열기 전에
    확인해 해당 사용자의 로컬 범위를 지우고 로그아웃한다.
  - 새로 로그인한 사용자가 binding을 만들 때 그 record를 지워야 하므로, binding
    검사(`CloudIdentityBindingService`)와 순서를 맞춰야 한다.
  - 새 record type이라 Development 스키마 생성과 Production 배포가 필요하다
    (`docs/known-issues.md` "CloudKit 스키마 드리프트").

- **영문 현지화 남은 것** — 영어 번역(2026-10-15)과 다듬기 이후:
  - 한 단어를 여러 곳에서 써서 영어가 달라야 하는 곳은 `editor.heading`처럼 영어
    키에 한국어 `defaultValue`를 주는 방식으로 나눈다(`String(localized:
    defaultValue:comment:)`). 숫자가 둘 이상인 문장은 "Label: %lld" 형태로 쓴다.
  - 기록 유형을 바꿀 때 본문에 덧붙는 줄(`EntryDetails.carryOverLines`)과
    가져오기 감사 기록 일부는 저장되는 데이터라 한국어로 남겼다.
  - 실기기·Mac에서 전 화면 영어 확인은 아직. App Store 영문 스크린샷도 없다
    (영문 설명은 1.1.0에서 갱신).
  - 언어는 설정 › 언어(시스템 설정·한국어·English)에서 고른다. iOS·macOS 앱별 언어
    설정과 같은 `AppleLanguages`에 저장하므로 서로 맞춰지고, 앱을 다시 열어야
    적용된다(Mac은 "지금 다시 시작" 버튼). `String(localized:)`는 실행 중에
    언어를 바꿀 수 없어서 즉시 전환은 하지 않는다.

- **지난 백업 목록 화면**
  지금은 백업을 파일 하나(`.journalbackup`)로 내보내기만 하고, 앱은 그
  기록을 전혀 안 남긴다(`AppModel.lastBackupExportMessage`는 가장 최근 것
  하나만 잠깐 담는 휘발성 문자열, 영속 저장 없음 — `AppModel.prepareBackup()`). 복원할 때도 그냥 Finder 파일 선택 창만 뜬다.
  설정 → 백업 및 복원에 **최근 3개를 보여주고, "전체 보기" 버튼으로 나머지도
  볼 수 있는 목록 화면**을 추가한다. 구현하려면:
  - 내보내기 성공 시마다 메타데이터(파일명, 저장 시각, 항목 수, 저장 위치
    URL)를 기록하는 작은 로그가 필요하다 — CloudKit에 안 실리는 device-only
    저장소(`LocalAuxiliary` store, 검색 인덱스 상태와 같은 위치)에 두는 게
    맞아 보인다.
  - `.fileExporter`가 사용자가 고른 임의의 위치에 저장하므로, 그 URL이
    나중에 이동/삭제됐을 수 있다는 점을 감안해 "파일을 찾을 수 없음" 처리가
    필요하다.

- **macOS 첨부 칸 사진을 본문 커서 자리에 넣기** (사용자 판단으로 보류, 2026-10-15)
  macOS는 붙여넣은 이미지만 본문에 들어가고, 첨부 칸의 파일·사진 버튼은 목록에만
  올린다. 이동은 이미 된다 — 이미지 줄을 선택해 끌어 옮기기(`NSTextView` 기본 텍스트
  드래그)와 ▲▼(2026-10-15, 아래 완료 항목). 필요해지면 iPhone처럼
  `attachmentInsertionSelection` + `MarkdownImageInserter`를 macOS coordinator에
  연결하면 된다.
- **유형 편집 시트의 작은 UX 빈틈**
  - 시트의 오류 메시지가 목록 맨 위에 있어 스크롤하면 보이지 않는다.
  - macOS에는 눈에 보이는 삭제 버튼이 없다(컨텍스트 메뉴·Delete 키만).
  - "이름 없는 유형"을 삭제하면 그 자리표시 이름이 삭제 기록에 남는다(편집은
    이름 칸을 비운 채 열도록 고쳤다). 삭제된 유형이라 화면에는 영향이 없다.
- **사용자 유형 동기화의 남은 한계 (최종 리뷰에서 미룸)**
  - 다른 기기가 삭제한 유형을 오프라인 기기가 편집(이름·순서 변경)하면, 그
    편집이 더 늦은 시각이라 삭제를 이기고 유형이 되살아난다. 기록은 이미
    옮겨졌으므로 빈 유형이 하나 생길 뿐 데이터 손실은 없다.
  - 두 기기가 동시에 서로 다른 유형을 삭제하면 병합 결과에 새로 쓸 수 있는
    유형(`creatableKinds`)이 하나도 남지 않을 수 있다.
  - 이 빌드는 디코딩할 수 없는 iCloud 카탈로그를 만나면 다음 편집 때 로컬
    카탈로그로 덮어쓴다. 그 값이 더 새 빌드가 쓴 것이라면 그 빌드의 편집이
    사라진다.
  - 유형을 한 번이라도 삭제하면 이후 CloudKit 가져오기가 끝날 때마다 정리
    작업이 저장소 전체를 훑는다. 기록이 많아지면 비용을 재야 한다.
  - Day One 가져오기 뒤에는 정리 작업을 돌리지 않는다. 가져온 기록이 삭제된
    유형으로 분류되면(예: 아직 정리되지 않은 다른 기기의 규칙) 다음 정리 시점까지
    그 유형에 남는다.

- **편집기 구조 개편 (편집 세션·증분 스타일링)** — 2026-09-26 계획
  ([`archive/editor-refactoring-plan.md`](archive/editor-refactoring-plan.md))의
  1단계(재현 기준·데이터 보존, 인라인 구분자 즉시 스타일링)만 끝났다. 남은 것:
  - 2단계 편집 상태 분리: `EditorSession`(문서 ID·초안·revision·저장 상태)과
    `EditorTransaction`(변경 범위·치환 문자열·선택·명령 출처). 본문 해시 이력
    (`publishedHistory`) 대신 문서 ID와 변경 버전/출처로 echo와 외부 변경을 가른다.
    조합 중에는 텍스트 저장소·선택을 재작성하지 않는다.
  - 3단계 변경 범위 중심 스타일링: 바뀐 문단만 갱신, 코드 펜스처럼 여러 줄에
    걸치면 안정되는 블록까지 넓힌다. 전체 문서 스타일링은 초기 로드·전체 교체로
    제한하고, 비동기 결과는 revision이 같을 때만 반영.
  - 4단계 저장·검색을 입력 경로에서 분리: 양 플랫폼 자동저장을 공통 저장 조정자로,
    revision별 직렬화(오래된 저장 완료가 최신을 saved로 바꾸지 못하게), 검색 인덱스
    실패를 저장 성공과 구분해 재시도, 저장마다 전체 재조회 대신 변경 레코드 반영.
  - 각 단계마다 [에디터 입력 릴리스 게이트](known-issues.md#에디터-입력-릴리스-게이트)를
    다시 돌린다. 5단계의 파일 분할은 아래 항목으로 따로 한다.

- **앱 레이어 분할의 남은 것** — 2026-11-09 분할(아래 완료)에서 일부러 뺀 것:
  - `PilgrimJournalApp` App 구조체 본문(디버그 환경 변수 처리, macOS 메뉴 명령)은
    그대로다. 나누려면 App 멤버를 extension으로 옮기며 `private`을 풀어야 한다.
  - macOS·iOS 편집기의 중복 헬퍼(`parseTags`/`mergingTag`/`optionalBinding`,
    `scheduleAutosave`/`performAutosave`)는 합치지 않았다. 저장 실패 처리가 두
    플랫폼에서 다르다(iOS는 실패를 돌려주고 macOS는 무시) — 합치려면 먼저 정책을 정한다.
  - `AppModel.autosaveOnEditorExit`는 앱 코드에서 부르는 곳이 없고 테스트만 쓴다.

## 완료

- **기도제목 나누기 (1차)** (2026-11-12, 브랜치 `feat/prayer-request-share`) — 기록의
  `기도제목 나누기`(iOS 상세 동작, macOS 편집기 `기록 정보` 메뉴·도구 막대, 목록 행 메뉴;
  휴지통·빈 본문 제외)에서 시트를 연다. Apple Intelligence 기기(iOS·macOS 26)는 기도제목을
  1~3개 제안하고 나머지는 직접 쓰기로 열린다. 새 라이브러리 `JournalShareDrafts`(언어
  감지, 프롬프트 `2026-11-11.1`, 파이프라인)를 앱과 `ShareCardEval` 실험실이 함께 쓴다.
  `나눌 언어`는 시스템 번역, `나누기`는 시스템 공유 시트(텍스트만), `복사`. 아무것도
  저장·동기화·업로드·로그하지 않는다. 시뮬레이터 확인만 끝났고 실기기는 출시 전 확인
  리스트에 있다.

- **앱 레이어 파일 분할 (동작 변경 없음)** (2026-11-09, 브랜치
  `refactor/split-app-layer`) — 큰 파일을 파일 하나당 커밋 하나로 글자 그대로 옮겼다.
  `MarkdownSupport.swift` → `Markdown/` 10개(편집기 입력 경로는 macOS·iOS 블록째),
  `EntryViews.swift` → `Entry/` 5개, `AppModel.swift` → 코어 + `AppModel+<영역>.swift`
  9개, ContentView·PrayerTopicViews·SettingsAndImportViews·PilgrimJournalApp의 최상위
  타입, 큰 테스트 두 파일(같은 suite 이름의 extension). 다른 파일에서 쓰게 된 선언만
  `private`을 뗐다(AppModel은 25개, `@Published` 9개는 `private(set)` 해제). 테스트 480개
  전후 동일.

- **기도노트 기도제목 체크리스트 + 응답/기도중 모아보기 + 섹션·템플릿** (2026-11-06) —
  기도제목을 `EntryDetails.prayerTopics`(`detailsData` JSON 블롭 안의 배열)로
  저장해 CloudKit 스키마 변경 없이 동기화·리비전·백업·유형 이동(평탄화)을
  그대로 탄다. 노트 단위 `prayerStatus`/`answeredAt` 피커는 UI에서 제거하고
  (저장된 레거시 값은 보존, `validated(for:)`의 `.ongoing` 기본값 주입도 제거)
  기도제목 단위 상태로 일원화. 기도노트 유형 선택 시 콘텐츠 열 상단에
  노트/기도중/응답 세그먼트가 생기고, 기도중·응답 탭은 전체 기도노트를
  페이징으로 읽어 `PrayerTopicAggregator`로 집계(응답은 응답일 기준 월별,
  없으면 `updatedAt` 폴백), 목록에서 바로 체크해 토글할 수 있다(열린 편집기와의
  경합은 유형 이동과 같은 `flushOpenEditor` + `editorReloadRequest` 패턴).
  확장: ① 노트 안 자유 **섹션**(감사/가족 이름/중보…, 빈 섹션 허용 —
  `EntryDetails.prayerCategories` + `PrayerTopic.category`), ② **응답 세분화**
  Yes/No/Wait(`answerOutcome`, 기본 Yes, Wait도 응답 탭) + 응답 메모(`answerNote`),
  ③ **이름 붙인 템플릿**(`PrayerTemplateCatalog`/`PrayerTemplateStore`,
  유형 카탈로그와 같은 UserDefaults+iCloud KV 저장·tombstone LWW 병합, 계정
  삭제가 지우는 KV 키 목록에 포함) — 에디터의 템플릿 메뉴에서 시작·저장·삭제.
  검색 인덱스 `details` 컬럼에 제목·메모·섹션명·응답 메모 포함. 로드맵의
  기도제목 공유 카드를 위해 `PrayerTopic`에 기한(`deadline`) 필드를 나중에
  추가할 수 있게 optional 디코딩 호환을 테스트로 고정해 둠(구현은 안 함).
  실기기 확인(타이핑 게이트 재실행 포함)은 `docs/pre-release-checklist.md`.

- **유형 편집 무료화** (2026-11-05) — #13의 유료 코드 잠금(`PremiumCodeFeatureAccess`,
  잠금 안내 시트, 설정 › 유료 기능, Debug 잠금 시뮬레이션)과 `FeatureAccess`를 뺐다.
  유형 편집은 모든 사용자에게 열린다. 지금은 모든 기능이 무료이고, 나중에 유료로
  할 후보는 그룹 공유뿐이다(`docs/roadmap.md`). 잠금이 들어간 빌드는 출시된 적이
  없다(1.1.0 (29)는 #13 이전 커밋). 그때 코드를 넣은 기기에 남는 `premium-unlocked`
  `UserDefaults` 값은 이제 아무도 읽지 않는다.

- **설정에서 수동 iCloud 동기화** (2026-10-28) — 설정 › 동기화 › `지금 동기화`.
  iCloud 범위가 열려 있고 로컬→iCloud 이전 대기 중이 아닐 때만 보인다. 저장소를
  다시 열어 CloudKit mirroring을 처음부터 다시 돌리는 방식이라 화면이 잠깐 다시
  그려진다(편집기는 설정이 열려 있는 동안 떠 있지 않으므로 입력이 사라지지 않는다).
  실기기 확인은 `docs/pre-release-checklist.md`.
- **유형 이동 뒤 편집기 재로드의 경계 사례 3건 (최종 리뷰에서 미룸)** —
  (1) macOS에서 새 기록의 autosave가 refresh → 정리 작업 → 편집기 flush로
  재진입해 같은 기록을 두 번 저장하던 것: 저장 중에는 flush를 건너뛴다
  (`AppModel.isSavingEntry`). (2) 한글 조합 중에 도착한 재로드가 조합이 끝날 때
  덮이던 것: 편집기가 조합이 끝날 때까지 미뤘다가 조합 글자를 얹어 적용한다
  (`ExternalTextRebase`, `docs/known-issues.md` 참고). (3) iOS 전체 화면
  편집기에 재로드가 없던 것: macOS 인라인 편집기처럼 flush와 재로드를 받는다.
  실기기 확인은 `docs/pre-release-checklist.md`. (2026-10-15)

- **macOS 본문 이미지 ▲▼ 이동** (2026-10-15) — iPhone과 같은 버튼과 규칙
  (`movingAttachmentImage`, `moveButtonRects`). 커서가 이미지 줄에 있으면 우측 상단에
  ▲▼가 그려지고, 클릭은 `mouseDown`이 `super`보다 먼저 받는다(그래야 커서가 이미지
  밖으로 나가 버튼이 사라지지 않는다). iPhone과 달리 `NSTextView`는 글자와 장식을 한
  뷰에서 그리고 글자가 바뀌면 스스로 다시 그려서, 별도 `needsDisplay`는 필요 없었다
  (`MacImageMoveTests`).
- **화면 모드 설정** (2026-10-15) — 설정 › 화면에서 시스템 설정·라이트·다크를
  고른다. 기기별(`@AppStorage`, 동기화 안 함)이고, SwiftUI `preferredColorScheme`
  대신 창 단위로 적용한다(iOS `overrideUserInterfaceStyle`, macOS
  `NSApp.appearance`) — 그래야 "시스템 설정"으로 돌아올 때 확실히 풀리고
  AppKit/UIKit 편집기 색도 따라간다. iOS 시뮬레이터에서 즉시 전환·재실행 유지·
  시스템 추종 확인. Mac 화면 확인과 실기기 확인은 아직.
- **iPhone 본문 사진 위치 지정과 ▲▼ 이동** (2026-10-15) — 사진·촬영·파일(이미지)
  버튼, 키보드 도구줄 📷, 꾹 눌러 뜨는 메뉴의 사진 삽입으로 넣은 사진이 첨부
  목록뿐 아니라 본문의 마지막 커서 자리(커서가 없었으면 끝)에 한 줄로 들어간다.
  커서가 이미지 줄에 있으면 우측 상단 ▲▼로 위·아래 문단과 자리를 바꾼다.
  도구줄 칸이 6개로 꽉 차 있어 "키보드 닫기"를 빼고 📷을 넣었다(본문을 아래로
  쓸어내리면 키보드가 닫힌다). 집중 모드에서도 첨부 칸은 목록만 숨긴 채 남아
  사진 선택 화면을 띄운다. `docs/known-issues.md` 참고.
- **iPhone 편집기 집중 모드** — 키보드 도구막대의 버튼으로 켜고 끈다. 켜면
  상단 바·메타데이터 칩·유형별 칸·태그·첨부·글자 수·Markdown 메뉴 줄이 사라지고
  제목과 본문만 남는다. 키보드를 내린 상태에서는 오른쪽 위 작은 버튼으로
  나오고, 저장에 실패하면 그 옆에 저장 오류와 "다시 저장"이 뜬다. 편집기를 열
  때마다 평소 화면으로 시작한다(저장하지 않는 `@State`). 무엇을 보일지는
  `EntryEditorFocusLayout`이 정하고 `EntryEditorFocusLayoutTests`가 검증한다.
  Mac의 집중 모드(`FocusModeLayoutPolicy`)는 그대로다. 실기기 확인은
  `docs/pre-release-checklist.md`에 남아 있다. (2026-10-15)
  - 같이 고친 것: 키보드 도구막대가 **본문에서는 한 번도 뜬 적이 없었다.**
    SwiftUI `.toolbar(placement: .keyboard)`는 SwiftUI 입력칸에만 붙고 본문의
    UIKit 텍스트 뷰에는 붙지 않는다. 이제 같은 항목(`MarkdownKeyboardAccessory`)을
    본문 텍스트 뷰의 `UIToolbar`로도 보여 준다. 390pt 폭에서 넘치지 않도록
    "오늘" 버튼을 빼고(`/today` 명령으로 대신) "키보드 닫기"를 아이콘으로 바꿨다.

이전 완료 항목(2026-08)은 [`archive/pre-release-checklist-history.md`](archive/pre-release-checklist-history.md)의 "implementation-todo 완료 (이전)".
