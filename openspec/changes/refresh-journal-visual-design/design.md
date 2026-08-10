## Context

현재 macOS 앱은 `NavigationSplitView`의 사이드바, 기록 목록과 인라인 편집기라는 적절한 정보 구조를 갖췄지만, AccentColor가 정의되지 않아 시스템 기본 파랑과 회색이 대부분의 선택 상태를 결정한다. 화면마다 `.secondary`, `.background`, 시스템 Form 스타일을 직접 사용해 기능은 구분되지만 개인 일기장다운 온도감과 공통 브랜드 계층이 약하다. 편집기에는 기록 유형, 날짜, 즐겨찾기, 고정, 이력과 저장 제어가 분산되어 있고 목록은 긴 원문을 그대로 노출해 글을 찾고 쓰는 핵심 흐름의 시각적 우선순위가 흐려진다.

현재 앱 아이콘은 짙은 청록 배경 위에 여러 겹의 책장, 중앙 별, 크림색 그라데이션과 그림자를 사용한다. 큰 원본에서는 의미가 보이지만 작은 홈 화면·Dock·설정 크기에서는 형태가 복잡하고 현대적인 앱 shell과도 연결되지 않는다.

개편은 기존 SwiftUI 멀티플랫폼 구조, 즉시 서식 Markdown 편집기, 저장 모델과 접근성 API를 유지해야 한다. 사용자의 긴 한국어·영어 혼합 기록이 주 콘텐츠이므로 장식보다 읽기 지속성, 명확한 focus와 시스템 동작을 우선한다.

## Goals / Non-Goals

**Goals:**

- 차분하지만 칙칙하지 않은 `Quiet Morning` 브랜드 인상을 Mac과 iPhone에 일관되게 제공한다.
- 색상, 글꼴, 간격, 모서리와 선택 상태를 semantic token으로 중앙화하고 Light/Dark appearance를 지원한다.
- 작은 크기에서도 식별되는 단순한 앱 아이콘과 tinted appearance 변형을 만든다.
- 탐색에서 기록 제목과 날짜를 빠르게 찾고, 편집에서는 본문에 오래 집중할 수 있게 한다.
- Markdown 문법을 직접 노출하지 않는 즉시 서식 경험을 유지하면서 서식 입력과 발견 가능성을 개선한다.
- Dynamic Type, VoiceOver, 키보드, Reduce Motion과 대비 기준을 기능 요구사항으로 검증한다.

**Non-Goals:**

- 도메인 모델, CloudKit schema, 검색 query, Day One parser 또는 백업 형식을 변경하지 않는다.
- Day One의 화면을 픽셀 단위로 복제하거나 Apple 플랫폼 관례를 벗어난 자체 navigation framework를 만들지 않는다.
- 사용자 정의 theme builder, 임의 글꼴 설치, 스킨 marketplace 또는 기록 유형별 전체 화면 색상 theme은 포함하지 않는다.
- 아이콘에 사진, 상세 삽화, 종교적 인물이나 작은 글자를 사용하지 않는다.

## Decisions

### 1. `Quiet Morning` semantic palette

구현 화면은 hex 값을 직접 사용하지 않고 `JournalTheme`의 semantic role을 사용한다. 브랜드색과 표면색을 분리해 accent를 바꾸더라도 본문 가독성이 흔들리지 않게 한다.

| Role | Light | Dark | Usage |
|---|---|---|---|
| `brandPrimary` | `#2F5D50` | `#7EBAA5` | 주요 버튼, focus, 선택 icon |
| `brandDeep` | `#173C36` | `#0E2420` | 앱 아이콘, 강한 브랜드 면 |
| `accentWarm` | `#D9A24A` | `#F0BD68` | 즐겨찾기, 작은 강조, 로고 책갈피 |
| `canvas` | `#F6F3EC` | `#111714` | 앱 바깥 배경 |
| `paper` | `#FBF8F1` | `#18211D` | 편집 캔버스 |
| `surfaceMuted` | `#EEF3ED` | `#151D1A` | 사이드바, 보조 영역 |
| `ink` | `#252A27` | `#F3F1EA` | 제목과 본문 |
| `inkSecondary` | `#66706A` | `#AEB8B1` | 날짜와 보조 정보 |
| `separator` | `#DCE3DD` | `#34413B` | 구획선 |
| `selection` | `#DDEBE5` | `#29483F` | 선택 행과 선택 chip |

기록 유형색은 `기도 #B88438`, `성경공부 #56745B`, `독서노트 #55758C`, `일기 #AF7064`, `미분류 #7C8580`으로 두되 아이콘, 2pt indicator와 작은 badge에만 사용한다. 큰 배경은 `canvas`, `paper`, `surfaceMuted`만 사용한다. 빨강·주황·초록은 오류·경고·성공이라는 시스템 의미를 유지하고 브랜드 장식에 재사용하지 않는다.

Apple semantic color를 직접 사용하는 대안은 구현이 단순하지만 현재의 무채색 인상을 해결하지 못한다. 모든 영역을 브랜드 초록으로 칠하는 대안은 긴 글의 피로와 대비 문제를 만들므로 배제한다.

### 2. 단순한 페이지·책갈피 앱 아이콘

새 아이콘은 `brandDeep` 단색 배경, `paper` 한 장으로 표현한 열린 페이지 실루엣, `accentWarm`의 작은 수직 책갈피라는 최대 세 색과 두 핵심 도형으로 제한한다. 별, 반복 책장, 내부 선, 텍스트, 사실적 그림자와 광택을 제거한다. 페이지의 중앙 접힘은 negative space 하나로만 표현한다.

1024px vector master를 source of truth로 두고 iOS 1024px와 macOS size set을 생성한다. iOS dark와 tinted appearance에서는 형태를 유지한 별도 색상 variant를 제공하고, macOS 아이콘은 시스템 mask 안에서 여백이 과도하게 커지지 않도록 optical size를 별도로 조정한다. 16px, 32px, 60px, 128px와 1024px에서 실루엣을 점검한다.

기존 아이콘을 선만 줄이는 대안은 여러 겹 책장과 별의 competing focal point가 남는다. 문자 `P` monogram은 단순하지만 일기장 의미가 약하므로 페이지·책갈피를 선택한다.

### 3. 디자인 token과 재사용 component

색상 외에도 4/8/12/16/24/32 간격 scale, 8/12/16 radius, editor measure와 typography role을 공유 token으로 둔다. SwiftUI component는 `JournalSidebarItem`, `EntryListRow`, `MetadataChip`, `StatusPill`, `PaperEditorSurface`, `EmptyState`처럼 의미 단위로 구성하고 플랫폼 차이는 style과 placement에서 처리한다.

본문은 시스템 글꼴을 사용한다. Mac 기본 본문 16pt, iPhone 17pt를 시작점으로 하되 Dynamic Type을 존중하며 line height는 약 1.55~1.65를 목표로 한다. 편집 본문 최대 폭은 Mac 720pt로 제한하고 긴 줄이 생기지 않게 중앙 정렬한다. 제목, 본문, 보조 정보의 세 단계만 강하게 구분해 과도한 크기 변화를 피한다.

화면마다 modifier를 직접 복제하는 대안은 빠르지만 Light/Dark와 접근성 변경이 분산되므로 중앙 token/component 계층을 선택한다.

### 4. 탐색 shell과 기록 목록

Mac의 세 열 구조는 유지하되 sidebar 220~260pt, timeline 300~360pt 범위와 editor flexible width를 권장한다. 사이드바 선택은 시스템 파란 면 대신 `selection` 배경, `brandPrimary` icon과 굵기 변화로 표시한다. 기록 유형과 사용자 노트북은 명확한 section으로 나누고 새 노트북 버튼은 낮은 강조의 trailing add action으로 둔다.

기록 목록은 `제목 또는 유형 fallback → 본문 2줄 → 날짜·노트북` 순으로 축약한다. raw Markdown marker가 미리보기의 첫 인상으로 보이지 않게 렌더링용 plain summary를 사용한다. 행 전체 선택, hover, keyboard focus와 context menu는 유지하며 pinned/starred는 작은 trailing symbol로 표시한다.

iPhone에서는 동일 정보를 NavigationStack에 맞춰 sidebar 목록 → timeline → editor로 전환한다. 색상과 component hierarchy는 공유하지만 Mac의 열 폭과 hover affordance를 그대로 이식하지 않는다.

### 5. 집중형 글쓰기 화면

Mac editor는 다음 순서로 구성한다.

1. 상단의 한 줄 metadata bar: 노트북, 기록 유형, 날짜, 즐겨찾기·고정, 이력, `저장 중/저장됨/오류` 상태
2. paper surface 안의 제목
3. 최대 720pt 폭의 즉시 서식 Markdown 본문
4. 태그 chip, 글자 수와 마지막 수정 시각을 담은 낮은 강조의 footer

저장 버튼은 정상 상태에서 제거하고 debounce autosave 상태를 표시한다. 오류일 때만 명시적인 재시도 action을 제공한다. 기존의 `/h1`, `/h2`, `/h3`, `/today`, `/line`, `* + space`는 유지하며 `/` 입력 시 검색 가능한 command palette를 띄운다. 텍스트 선택 중에는 bold, italic, heading, bullet, quote, link의 작은 contextual toolbar를 제공하되 선택이 없을 때는 본문을 가리지 않는다.

집중 모드는 sidebar와 timeline을 숨기고 paper surface만 표시하며 `⌘⇧F` 또는 명확한 toolbar action으로 켜고 끈다. window와 scene을 새로 만드는 방식보다 동일 editor state에서 navigation visibility만 바꿔 미저장 상태를 보존한다.

iPhone editor는 metadata를 상단의 compact chip과 sheet로 제공하고 자주 쓰는 bullet, heading, 오늘 날짜와 dismiss keyboard를 keyboard accessory에 둔다. 좁은 화면에서는 card 그림자나 큰 외부 margin을 없애 paper가 화면 전체가 되게 한다.

항상 보이는 다단 formatting toolbar는 본문 공간을 줄이고 Day One과 유사한 즉시 작성 감각을 해치므로 contextual 도구를 선택한다.

### 6. 움직임과 접근성

선택 변화와 focus mode에는 150~200ms 이하의 opacity/position transition만 사용하고 Reduce Motion에서는 animation을 제거한다. 색상만으로 선택·유형·오류를 전달하지 않고 icon, label 또는 shape를 함께 사용한다. 모든 token 조합은 일반 텍스트 4.5:1, 큰 텍스트·비텍스트 핵심 요소 3:1 대비를 목표로 실제 appearance에서 측정한다.

## Risks / Trade-offs

- [따뜻한 종이색이 일부 사용자에게 누렇게 느껴질 수 있음] → 채도를 낮추고 시스템 appearance를 따르며 순백 surface가 필요한 설정·sheet에는 `paper`가 아닌 기본 surface를 사용한다.
- [브랜드색과 기록 유형색이 많아 다시 복잡해질 수 있음] → 유형색 사용 영역을 icon·indicator·badge로 제한하고 배경 token을 공유한다.
- [contextual Markdown 도구가 발견되기 어려울 수 있음] → 첫 사용 hint, `/` command palette와 keyboard shortcut help를 함께 제공한다.
- [자동 저장 상태가 빠르게 깜빡일 수 있음] → 최소 표시 시간과 debounce를 적용하고 정상 `저장됨` 상태는 낮은 대비로 안정화한다.
- [macOS와 iOS를 동일하게 보이게 하려다 플랫폼 사용성이 떨어질 수 있음] → token과 정보 계층만 공유하고 navigation, toolbar와 keyboard interaction은 플랫폼 native pattern을 유지한다.
- [앱 아이콘 변경으로 기존 사용자가 앱을 순간적으로 찾기 어려울 수 있음] → 기존의 짙은 청록 계열을 `brandDeep`으로 이어가고 페이지 motif를 유지한다.

## Migration Plan

1. semantic token과 component preview를 추가하되 기존 화면에는 아직 적용하지 않는다.
2. 새 아이콘을 모든 필수 크기와 appearance로 생성하고 asset validation을 통과시킨다.
3. sidebar와 timeline부터 token/component로 전환한 뒤 editor를 별도 단계로 전환한다.
4. macOS와 iPhone에서 Light/Dark, Dynamic Type, VoiceOver, keyboard와 긴 본문 snapshot을 검증한다.
5. TestFlight 내부 build에서 기존 버전과 새 디자인의 데이터 보존, 편집과 autosave smoke test를 수행한다.

회귀가 있으면 데이터 계층은 건드리지 않은 채 화면별로 기존 SwiftUI view 스타일로 되돌릴 수 있다. AppIcon은 이전 asset set을 release tag에서 복구할 수 있게 원본을 git history에 유지한다.

## Open Questions

- 초기 구현 후 paper 색온도와 category accent는 실제 Mac·iPhone 디스플레이에서 한 차례 optical adjustment한다.
- focus mode가 첫 배포에서 Mac 전용이어야 하는지 iPhone landscape까지 포함할지는 prototype 사용성 검증에서 결정한다.
