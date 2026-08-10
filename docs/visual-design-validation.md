# Quiet Morning 디자인 검증

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

## iPhone simulator evidence (2026-08-09)

`iPhone 17 / iOS 26.5`의 격리된 DEBUG 메모리 저장소에 한국어·영어
혼합 fixture를 넣어 실제 compact navigation을 점검했다.

- 유형·노트북 선택 뒤 timeline을 먼저 표시하고, row를 눌렀을 때만 detail로
  이동한다. Mac의 최신 기록 자동 선택은 유지한다.
- Light timeline과 detail, Dark detail, Increase Contrast, accessibility
  extra-extra-extra-large sidebar/detail screenshot을
  `docs/visual-regression/ios/`에 저장했다.
- 최대 Dynamic Type에서 sidebar symbol을 고정 optical size로 유지하고,
  detail의 유형 badge와 편집·이력 action은 폭이 부족하면 두 줄로 재배치한다.
- 긴 혼합 언어 제목과 본문은 timeline에서 제한된 줄 수로 요약되고 detail에서
  줄바꿈·스크롤되며, 상단 action과 겹치지 않는다.
- 검색 결과 없음 화면은 Light·Dark와 accessibility extra-extra-extra-large에서
  제목, 설명과 `검색 조건 지우기` action이 서로 겹치지 않는다. 재현 screenshot은
  `search-empty-light.png`와 `search-empty-dark.png`로 저장했다.

DEBUG 시각 테스트 진입점은 `PILGRIM_VISUAL_TESTING=1`일 때만 인증을 우회하고
SwiftData를 메모리 저장소로 만든다. 파일 경로, 검색 색인, 앱 잠금 저장소와
Cloud identity 검사도 실제 사용자 데이터와 분리된다. SwiftPM의 debug 실행에도
`DEBUG`를 명시해 이 격리를 동일하게 적용한다. Release/TestFlight 빌드에서는
해당 우회가 컴파일되지 않는다.

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

## macOS direct interaction evidence (2026-08-10)

잠금 해제된 실제 Mac에서 설치 앱의 Day One 가져오기 기록은 읽기만 하고,
고유 검색어를 입력했다가 `검색 조건 지우기`로 원상 복구했다. 표준 창과 작은 창의
Dark appearance에서 제목, 설명, 지우기 action이 서로 겹치지 않았다.

편집 동작은 실제 저장소와 분리된 DEBUG fixture 앱에서 직접 점검했다.

- `/` palette에 제목 1~6, 글머리·번호·체크리스트, 인용, 코드, 오늘 날짜와
  구분선이 나타나고, `제목 1` 선택 시 slash query가 `# `로 교체되며 닫힌다.
- 선택 서식 도구가 나타나며 굵게 적용, Command-Z와 Command-Shift-Z 복원이
  정상 동작한다. 같은 서식을 다시 적용해도 marker가 중첩되지 않는다.
- Day One의 `\.` escape는 저장 문자열을 보존하면서 화면에서는 backslash만
  숨긴다.
- 집중 모드는 sidebar와 timeline을 접어 editor만 표시하고, 종료하면 세 열을
  그대로 복원한다.

## Markdown interaction regression

- slash command 선택 후 query가 제거되어 palette가 dismiss되는 단위 테스트를
  추가했다.
- bold, italic, link, heading, bullet, quote 적용 뒤 selection range가 유지되는
  회귀 테스트를 추가했다.
- AppKit/UIKit text view의 외부 서식 변경을 native undo manager에 등록해
  undo·redo 시 본문과 selection을 함께 복원한다.
- 전체 Swift test: 129 tests passed. macOS app target과 iOS Simulator app
  target build가 모두 통과했다.

## Remaining manual release checks

- 실제 Mac의 Light appearance와 keyboard-only/VoiceOver 순서
- 실제 iPhone의 landscape, VoiceOver, Reduce Motion, touch undo·redo
- Instruments typing/scroll hitch 기록 (화면 잠금 상태에서 simulator trace가
  시작 후 종료되지 않아 유효한 trace를 만들지 못함)
- TestFlight 1.0 (2)의 실기기 설치·업데이트, 기존 기록 보존과 appearance 전환
- 최신 수정이 포함된 iOS 1.0 (3) Release archive는 성공했다. Mac 잠금 후
  Xcode Keychain 계정을 읽지 못해 upload export가 `Failed to Use Accounts`로
  중단됐으므로 잠금 해제 뒤 export/upload를 재실행한다.

## Build and launch verification

- `swift test`: 129 tests passed
- `PilgrimJournalApp` iOS Simulator app target: build passed, Asset Catalog linked
- `PilgrimJournalApp` macOS app target: Apple Development signed build passed
- Signed macOS build: CloudKit, Sign in with Apple, app sandbox entitlements verified and launch passed

An unsigned macOS validation bundle (`CODE_SIGNING_ALLOWED=NO`) crashed while
Core Data initialized CloudKit. The crash report had an empty Team ID and no
CloudKit entitlement. This is a validation-bundle configuration failure, not a
crash reproduced by the signed application build; CloudKit runtime smoke tests
must use a provisioned build.
