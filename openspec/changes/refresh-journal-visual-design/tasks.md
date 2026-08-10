## 1. 디자인 기반과 기준선

- [ ] 1.1 현재 macOS·iPhone의 sidebar, timeline, editor, 인증·잠금·설정 화면을 Light·Dark 기준 screenshot으로 남기고 개편 acceptance matrix를 작성한다
- [x] 1.2 `JournalTheme`에 Light·Dark semantic color, typography, spacing, radius와 editor width token을 구현한다
- [x] 1.3 Asset Catalog의 AccentColor에 `brandPrimary` 기반 Light·Dark·고대비 appearance를 추가한다
- [x] 1.4 `MetadataChip`, `StatusPill`, `PaperEditorSurface`, `EmptyState`와 공통 focus style을 구현하고 두 appearance preview를 만든다
- [x] 1.5 semantic token 조합의 본문·보조 텍스트·focus·선택 상태 대비를 측정하고 기준 미달 조합을 조정한다

## 2. 심플 앱 아이콘

- [x] 2.1 에버그린 배경, 단일 열린 페이지와 골드 책갈피로 구성된 1024px vector master를 만들고 반복 책장·별·그라데이션·문자를 제거한다
- [x] 2.2 vector master에서 iOS 1024px와 macOS 16~1024px icon set, iOS dark·tinted appearance variant를 생성한다
- [x] 2.3 Asset Catalog에 새 icon을 연결하고 alpha, 크기, filename과 appearance slot을 검증한다
- [ ] 2.4 16px·32px·60px·128px·1024px, macOS Dock과 iPhone 홈 화면에서 silhouette·negative space·optical size를 시각 검수한다

## 3. 탐색 shell과 기록 목록

- [x] 3.1 macOS NavigationSplitView에 canvas·surface token, sidebar·timeline 권장 폭과 작은 창 collapse 동작을 적용한다
- [x] 3.2 기록 유형·사용자 노트북 section, 선택·hover·keyboard focus와 추가 action을 공통 sidebar item style로 재구성한다
- [x] 3.3 raw Markdown marker를 제거하고 제목 fallback, 본문 두 줄, 날짜·노트북을 만드는 기록 목록 summary formatter를 구현하고 테스트한다
- [x] 3.4 pinned·starred와 기록 유형 indicator를 절제된 trailing symbol과 badge로 적용한 기록 목록 row를 구현한다
- [x] 3.5 검색 결과, 빈 상태, 휴지통, 설정, onboarding, 로그인과 앱 잠금 화면을 동일 token과 component 계층으로 정리한다
- [x] 3.6 iPhone의 유형·노트북 → timeline → detail navigation에 공통 hierarchy를 적용하고 Dynamic Type에서 compact layout을 검증한다
- [x] 3.7 macOS 검색 결과 없음 화면의 제목·설명·초기화 action을 단일 adaptive empty-state layout으로 구성해 작은 창에서 겹치지 않게 한다

## 4. 집중형 글쓰기 화면

- [x] 4.1 Mac 편집기를 한 줄 metadata bar, 제목, 최대 720pt paper 본문과 footer 구조로 재배치한다
- [x] 4.2 노트북·유형·날짜·즐겨찾기·고정·이력 control을 compact metadata component로 만들고 좁은 폭에서 overflow layout을 제공한다
- [x] 4.3 편집 변경의 debounce autosave와 `저장 중/저장됨/오류` 상태 model을 구현하고 오류 재시도 중 입력을 보존한다
- [x] 4.4 일반 태그를 추가·삭제 가능한 chip으로 바꾸고 footer에 글자 수와 마지막 수정 시각을 낮은 강조로 표시한다
- [x] 4.5 Mac sidebar·timeline을 숨기고 cursor, selection과 미저장 입력을 유지하는 집중 모드와 keyboard shortcut을 구현한다
- [x] 4.6 iPhone 편집기에 화면 폭 paper layout, compact metadata sheet와 heading·bullet·오늘 날짜·키보드 닫기 accessory를 구현한다

## 5. Markdown 입력 도구

- [x] 5.1 기존 즉시 서식의 heading·강조·bullet·구분선 marker 숨김과 가져온 Markdown 무손실 편집을 회귀 테스트한다
- [x] 5.2 `/` 입력 시 heading 1~3, 오늘 날짜, 구분선, bullet을 검색·키보드 선택할 수 있는 command palette를 구현한다
- [x] 5.3 텍스트 선택 시 bold, italic, heading, bullet, quote와 link 중 지원 action을 제공하는 contextual toolbar를 구현한다
- [ ] 5.4 Mac keyboard와 iPhone touch에서 command palette dismiss, 서식 적용, undo·redo와 selection 유지 동작을 테스트한다
- [x] 5.5 Day One의 escaped punctuation marker를 원문 변경 없이 즉시 서식 편집기와 목록 요약에서 숨기고 회귀 테스트한다
- [x] 5.6 제목 1~6, 번호 목록, 체크리스트, 인용, 코드, 취소선과 하이라이트를 slash command·선택 서식·미리보기에 확장한다

## 6. 접근성·회귀와 출시 검증

- [x] 6.1 semantic token, 목록 summary, autosave 상태와 metadata responsive layout의 단위 테스트를 추가한다
- [ ] 6.2 VoiceOver label·순서, keyboard-only navigation, Dynamic Type, Increase Contrast와 Reduce Motion을 macOS·iPhone에서 점검한다
- [ ] 6.3 Light·Dark, 작은 Mac 창, iPhone portrait·landscape와 긴 한국어·영어 혼합 본문의 visual regression screenshot을 비교한다
- [ ] 6.4 긴 기록의 typing, scroll, live Markdown과 autosave가 UI hitch 없이 동작하는지 Instruments 및 수동 smoke test로 확인한다
- [x] 6.5 Swift test 전체와 macOS·iOS simulator build를 실행하고 저장·CloudKit·Day One 가져오기 데이터 계약이 변하지 않았음을 회귀 검증한다
- [ ] 6.6 새 아이콘과 디자인을 포함한 TestFlight 내부 build를 설치·업데이트하고 기존 기록 보존, Mac·iPhone 편집과 appearance 전환을 smoke test한다
