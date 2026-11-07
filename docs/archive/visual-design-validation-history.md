> 아카이브됨(2026-11-06).

# Quiet Morning 디자인 검증 — 지난 기록

`docs/visual-design-validation.md`에서 옮겼다. 내용은 작성 당시 그대로다.

## 성경·불꽃 아이콘 (2026-10-15, 등잔 아이콘으로 교체됨)

- 기존 초록·아이보리·금색 팔레트로 펼친 성경 위에 불꽃을 배치했다.
  불꽃 중심은 최초 시안보다 24px 아래로 옮기고 금색에서 주황색으로 이어지는
  그라데이션으로 강조했다. 이후 각 중심을 유지하며 불꽃은 12% 확대하고
  책은 8% 축소했다. 불꽃 뒤에는 가장자리로 갈수록 투명해지는 은은한 금빛
  후광을 추가했다. 틴트 버전은 같은 위치·크기의 흰색 실루엣과 무채색 후광을 사용한다.
  기본·다크·틴트 SVG가 원본이며 `scripts/generate_app_icons.sh`가 앱 에셋과
  `Design/PilgrimJournal-AppIcon-master.png`를 함께 갱신한다.
- 13개 PNG의 크기와 불투명 RGB 형식, 마스터와 기본 에셋 일치를 확인했다.
  기본·다크·틴트 및 16px·32px 축소본을 시각 검수했다.
- `actool`로 iOS 17.0 및 macOS 14.0 대상 Asset Catalog 컴파일 통과.
  실제 홈 화면·Spotlight·Dock·Finder 검수는 새 설치 빌드에서 진행한다.

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
