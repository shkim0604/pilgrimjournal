# Quiet Morning 디자인 검증

## 등잔 아이콘 (2026-11-03)

- 시편 119:105("주의 말씀은 내 발에 등이요 내 길에 빛이니이다")를 담아 성경·불꽃
  아이콘을 등잔으로 바꿨다. 살짝 위에서 본 넓은 그릇에 어두운 기름 면이 보이고,
  그 위로 기존과 같은 모양의 불꽃이 피어오른다. 불꽃 속 구멍과 후광은 뺐다.
- 불꽃이 그릇만큼 크면 화로나 성화대처럼 읽혀서, 불꽃은 그릇 폭의 약 40%로 줄였다.
  받침대를 세운 안은 성화봉이나 잔처럼 보여서, 측면에서 본 기름 등잔은 지니 램프처럼
  보여서 뺐다. 전체 덩어리는 캔버스 중앙에 두고 그릇 폭은 약 61%다(2026-11-05에 52%에서 키움).
- 틴트 버전은 흰 불꽃이 흰 그릇 테두리와 붙지 않도록 불꽃 둘레에 배경색 외곽선을 둔다.
- `scripts/generate_app_icons.sh`로 13개 PNG를 다시 만들었고, 모두 불투명 RGB이며
  마스터와 기본 에셋이 일치한다. 기본·다크·틴트와 64px 축소본을 시각 검수했다.
  실제 홈 화면·Spotlight·Dock·Finder 검수는 새 설치 빌드에서 진행한다.

## Acceptance matrix

| 영역 | 개편 기준 | 구현 상태 |
| --- | --- | --- |
| Sidebar | 기록 유형과 사용자 노트북을 분리하고 선택·키보드 포커스를 명확히 표시 | semantic sidebar item 적용 |
| Timeline | raw Markdown 없이 제목, 두 줄 요약, 날짜·노트북, 절제된 상태 표시 제공 | summary formatter와 category indicator 적용 |
| Editor | metadata 한 줄, 720pt paper, 자동 저장 상태, 태그 chip, footer 제공 | macOS·iPhone 공통 hierarchy 적용 |
| Markdown | 즉시 서식을 유지하며 slash command와 선택 서식 도구 제공 | Day One escape, heading 1~6, 목록·체크리스트·인용·코드와 contextual action 적용 |
| 지원 화면 | 로그인, 잠금, onboarding, 설정과 빈 상태를 같은 palette로 통일 | Quiet Morning token 적용 |
| Appearance | Light·Dark와 Increase Contrast에서 정보 계층 유지 | adaptive token과 AccentColor appearance 제공 |

## Semantic color contrast

WCAG 상대 휘도 공식으로 측정했다. 일반 텍스트 AA 기준은 4.5:1이다.

| 조합 | Light | Dark |
| --- | ---: | ---: |
| 본문 / paper | 13.76:1 | 14.58:1 |
| 보조 텍스트 / paper | 4.84:1 | 8.08:1 |
| brandPrimary / paper | 7.06:1 | 7.42:1 |
| 본문 / selection | 11.87:1 | 8.88:1 |
| brandPrimary / selection | 6.10:1 | 4.52:1 |

## Visual regression matrix

아래 항목은 실제 기기와 TestFlight 후보 빌드에서 최종 screenshot을 남겨 비교한다.

- macOS Light·Dark: 넓은 창, 작은 창, 집중 모드
- iPhone Light·Dark: portrait, landscape, Dynamic Type 확대
- 긴 한국어·영어 혼합 본문, 긴 제목, 태그 다수, 빈 상태
- 앱 아이콘: 16px, 32px, 60px, 128px, 1024px, Dock, 홈 화면
- 접근성: VoiceOver 순서, keyboard-only, Increase Contrast, Reduce Motion

## 시각 테스트 진입점

DEBUG 시각 테스트 진입점은 `PILGRIM_VISUAL_TESTING=1`일 때만 인증을 우회하고
SwiftData를 메모리 저장소로 만든다. 파일 경로, 검색 색인, 앱 잠금 저장소와
Cloud identity 검사도 실제 사용자 데이터와 분리된다. SwiftPM의 debug 실행에도
`DEBUG`를 명시해 이 격리를 동일하게 적용한다. Release/TestFlight 빌드에서는
해당 우회가 컴파일되지 않는다.

## 긴 본문 레이아웃 확인 (2026-08-15 추가)

`PILGRIM_VISUAL_TEST_SCREEN=editor-long`은 화면보다 몇 배 긴 본문(60문단)을 가진
기록을 만들고 편집기를 연다. 짧은 fixture로는 **본문이 길어졌을 때만 드러나는
레이아웃 문제**를 볼 수 없다 — iPhone 편집기가 스크롤 뷰 안의 스크롤 뷰라
긴 기록의 뒷부분에 아예 닿을 수 없던 버그가 그렇게 숨어 있었다.

```sh
xcodebuild -project PilgrimJournal/PilgrimJournal.xcodeproj \
  -scheme PilgrimJournalApp -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/pilgrim-sim CODE_SIGNING_ALLOWED=NO build

xcrun simctl install booted /tmp/pilgrim-sim/Build/Products/Debug-iphonesimulator/PilgrimJournal.app
SIMCTL_CHILD_PILGRIM_VISUAL_TESTING=1 \
SIMCTL_CHILD_PILGRIM_VISUAL_TEST_SCREEN=editor-long \
  xcrun simctl launch booted com.dhouse.PilgrimJournal.debug
xcrun simctl io booted screenshot /tmp/editor-long.png
```

`simctl`은 터치·키 입력을 넣지 못하므로 **레이아웃까지만** 확인된다. 실제 스크롤
동작과 "긴 글 끝에서 타이핑할 때 커서가 따라오는지"는 실기기에서 봐야 한다.

## Scripted simulator matrix (2026-08-11)

`scripts/capture_ios_screens.sh`가 `PILGRIM_VISUAL_TESTING=1`로 앱을 띄우고
`xcrun simctl ui`로 appearance, `content_size`와 `increase_contrast`를 바꿔
가며 같은 화면을 연속 촬영한다. 조합은 Light·Dark, 기본·accessibility
extra-extra-extra-large, Increase Contrast 여섯 가지다.

- `launch` 모드는 실행 직후 화면을 촬영한다. `hold <이름>` 모드는 앱을 한 번만
  띄운 뒤 원하는 화면으로 직접 이동할 시간을 주고 Enter 이후 매트릭스를 찍는다.
  화면 전환에는 UI 자동화가 없으므로 sidebar 밖의 화면은 `hold`를 쓴다.
- 최대 Dynamic Type에서 sidebar navigation 제목이 `Pilgrim Jour…`로 잘리는
  것을 이 매트릭스로 발견했다. 접근성 글자 크기에서는 large title을 inline으로
  낮춰 제목 전체가 보이도록 고쳤다.
- 다섯 기록 유형, 미분류, 노트북과 설정 항목은 최대 글자 크기에서도 잘리지
  않고 스크롤된다. 재현 screenshot은 `home-*.png`로 저장했다.

## 지난 기록

교체된 성경·불꽃 아이콘, 2026-08 iPhone 시뮬레이터·Mac 직접 조작 증거, TestFlight
1.0 (2)/(3) 시점의 남은 확인과 빌드 검증(129 tests)은
`docs/archive/visual-design-validation-history.md`에 있다. 남은 수동 확인(VoiceOver,
keyboard-only, Reduce Motion, landscape, 기준선 screenshot)은
`docs/pre-release-checklist.md` 세션 E에서 관리한다.
