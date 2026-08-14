# 출시 전 확인 리스트

실기기 검증(`docs/device-verification.md`)과 알려진 문제(`docs/known-issues.md`)를
바탕으로 한 최상위 상태 추적 문서. 절차 상세는 각 문서를 참고하고, 여기서는
"끝났는지/미뤘는지/안 했는지"만 관리한다.

## 미룬 항목 (재개 필요)

- [ ] **본문 이미지 붙여넣기 — 실기기 검증** (openspec
      `improve-attachment-transfer-and-paste`, 2026-08-12). macOS/iOS
      `paste(_:)` 인터셉트가 실제 클립보드 이미지(스크린샷, 다른 앱에서 복사한
      사진)로 동작하는지, `docs/known-issues.md`의 편집기 입력 릴리스
      게이트(빠른 한글·영어 혼합 타이핑)와 함께 걸어도 씹힘이 재발하지 않는지
      iPhone 실기기 소프트 키보드로 확인 필요. 다운로드 타임아웃(잠정 25초)도
      실제 CloudKit import 지연 관찰 후 값 조정 필요.
- [ ] **대량 Day One import 성능** — task 2.5, 10.8 (세션 D-1)
      수천 건 합성 기록을 넣고 CloudKit queue 지연, 메모리, 검색 응답성, 인덱스
      rebuild 소요를 측정. 2026-08-12에 나중으로 미룸.
- [ ] **iCloud 계정 전환·격리** — task 12.2 (세션 B-2)
      계정 A → 로그아웃 → 계정 B → 다시 계정 A. 계정별 기록·검색 인덱스가
      섞이면 개인정보 사고급 불합격. **두 번째 iCloud 계정 필요.**
      2026-08-12에 나중으로 미룸.
- [ ] **백업·복원 수렴 재시도** — task 11.10 (세션 C-2)
      지금 갖고 있는 build 15로 시도하니 "백업에서 복원…" 버튼을 눌러도 파일
      선택 창이 안 떴음. 원인은 이미 커밋 `7ecc452`
      ("fix(macos): let settings give way to the editor and confirm data
      operations", build 16에 포함)에서 고쳐졌지만, **build 16이 아직
      TestFlight에 안 올라가서 검증 불가.** build 16(또는 이후) 업로드되면
      재시도.
- [ ] **세션 E 나머지** — E-1(VoiceOver), E-2 나머지(키보드만으로 조작,
      Reduce Motion, landscape, 긴 본문), E-4(Light/Dark 기준선 screenshot).
      2026-08-12에 나중으로 미룸.
- [ ] **세션 F** — TestFlight 설치·업데이트 후 기록 보존 smoke test.
      2026-08-12에 나중으로 미룸.
- [ ] **세션 C-4 — 휴지통 영구 삭제 수렴** (신규, openspec
      `add-trash-permanent-delete`). canonical 타입(기록·첨부)에 대해 처음으로
      실제 CKRecord 삭제를 발생시키는 경로라 별도 2대 기기 검증이 필요함.
      2026-08-12에 코드는 완료, 실기기 검증은 미룸.
- [ ] **불릿 목록 버그 5건 + 체크리스트 렌더링 — iPhone 실기기 검증**
      (2026-08-12, `docs/known-issues.md` 참고). macOS는 격리된 디버그
      인스턴스 GUI로 전부(불릿 5건 + 체크리스트) 확인함. iOS는 이번에도
      실기기·시뮬레이터로 확인하지 못했다.
- [ ] **인라인 리사이즈 가능한 이미지 — 실기기 검증** (2026-08-12,
      `docs/known-issues.md` "인라인 리사이즈 가능한 이미지" 참고). 붙여넣기
      → 라이브 편집기 내 즉시 렌더링 → 핸들 드래그 리사이즈(macOS 마우스,
      iOS 팬 제스처) → 창 크기/회전 시 재계산까지 코드는 완료, 자동화 테스트
      (`swift test`, iOS 시뮬레이터 빌드, `scripts/check.sh`)는 전부 통과했지만
      실기기 GUI로는 아직 확인 안 함. **편집기 입력 릴리스 게이트를 이미지가
      포함된 문서에서 반드시 재통과시켜야 함** — `draw(_:)`에 이미지 합성이
      추가되어 매 키 입력마다 도는 경로의 비용이 늘었고, 이는 기존 씹힘
      회귀와 같은 코드 경로다.
- [ ] **첨부 성능 근본 수정 — 실기기 실측** (2026-08-14,
      `docs/known-issues.md` "첨부 있는 기록이 계속 느렸던 진짜 원인" 참고).
      `allAttachments()`가 view body에서 DB 전체 첨부 blob을 폴트시키던
      것(첨부 있는 기록이 유독 느렸던 주 원인)을 범위 좁힌 조회로 교체,
      다운샘플 이미지 캐시 추가, 편집기 재렌더 낭비 여러 건 제거. 자동화
      테스트·양 플랫폼 컴파일은 전부 통과했지만 **실기기에서 체감 개선을
      실측하지 않았다.** 첨부 20장 이상인 기록을 열어보고, 30초 이상 빠르게
      타이핑해 이미지가 있는 문서에서도 편집기 입력 릴리스 게이트가
      통과하는지 확인 필요 — `draw(_:)` 렌더 경로를 직접 건드린 변경이라
      다른 이미지 관련 항목들과 같은 급의 필수 게이트다. Stage 3(자동 저장
      `refresh()` 경량화)는 위험도가 높아 실측 없이 보류함 — 위 두 항목
      확인 후에도 여전히 느리면 그때 재검토.
- [ ] **태그 입력창 한글 조합 깨짐 — 실기기 검증** (2026-08-14,
      `docs/known-issues.md` "태그 입력창에서 한글 조합이 깨짐" 참고).
      가로 스크롤뷰 안 태그 `TextField`의 폭을 타이핑 중 고정시키는 수정을
      했지만, **근본 원인이 확정되지 않았다** — IME 조합은 자동화 테스트로
      재현 불가. 태그 필드에 한글을 빠르게 입력해 자모가 정상 조합되는지
      확인 필요. 안 고쳐졌다면 다른 원인(예: `.onChange(of: tagsText)` →
      `scheduleAutosave()` 경로 자체)을 봐야 함.
- [ ] **태그 커밋/입력창 분리 — 실기기 확인** (2026-08-14, build 20).
      태그를 확정(쉼표/Return)하면 칩만 남고 입력창에 원본 텍스트가 같이
      남아있던 버그 수정. 자동화 테스트는 통과했지만 실제 타이핑 흐름으로
      확인 안 함. 위 IME 항목과 같은 필드라 함께 확인 가능.
- [ ] **macOS 집중 모드 → 새 노트 크래시 — 실기기 재확인** (2026-08-14, build
      20). `MacNavigationSplitFocus.setCollapsed`가 SwiftUI가 detail 컬럼을
      교체하는 도중(새 기록 생성 시) 이미 창에서 떨어져 나간 뷰를 만지다
      크래시하던 것으로 추정, 모든 뷰/컨트롤러 변경 전에 `window === keyWindow`
      확인을 추가함. 집중 모드 전환 후 새 노트를 반복 생성해 재현 안 되는지
      확인 필요.

## 완료

- [x] 세션 S — build 15 smoke test (다중 선택, 앱 이름, iOS 목록 조작, 백업 피드백, 편집기 입력)
- [x] 세션 A (A-1~A-4) — CloudKit 동기화 spike. SwiftData **go** 결정.
      대량 배치 성능(위 미룬 항목)만 이 결정에서 제외.
- [x] 세션 B-1 — Sign in with Apple (재실행·오프라인 세션·철회·재설치 보존)
- [x] 세션 C-1 — Day One 가져오기 수렴 (태그·첨부·날짜·시간대 확인).
      `scripts/make_anonymous_dayone_export.swift`로 만든 합성 export로 검증.
- [x] 세션 C-3 — 데이터 무결성 검사. canonical 참조·revision·첨부·검색 토큰
      문제 없음. (백업·복원 구간은 C-2와 동일하게 build 16 대기 중이라 건너뜀)
- [x] 세션 D-2 — 입력 반응성. iPhone 실기기 소프트 키보드로 한글·영어 섞어
      빠르게 입력, 씹힘 재현 안 됨. **매 빌드 전 반복 필요** — 일회성 완료가
      아니라 `docs/known-issues.md`의 릴리스 게이트 체크리스트로 관리.
- [x] 세션 E-3 — 아이콘 실기기 검수 (Dock/Finder, 홈 화면/Spotlight 크기별). 통과.
- [x] 불릿 목록 버그 5건 — macOS GUI 검증. 격리된 디버그 인스턴스
      (`PILGRIM_VISUAL_TESTING=1`)를 띄우고 System Events로 실제 키 입력을
      보내 스크린샷으로 하나씩 확인. 상세는 `docs/known-issues.md`의
      "2026-08-12 — 불릿 목록 버그 수정" 참고.

## 아직 시작 안 한 세션

- [ ] 세션 D-1 — 대량 배치 성능 (위 "미룬 항목" 참고)

## 이번 세션(2026-08-12)에서 발견해 코드로 고친 것

- 편집기가 열려 있는 상태에서 "수정 이력 → 이 버전으로 복원"을 눌러도
  편집 화면(draft)이 갱신 안 되던 버그 수정 (사이드바는 반영되는데 편집기만
  그대로였음) — `Sources/PilgrimJournal/EntryViews.swift`
- 첨부 미리보기(QuickLook/기본 앱 열기)와 다른 위치에 저장(fileExporter) 기능
  신규 추가 — 다운로드는 됐는데 열어볼 방법이 아예 없었던 공백을 메움
- macOS에서 창을 너무 좁게 줄이면 편집기 상단 툴바(유형·노트북 chip, 기록
  정보 메뉴, 저장 상태 아이콘)가 서로 겹쳐 보이던 버그 수정 (E-2에서 발견).
  detail 컬럼에 `JournalTheme.detailMinWidth`(420pt) 최소 폭을 걸어서, 겹칠
  수 있는 폭까지 창이 좁아지지 않도록 막음 — `Sources/PilgrimJournal/ContentView.swift`,
  `Sources/PilgrimJournal/DesignSystem.swift`
- 휴지통 완전 비우기/영구 삭제 기능 신규 추가 — 기록·수정 이력·첨부 행을
  지우고 참조되지 않는 첨부 파일을 회수함. Day One 재가져오기가 휴지통
  항목 때문에 영구 차단되던 버그도 함께 해소함. openspec
  `add-trash-permanent-delete` — 실기기 수렴 검증은 세션 C-4로 미룸
- 불릿 목록 버그 5건 수정, macOS GUI로 실측 검증: 빈 불릿에서 Backspace 한
  번으로 마커 삭제, macOS에 Tab/Shift+Tab 들여쓰기 추가(기존엔 iOS에만
  있었음), 불릿 점 세로 중앙 정렬(줄 간격 포함 rect가 아니라 글리프 자체의
  bounding rect 기준으로 변경), 불릿 점 뒤 여백 추가, macOS 편집기의 매 키
  입력마다 전체 문서를 동기적으로 재스타일링하던 걸 iOS처럼 디바운스
  방식으로 바꾸고 `scrollRangeToVisible`을 매 변경마다 호출하도록 고쳐 빠른
  Enter 연타 후에도 마지막 줄이 항상 보이게 함 —
  `Sources/PilgrimJournal/MarkdownSupport.swift`. iOS는 미검증, 위
  "불릿 목록 버그 5건 + 체크리스트 렌더링 — iPhone 실기기 검증" 항목 참고.
- `SwiftDataJournalRepository.entry(sourceUUID:)`가 `fetchLimit = 500`을 건
  채 정렬 없이 조회하던 버그 수정. 가져온 기록이 500개를 넘으면 500번째
  이후 기록은 재가져오기 중복 판정·`save()`의 중복 방지 가드·기기 간 병합
  매칭에서 전부 누락될 수 있었음(대량 Day One 가져오기 사용자에게 실제
  중복 기록이 생길 수 있는 정확성 버그). 휴지통 영구 삭제 작업 중 발견,
  fetchLimit을 제거하고 520개 기록으로 재현하는 회귀 테스트 추가함 —
  `Sources/JournalData/SwiftDataJournalRepository.swift`
- 체크리스트가 실제로는 한 번도 제대로 렌더링된 적이 없던 버그 발견·수정
  (사용자가 실사용 중 지적). `- [ ] 할 일`을 입력해도 체크박스 대신 평범한
  색의 `-` 글자만 보였다 — `NSTextAttachment`를 문자를 치환하지 않고
  attribute로만 얹었는데, AppKit/UIKit은 실제로 U+FFFC로 치환된 자리가
  아니면 `.attachment`를 무시하기 때문. 불릿 점과 같은 방식(커스텀 드로잉)
  으로 체크박스를 직접 그리도록 바꾸고, 완료 항목에 취소선을 추가함 —
  `Sources/PilgrimJournal/MarkdownSupport.swift`. macOS GUI로 체크됨/안 됨
  둘 다 확인함, iOS 미검증.

## 참고만 해둘 관찰 (출시 게이트는 아님)

(2026-08-12에 openspec `improve-attachment-transfer-and-paste`로 해소 — 첨부
업로드 진행률 세분화, 다운로드 타임아웃/재시도, 본문 이미지 붙여넣기. 아래
"미룬 항목"의 실기기 검증 게이트만 남음.)
