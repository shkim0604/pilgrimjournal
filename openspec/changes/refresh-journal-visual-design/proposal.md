## Why

현재 앱은 시스템 기본 회색과 흰색에 크게 의존해 개인 일기장으로서의 따뜻함과 브랜드 인상이 부족하고, 복잡한 앱 아이콘은 작은 크기에서 핵심 형태를 빠르게 인식하기 어렵다. 또한 글쓰기 화면의 메타데이터와 도구가 분산되어 기록에 집중하기보다 조작 요소가 먼저 보이므로, Mac과 iPhone에 공통으로 적용할 시각 체계와 집중형 편집 경험이 필요하다.

## What Changes

- 에버그린, 따뜻한 종이색과 골드 포인트를 중심으로 한 `Quiet Morning` 시각 언어와 semantic color token을 정의한다.
- 시스템 Light/Dark appearance, 접근성 대비와 플랫폼별 재질을 유지하면서 사이드바, 기록 목록, 빈 상태, 설정과 인증 화면을 하나의 브랜드 체계로 정리한다.
- 기존의 별, 여러 겹 책장, 그라데이션과 그림자를 제거하고 한 장의 열린 페이지와 작은 책갈피로 구성한 단순한 앱 아이콘을 제공한다.
- 기록 유형의 색은 넓은 배경이 아니라 아이콘, 배지와 선택 상태에 제한해 본문 가독성을 우선한다.
- 글쓰기 화면을 종이형 편집 캔버스, 한 줄 메타데이터 바, 명확한 제목·본문 계층과 저장 상태 중심으로 재구성한다.
- Markdown 즉시 서식, `/` 명령, 텍스트 선택 도구, 태그 chip과 집중 모드를 Mac·iPhone interaction에 맞게 제공한다.
- Dynamic Type, VoiceOver, 키보드 탐색, 명암 대비, 긴 한국어·영어 혼합 본문과 작은 창을 시각 회귀 기준에 포함한다.

## Capabilities

### New Capabilities

- `journal-visual-design`: 브랜드 팔레트, semantic token, 단순한 앱 아이콘, 공통 shell과 기록 목록의 시각·접근성 계약
- `journal-writing-experience`: 집중형 글쓰기 레이아웃, 메타데이터·저장 상태, Markdown 도구와 플랫폼별 편집 interaction 계약

### Modified Capabilities

없음.

## Impact

- SwiftUI 공통 화면, macOS NavigationSplitView, iPhone navigation과 편집 화면의 레이아웃·스타일이 변경된다.
- Asset Catalog의 AccentColor와 macOS·iOS AppIcon 변형이 교체된다.
- semantic color, typography, spacing과 component style을 제공하는 공유 디자인 token 계층이 추가된다.
- 기존 도메인 모델, 저장 형식, CloudKit schema와 Day One 가져오기 데이터 계약은 변경하지 않는다.
