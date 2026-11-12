> 아카이브됨(2026-11-06). pre-release-checklist.md에서 내린 완료 항목·세션 기록이다.

# 출시 전 확인 리스트 — 지난 기록

살아 있는 목록은 [`pre-release-checklist.md`](../pre-release-checklist.md). 아래는
2026-11-06 정리 때 그 문서·`device-verification.md`·`implementation-todo.md`에서
옮긴 원문이다(경로·번들 ID 오타만 고침).

## 미룬 항목에서 내린 것 (2026-11-06)

### 완료 처리된 항목

- [x] **Mac 편집기 창 줄이면 줄바꿈 안 됨 — 수정** (2026-10-15, 브랜치
      `fix/mac-editor-wrap`). 글자 크기 배율 때문에 보이는 폭과 텍스트 뷰 폭이
      어긋나 줄 끝이 잘렸다. 서명 없는 테스트 빌드에서 창 축소·글자 크기
      확대 후 정상 줄바꿈 확인. Mac 제목도 줄바꿈되게 바꿈. 중복 "보기"
      메뉴 하나로 합침.
- [x] **macOS 본문 이미지 ▲▼ 이동 — 확인** (2026-10-15). 사용자가 테스트 모드
      Mac Debug 빌드에서 ▲▼가 잘 된다고 확인했다. 확인 항목: 이미지 줄에 커서를 두면
      우측 상단에 ▲▼가 뜨고 클릭하면 위·아래 내용 있는 줄과 자리가 바뀌는지, 실행취소
      (⌘Z), 크기 조절 핸들·텍스트 선택·이미지 줄 드래그 이동과 충돌하지 않는지,
      이동 직후 한글·영어 타이핑이 씹히지 않는지. 같은 날 사용자가 테스트 모드 Mac
      Debug 빌드에서 붙여넣기·드래그 이동·크기 조절이 된다고 확인했다(▲▼ 이전).
- [x] **iPhone 본문 사진 위치 지정·▲▼ 이동 — 실기기 검증** (2026-10-15,
      `docs/known-issues.md` "사진을 본문 커서 자리에 넣고 ▲▼로 옮긴다" 참고).
      시뮬레이터 hosted 테스트(`BodyImagePlacementIOSTests`)와 테스트 모드
      시뮬레이터로는 확인함(키보드 도구줄 📷은 하드웨어 키보드 때문에 못 봄).
      **2026-10-15 실기기(iPhone 15 Pro, iOS 26.6, Debug, 테스트 모드)를 iPhone
      미러링으로 확인함:** 보조 클릭 메뉴 맨 위 **사진 삽입** → 하위 메뉴(사진
      보관함/촬영) → 사진 보관함에서 2장 → 커서 자리에 순서대로 삽입, ▲로 위 사진과
      자리 바뀌고 그림 즉시 갱신, 이동 직후 Mac 키보드로 `abc` 입력 → 이미지 위
      새 줄에 세 글자 모두 남음.
      사용자가 실기기에서 **키보드 도구줄 📷이 안 뜬다**고 보고 → 원인은 SwiftUI
      `.keyboard` 도구줄이 본문(UIKit 텍스트 뷰)에 안 붙는 것. 집중 모드 브랜치 위로
      옮겨 📷을 본문의 `inputAccessoryView` 목록에 넣었다(키보드 닫기 자리, 아래 "본문
      키보드 도구막대" 항목). **2026-10-15 사용자가 실기기(소프트 키보드)에서
      확인: 본문 키보드 도구줄에 📷이 뜨고, 사진이 커서 자리에 들어간다. 집중
      모드에서도 📷으로 사진 선택 화면이 뜬다.**
      남아 있던 손가락 길게 누르기 메뉴, 촬영, 첨부 칸 버튼, ▲▼와 텍스트
      선택·리사이즈 핸들 충돌, 실행취소, 소프트 키보드 한글·영어 빠른 입력도
      사용자가 실기기에서 "다 잘 된다"고 보고(2026-10-15, Debug 빌드). **TestFlight
      Release 빌드에서는 편집기 입력 릴리스 게이트를 다시 통과시킬 것** — 매 빌드
      반복 항목이다.

### 1.1.0 (28) — 29로 대체됨

- [ ] **1.1.0 (28) — 심사 반려됨(2026-10-16, 5.1.1(v)·1.5), 29로 대체** (2026-10-15). iOS·macOS 둘 다
      업로드 후 심사 제출(Xcode 계정 인증, API 키 없이 `-allowProvisioningUpdates`).
      새 아이콘·홈 화면 이름 "Pilgrim" 포함. 아카이브는 `.release/build28/`.
      1.0.1 (25) 이후 CloudKit 스키마 변경 없음. 수동 출시로 설정했으니 승인 후
      "이 버전 출시"를 누르기 전에 TestFlight 28로 확인할 것:
      - 편집기 입력 게이트(`docs/known-issues.md`): 실제 iPhone 소프트 키보드,
        30초 이상 한글·영어 혼합 고속 타이핑. 1.0.1 이후 사진 위치·집중 모드·본문
        탭 영역·키보드 도구막대·Mac 줄바꿈이 편집기를 바꿨다.
      - 1.0.1 위에 업데이트 설치 후 기록 보존(세션 F).
      - 기기를 여러 대 쓰면 모두 1.1.0으로 올린 뒤 유형 편집 — 1.0.1은 직접 만든
        유형의 기록 저장을 거부한다.
      - 영어로 둔 기기에서 화면 한 바퀴(현지화는 시뮬레이터에서만 확인).

### 줄이기 전 원문

체크리스트에는 열린 부분만 남겼다. "시뮬레이터 입력 순서 섞임"은 같은 원인이라
"첫 입력 지워짐" 항목에 합쳤다.

- [ ] **1.1.0 (29) — App Review 반려 대응: 계정 삭제·지원 페이지** (2026-10-16,
      브랜치 `fix/account-deletion`). 1.1.0 (28)이 2026-10-16 두 가지로 반려됐다.
      - **5.1.1(v)**: Sign in with Apple로 계정을 만드는데 앱 안에 계정 삭제가
        없었다. → 설정 › Apple 로그인 › `계정 삭제` 추가(`AccountDeletionService`,
        범위와 순서는 `docs/privacy.md` "계정 삭제"). 서버가 없어 Apple 토큰
        revoke 대신 "설정 › Apple 계정 › Apple로 로그인 › Pilgrim › 사용 중단"을
        안내한다.
      - **1.5**: Support URL(`…chatgpt.site/support`)이 동작하는 지원 페이지가
        아니었다. → `site/index.html`(한·영 정적 페이지)을 만들어 공개 저장소
        `shkim0604/pilgrim-support`의 GitHub Pages로 배포했다(2026-10-16):
        https://shkim0604.github.io/pilgrim-support/ — 앱의
        `SupportLinks.supportPage`에 반영. 페이지를 고치면 `site/index.html`을 그
        저장소에 복사해 푸시한다. **App Store Connect Support URL 교체는 아직.**
      - 자동 테스트(`AccountDeletionServiceTests`, coordinator·session 테스트)와
        `scripts/check.sh`, 서명 없는 iOS/macOS 빌드는 통과. 빌드 번호 29.
      - 남은 일: 실기기 세션 **B-3**(`docs/device-verification.md`, 녹화 포함) →
        녹화와 함께 답장(`docs/archive/app-review/2026-10-1.1.0.md` 초안) → 29 업로드·재제출.
      - **macOS 29 업로드 완료** (2026-10-20, `55fcca4`에서 Release 아카이브,
        Xcode 계정 인증 + `-allowProvisioningUpdates`). 아카이브는
        `.release/build29/`(macOS만). 처리 완료(VALID).
      - **2026-10-21 App Store Connect:** iOS 1.1.0 (29)는 Ready for Sale,
        Support URL(ko·en)도 새 주소. macOS 1.1.0은 build 28 + 옛 Support URL
        (`…chatgpt.site/support`)로 10-15 제출분이 아직 In Review였다(반려 메시지는
        없었음). 심사에서 빼고 build 29 + 새 Support URL(ko·en)로 바꿔 재제출 →
        **Waiting for Review**. Mac 쪽엔 반려 스레드가 없어 녹화 첨부는 하지 않았다.
      - 계정 바인딩 삭제 경로를 새로 만들었으므로 완료 목록의 **B-2**(계정 전환·
        격리)와 **C-4**(CloudKit record 삭제 수렴)를 이 빌드로 다시 돌린다.
      - CloudKit 스키마 변경 없음(삭제만 함) — 스키마 배포 불필요.
      - 아래 1.1.0 (28) 출시 전 게이트(편집기 입력 등)는 29에서 그대로 유효하다.

- [ ] **iPhone 편집기 첫 입력 지워짐 — 실기기 확인** (2026-10-15, 브랜치
      `claude/funny-cerf-e80f16`, `docs/known-issues.md` "iPhone 편집기를 연 직후
      첫 입력이 지워짐"). 시뮬레이터에서 보인 캐럿 튐·글자 유실은 시뮬레이터
      키 주입 탓이 아니었다 — 앱 안에서 `insertText`만으로도 편집기를 연 직후
      첫 입력이 지워졌다(새 기록은 첫 묶음 전체). 여는 시점 본문을
      `publishedHistory`에 넣어 고쳤고, iOS XCTest 2건이 수정 전 실패/수정 후
      통과, 시뮬레이터 재현 절차로도 글자 순서가 보존됨을 확인했다.
      `scripts/check.sh`, 서명 없는 iOS/macOS 빌드 통과. **다음 TestFlight
      빌드에 이 수정이 들어가야 한다.** 실기기에서는 릴리스 게이트의 새 항목
      (편집기를 막 열고 영어 한 글자 → 1초 대기, 기존 기록·새 기록 각각)을
      확인할 것. build 21 게이트에서 안 보였던 이유는 미확인.
      - 2026-10-15 iPhone 15 Pro(iOS 26.6) 실기기 확인 — **iPhone 미러링 + 하드웨어
        키보드**로, 별도 테스트 앱(`com.dhouse.PilgrimJournal.debug`, 샘플 데이터)에서:
        - ✅ 새 기록 첫 입력 묶음 전체 보존("Yes first burst ok"), 기존 기록에서
          몇 글자 → 1초 쉼 반복해도 순서·누락 없음.
        - ✅ 한글 조합이 쉼을 사이에 두고도 정상("안녕하세요 반갑습니다.", "할 일").
        - ✅ `**굵게**` 닫는 순간 굵게 표시, 체크리스트 박스 그려짐·탭 토글·
          Return 시 다음 항목 이어짐, 긴 본문 끝에서 캐럿이 화면을 따라옴,
          완료 후 저장·읽기 화면 반영, 한국어 날짜.
        - 못 함(미러링 한계): **소프트 키보드**(릴리스 게이트 본 항목), `#`·`/`·백틱
          (Shift·슬래시가 전달 안 됨 → 제목·슬래시 명령 미확인), 태그 입력, 이미지.
        - ⚠️ 새 발견: 빈 새 기록에서 본문 영역 위쪽을 탭하면 본문이 선택되지 않는다.
          한 줄짜리 본문 텍스트 뷰가 최소 높이 영역의 **세로 가운데**에 놓여, 그
          지점을 눌러야만 입력된다(기존 기록 본문 위의 큰 빈칸도 같은 원인으로 보임).
          → PR #4(`fix/ios-empty-body-tap`)에서 수정해 main에 머지. 실기기 재확인 필요.
        - ⚠️ 하드웨어 키보드에서 제목 입력 중 Return이 편집기를 닫는다(완료로 동작).
          소프트 키보드에서도 그런지 확인 필요.
- [ ] **iPhone 시뮬레이터에서 입력 순서가 섞임 — 실기기로 재현 여부 확인**
      (2026-10-15). 시뮬레이터(iPhone 17, iOS 26.2, 테스트 모드)에서 본문 끝을
      탭한 뒤 몇 글자씩 쉬어 가며 입력하면, 쉴 때마다 캐럿이 처음 탭한 자리로
      돌아가 다음 입력이 그 자리에 끼어들고 일부 글자가 사라진다. `/h2 `도
      펼쳐지지 않았고 하단 글자 수(162자)가 그대로였다. **Phase 0 이전 빌드
      (`0e567c3`)에서도 똑같이 재현**되므로 이번 리팩토링 때문은 아니다. build 21
      실기기 게이트는 통과했으므로 시뮬레이터 텍스트 주입 경로에서만 생기는
      현상일 수 있다. 실제 iPhone에서 같은 패턴(본문 끝 탭 → 몇 글자 입력 → 1초
      쉼 → 반복)으로 확인할 것. 재현되면 출시 차단.

- [ ] **백업·복원 수렴 재시도** — task 11.10 (세션 C-2)
      지금 갖고 있는 build 15로 시도하니 "백업에서 복원…" 버튼을 눌러도 파일
      선택 창이 안 떴음. 원인은 이미 커밋 `7ecc452`
      ("fix(macos): let settings give way to the editor and confirm data
      operations", build 16에 포함)에서 고쳐졌지만, **build 16이 아직
      TestFlight에 안 올라가서 검증 불가.** build 16(또는 이후) 업로드되면
      재시도. → **2026-08-15: build 21이 올라갔으므로 막힘이 풀렸다. 이제 바로
      재시도 가능.**

- [ ] **태그 입력창 한글 조합 깨짐 — 실기기 검증** (2026-08-14,
      `docs/known-issues.md` "태그 입력창에서 한글 조합이 깨짐" 참고).
      가로 스크롤뷰 안 태그 `TextField`의 폭을 타이핑 중 고정시키는 수정을
      했지만, **근본 원인이 확정되지 않았다** — IME 조합은 자동화 테스트로
      재현 불가. 태그 필드에 한글을 빠르게 입력해 자모가 정상 조합되는지
      확인 필요. 안 고쳐졌다면 다른 원인(예: `.onChange(of: tagsText)` →
      `scheduleAutosave()` 경로 자체)을 봐야 함.

- [ ] **제목 글자 크기 — build 23 확인** (2026-08-15, 커밋 `c60e9e4`). build 21
      에서는 `# `/`/h1 ` 마커는 즉시 숨겨지지만 입력한 제목 글자가 본문 크기로
      찍히고 Enter 후에야 커졌다. 입력 속성이 캐럿이 있는 줄의 블록 스타일을
      따라가게 고침. build 22에 올라갔으나 **1-6 확인 때 명시적으로 짚어보지
      않은 항목** — `/h1`~`/h6`과 `# `~`###### ` 양쪽에서 첫 글자부터 제목
      크기로 보이는지 확인.

## 완료

- [x] **build 21 편집기 수정 1~6 — iPhone 실기기 확인** (2026-08-15 사용자
      확인). 한글·영어 혼합 입력 씹힘 없음, 사진 붙여넣기 삽입, 이미지 뒤 한글
      입력 표시, 마커 즉시 서식, 리사이즈 드래그 스케일링, 이미지 줄 원자성
      전부 통과. 제목 글자 크기(build 22 이후 별도 수정)는 이 확인에 포함되지
      않아 아래 "미룬 항목"에 남아 있음.
- [x] **세션 B-2 — iCloud 계정 전환·격리** (2026-08-15 사용자 확인).
      계정 A → 로그아웃 → 계정 B → 다시 계정 A에서 기록·검색 인덱스가 섞이지
      않음. 개인정보 관점에서 가장 무거운 게이트였다. *구체적 절차·기기 구성은
      기록해두지 않았으므로, 동기화나 계정 바인딩
      (`CloudIdentityBinding`/`CloudAccountMonitor`)을 손대면 다시 돌릴 것.*
      **2026-10-16 계정 삭제가 binding 삭제를 추가해 재실행 필요** (위 1.1.0 (29)).
- [x] **세션 C-4 — 휴지통 영구 삭제 수렴** (2026-08-15 사용자 확인, openspec
      `add-trash-permanent-delete`). canonical 타입에 대해 실제 CKRecord 삭제를
      일으키는 첫 경로였고 2대 기기에서 수렴 확인. *삭제 경로나 tombstone
      처리를 바꾸면 다시 돌릴 것.* **2026-10-16 계정 삭제(zone 전체 삭제)가
      새 삭제 경로라 재실행 필요** (위 1.1.0 (29)).
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
- [x] macOS 집중 모드에서 툴바 패널 버튼을 누르면 집중 모드가 풀림 (2026-09-26).
      Debug 빌드를 직접 실행해 사용자가 수동 확인, 정상 동작. `swift build`
      통과, `swift test` 17개 통과 (집중 모드 자동 테스트는 없음).
- [x] Mac 집중 모드에서 제목과 본문만 표시 (2026-11-05). 격리된 Debug 앱에서
      전환 전후에 창 도구 막대가 사라졌다가 복원되고, 편집 중인 본문과 커서 위치가
      유지되는 것을 확인했다. ⌘⇧F로 일반 화면에 돌아온다.
- [x] Mac 집중 모드 종료 버튼 (2026-11-05). 도구 막대가 사라지므로 본문 오른쪽 위에
      원형 종료 버튼을 띄운다(⌘⇧F·Esc도 그대로). 격리된 Debug 앱에서 사용자가 눌러
      보고 잘 된다고 확인했다.

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

## OpenSpec 정리 (2026-10-10)

- 기존 완료 증거를 `build-personal-journal-app`의 동기화·인증·가져오기·계정
  격리 8개 항목과 `refresh-journal-visual-design`의 아이콘 검수에 반영했다.
- `add-trash-permanent-delete`는 31개 작업 완료 및 기존 2대 기기 수렴 확인을
  근거로 정식 스펙에 병합하고 `2026-10-10-add-trash-permanent-delete`로 archive했다.
- 전체 `scripts/check.sh` 통과(213개 테스트, JournalChecks, 개인정보 파일 검사).
  집중 모드 테스트에서 `.automatic`이 `.doubleColumn`과 다르다는 가정을 제거했다.
  현재 macOS SwiftUI에서는 두 값이 같으며, 명시적 `.all`·`.detailOnly`의
  복구와 집중 모드 종료 상태 검증은 유지한다. 앱 실행 코드는 변경하지 않았다.
- 실기기 검증을 새로 수행한 것은 아니다. 미확인 항목과 매 빌드 입력 회귀
  검증은 계속 미완료로 둔다. 빌드 25 출시만으로 완료 처리하지 않는다.

## device-verification 결과 기록 (2026-11-06에 내림)

절차 문서에서 뺀 build 15 당시 준비 메모와 세션별 결과 표시다.

### 준비물 (build 15 당시)

- TestFlight의 **build 15** (Mac·iPhone 양쪽). 아카이브는 `.release/build15/`
- CloudKit container: `iCloud.com.dhouse.PilgrimJournal` —
  **Production 스키마 배포 완료** (5개 레코드 타입). 절차는
  `docs/development.md`의 "CloudKit 운영 도구"

> **build 15부터는 데이터가 비어 있다.** Development·Production 양쪽의 미러링
> 존을 지웠다. 기기에 남은 로컬 사본이 있으면 앱을 여는 순간 존을 다시 만들고
> 전부 재업로드하므로, 깨끗한 조건에서 보려면 **양쪽 기기에서 앱을 삭제한 뒤
> 설치**한다.

`2.7`과 `12.7`(schema 승격)은 완료됐다.

### 세션 S — build 15 smoke test ✅ 대부분 통과

이번 빌드에서 고친 것들이다. **A로 넘어가기 전에 여기서 걸러야 한다** — 여기가
깨져 있으면 A의 결과를 신뢰할 수 없다.

#### S-1. 다중 선택 (macOS) ✅

1. 목록에서 노트 하나를 클릭한다.
2. shift-클릭으로 범위를 잡고, command-클릭으로 하나씩 더한다.
3. 도구 막대 휴지통을 누른다.
4. 검색어를 넣어 선택한 노트가 목록에서 사라지게 한다.

- ✅ 한 개 클릭 시 **강조되는 카드가 정확히 하나**다 (이게 원래 증상)
- ✅ '선택'을 누르지 않아도 shift-클릭으로 여러 개가 잡히고 휴지통이 동작한다
- ✅ 여러 개 선택 시 오른쪽에 "N개의 노트를 선택했습니다"가 뜬다
- ✅ 검색으로 가려진 노트는 선택에서 빠지고 휴지통이 비활성화된다

#### S-2. 앱 이름 ✅

- ✅ iPhone 홈 화면·Spotlight·설정 앱: `Pilgrim Journal`
- ✅ macOS **메뉴 막대 좌상단**과 Dock·Finder: `Pilgrim Journal`
  (메뉴 막대는 `CFBundleName`이라 build 14까지 붙여 쓰기였다)
- ✅ 응용 프로그램 폴더에 옛 `PilgrimJournal.app` 없음

#### S-3. iOS 목록 조작 ✅

1. 노트를 탭한다.
2. 마지막 노트를 스와이프로 삭제한다.

- ✅ 탭하면 상세로 가고 **설정으로 튀지 않는다**
- ✅ 마지막 노트를 스와이프 삭제해도 **크래시하지 않는다**

#### S-4. 백업 피드백 ❌ → ✅ build 16에서 고침

설정 → 백업 및 복원에서 내보내기와 복원을 각각 한 번씩 한다.

- ❌ build 15: 성공이 화면에 안 떴다 (내부적으로만 기록됐음)
- ✅ build 16: alert로 올렸다. "N개 반영 · M개 휴지통 · 충돌 K개" 등

#### S-4b. 설정에서 새 노트 만들기 ❌ → ✅ build 16에서 고침

설정이 떠 있을 때 `새 노트` 버튼을 누른다.

- ❌ build 15: 아무 일도 안 일어난다 (설정이 detail column 우선이라 편집기 뒤에서 열리고 안 보인다)
- ✅ build 16: 편집기로 바뀐다

#### S-5. 편집기 입력 ✅

**이 항목만 실패해도 다음 빌드를 올려야 한다.** 자동화 테스트가 잡지 못한다.
본문에 한글·영어를 섞어 30초 이상 빠르게 친다. 제목이 아니라 **본문**이다.

### 세션 A·F 결과

#### A-1. 왕복 동기화 — task 2.2 ✅ 통과

**절차:** Mac에서 기록을 만들고, iPhone을 백그라운드로 두고 2분 대기, 비행기 모드
+ 셀룰러 끔으로 네트워크 끊은 상태에서 iPhone 앱을 열기. Safari로 네트워크 끊김을
증명하고, 기록이 보이는지 확인.

- ✅ **합격:** 네트워크가 끊긴 상태로 기록이 보인다 → 백그라운드에서 silent push로
  이미 받아 저장했다는 증거. background 수렴 동작 확인.

**다음 단계 (A-2, A-3 진행 중):**
- 오프라인 동시 편집과 tombstone 수렴
- 첨부 asset 지연 다운로드

#### F-1. CloudKit production schema — tasks 2.7, 12.7 ✅ 완료

build 15에서 5개 레코드 타입을 전부 Production에 배포했다. 배포 창의 변경
목록이 곧 snapshot review였고 전부 additive였다(타입 3개 추가, 기존 타입에 필드
추가, 인덱스 추가, 필드 삭제·타입 변경 없음). 절차와 재발 방지는
`docs/known-issues.md`.

## implementation-todo 완료 (이전)

- **첨부 다운로드 fetch 미트리거 / 업로드 진행률 세분화 / 이미지 붙여넣기**
  — openspec `improve-attachment-transfer-and-paste`. CloudKit이 특정
  레코드의 asset을 강제로 fetch하게 만드는 공개 API는 없다는 제약을 그대로
  받아들이고, 다운로드 버튼은 타임아웃(잠정 25초) 후 재시도 UI로 바꿈 — CloudKit
  import가 실제로 진행 중이면(`AppModel.isCloudImportInProgress`) 타임아웃을
  미룸. `AttachmentTransferState`에 `.uploading`을 추가하고,
  `NSPersistentCloudKitContainer.eventChangedNotification`이 이미 보내지만
  버려지고 있던 "작업 시작" 신호(`completedAt == nil`)를 살려 "대기 중"과
  "전송 중"을 구분함(`AppModel.handleCloudSyncStoreEvent`). 클립보드 이미지
  붙여넣기는 "첨부 추가"와 같은 `AttachmentFileStore`/`AttachmentRepository`
  경로로 저장하고 본문에 `![](attachment:id)` 마크다운을 삽입함(macOS/iOS
  `paste(_:)` 오버라이드 → 기존에 안전하다고 검증된
  `Coordinator.replaceExternalText` 경로로 삽입) — 라이브 에디터에서는 원시
  텍스트로 보이고, 보기 모드(`MarkdownPreviewView`)에서 실제 이미지로
  렌더링됨. (2026-08-12)

- **라이브 에디터 내 인라인 리사이즈 가능한 이미지** — 위 항목에서 범위
  제외했던 것을 사용자 요청으로 이어서 구현함. 문자 치환 없이
  `LiveMarkdownStyler`의 "저장되는 마크다운 문자를 절대 바꾸지 않는다"
  불변조건을 지키면서, 이미지 마커 줄에 `NSParagraphStyle.minimumLineHeight`
  /`maximumLineHeight`로 높이를 예약하고(기존 `separatorParagraphStyle`
  패턴 재사용) `draw(_:)`가 그 자리에 디코드된 이미지를 직접 합성하는
  방식으로 해결함. 크기는 `![](attachment:id =WxH)`로 텍스트 자체에
  인코딩(별도 메타데이터 저장소 없음). 커서가 이미지 줄에 있을 때만 보이는
  리사이즈 핸들을 드래그하면 가로세로 비율 고정으로 크기가 바뀌고, 놓는
  순간 한 번만 `Coordinator.replaceExternalText`로 `=WxH`를 확정함(드래그
  중에는 attribute만 바꿔 `textDidChange` 재진입 위험 없음). macOS는
  `mouseDown`/`mouseDragged`/`mouseUp` 오버라이드, iOS는 `UITextView`의
  내장 제스처와 충돌하지 않도록 `UIPanGestureRecognizer` +
  `UIGestureRecognizerDelegate` 히트테스트로 구현. 이미지 데이터는
  `draw(_:)`에서 동기 호출하지 않고, 첨부 전체를 스캔하던 기존
  `allAttachments()` 대신 새로 추가한 단일 조회
  `AttachmentRepository.attachment(id:)`로 Coordinator가 캐시하며 비동기
  로드함. `dirtyRect` 교차 검사로 화면 밖 이미지는 합성하지 않아 편집기
  입력 씹힘 회귀와 같은 `draw(_:)` 경로의 비용 증가를 최소화함 —
  실기기 검증은 `docs/pre-release-checklist.md`로 미룸 (2026-08-12)

- **`entry(sourceUUID:)`의 fetchLimit 500이 대량 가져오기에서 중복 판정을
  놓칠 수 있던 버그** — `SwiftDataJournalRepository.entry(sourceUUID:)`가
  `fetchLimit = 500`을 건 채 정렬 없이 조회해, 가져온 기록이 500개를 넘으면
  500번째 이후 기록은 재가져오기 중복 판정(`DayOneImportExecutor`)·`save()`의
  중복 방지 가드·기기 간 병합 매칭(`JournalSessionController`)에서 전부
  누락될 수 있었다. `purgeEntries`에서 이미 쓰던 "정확성이 걸린 곳엔 임의
  cap을 두지 않는다" 관례를 따라 fetchLimit을 제거함. 휴지통 영구 삭제 작업
  (openspec `add-trash-permanent-delete`) 중 발견, 이번 세션에서 수정
  (2026-08-12)

- **첨부 미리보기(QuickLook/기본 앱 열기)** — iOS는 `.quickLookPreview`,
  macOS는 `NSWorkspace.shared.open`으로 구현함 (2026-08-12)
- **첨부를 다른 위치에 저장** — `AttachmentDocument` + `.fileExporter`로
  구현함 (2026-08-12)
- **편집기 열린 상태에서 수정 이력 복원 시 draft 갱신 안 되던 버그** —
  `RevisionHistoryView`에 `onRestore` 콜백 추가해 수정함 (2026-08-12)
- **휴지통 완전 비우기 기능이 없음** — 휴지통 화면에서 개별 영구 삭제와
  전체 비우기를 추가함. 기록·수정 이력·첨부 행을 함께 지우고, 다른 기록이
  더 이상 참조하지 않는 첨부 파일만 회수함(checksum 기반 dedupe라 공유
  파일은 보존). Day One 재가져오기 영구 차단 버그도 함께 해소 — 영구
  삭제된 기록은 같은 sourceUUID로 다시 가져올 수 있고, 휴지통에만 있는
  기록은 계속 중복으로 차단됨. 새 canonical 모델이나 속성을 추가하지
  않아 CloudKit 스키마 재배포가 필요 없음. openspec
  `add-trash-permanent-delete` (2026-08-12)
