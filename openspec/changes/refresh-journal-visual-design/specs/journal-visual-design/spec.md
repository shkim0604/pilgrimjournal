## ADDED Requirements

### Requirement: Quiet Morning semantic theme
앱은 에버그린 브랜드색, 따뜻한 종이색, 골드 포인트와 가독성 중심의 semantic color role을 사용해 macOS와 iPhone의 공통 시각 체계를 제공해야 한다(MUST).

#### Scenario: Light appearance
- **WHEN** 사용자가 시스템을 Light appearance로 사용한다
- **THEN** 앱은 따뜻한 중립 canvas와 paper surface, 짙은 ink 본문과 에버그린 선택 상태를 일관되게 표시한다

#### Scenario: Dark appearance
- **WHEN** 사용자가 시스템을 Dark appearance로 전환한다
- **THEN** 앱은 의미와 계층을 유지하는 dark semantic token을 적용하고 밝은 paper 면이나 낮은 대비 본문을 남기지 않는다

#### Scenario: 상태 의미 보존
- **WHEN** 앱이 성공, 경고 또는 오류 상태를 표시한다
- **THEN** 시스템 상태색은 브랜드와 기록 유형 장식색과 구분되고 label 또는 icon을 함께 제공한다

### Requirement: 절제된 기록 유형 강조
앱은 기도노트, 성경공부, 독서노트, 일기와 미분류를 구분하는 색상을 넓은 배경이 아니라 icon, indicator 또는 badge에 제한해 사용해야 한다(MUST).

#### Scenario: 기록 유형 목록
- **WHEN** 사용자가 사이드바나 기록 목록에서 여러 기록 유형을 본다
- **THEN** 각 유형은 색상과 symbol 또는 label로 구분되며 본문과 주요 표면은 공통 중립 theme을 유지한다

#### Scenario: 색각 또는 고대비 환경
- **WHEN** 사용자가 색 차이를 인지하기 어렵거나 Increase Contrast를 사용한다
- **THEN** 기록 유형과 선택 상태는 색상 없이도 icon, text와 shape로 식별할 수 있다

### Requirement: 단순하고 확장 가능한 앱 아이콘
앱은 짙은 에버그린 배경, 한 장의 열린 페이지와 작은 골드 책갈피로 구성된 단순한 아이콘을 macOS와 iOS의 필수 크기 및 appearance에 제공해야 한다(MUST).

#### Scenario: 작은 아이콘 크기
- **WHEN** 아이콘이 16px, 32px 또는 iPhone 설정 목록 크기로 표시된다
- **THEN** 반복 책장, 별, 글자, 세부 선 없이 페이지와 책갈피 실루엣을 구분할 수 있다

#### Scenario: iOS tinted appearance
- **WHEN** 사용자가 iOS의 tinted app icon appearance를 사용한다
- **THEN** 아이콘은 단색 처리에서도 페이지의 silhouette과 negative space를 유지한다

#### Scenario: macOS Dock
- **WHEN** 아이콘이 macOS Dock과 앱 전환기에 표시된다
- **THEN** 시스템 mask와 주변 앱 대비 적절한 optical size와 여백을 유지한다

### Requirement: 일관된 탐색 shell
앱은 semantic token과 공통 component를 사용해 사이드바, 기록 목록, 빈 상태와 설정 화면에 일관된 정보 계층을 제공해야 한다(MUST).

#### Scenario: Mac 세 열 탐색
- **WHEN** 사용자가 넓은 Mac 창에서 앱을 연다
- **THEN** sidebar, timeline과 editor는 각 역할이 구분되면서 선택 상태, separator와 surface가 하나의 theme으로 연결된다

#### Scenario: 작은 Mac 창
- **WHEN** 사용자가 Mac 창 폭을 줄인다
- **THEN** 본문 가독 폭을 우선하고 탐색 열은 최소 폭 또는 시스템 collapse 동작으로 대응하며 핵심 action을 가리지 않는다

#### Scenario: 검색 결과 없음
- **WHEN** 작은 Mac 창에서 검색 결과가 없고 검색 조건 초기화 action이 표시된다
- **THEN** 빈 상태 제목, 설명과 action은 시스템 layout 안에서 순서대로 배치되어 서로 겹치지 않는다

#### Scenario: iPhone 탐색
- **WHEN** 사용자가 iPhone에서 유형 또는 노트북과 기록을 탐색한다
- **THEN** 앱은 동일한 색상·타이포그래피 계층을 NavigationStack에 맞게 제공하고 Mac의 고정 열이나 hover affordance를 요구하지 않는다

### Requirement: 읽기 쉬운 기록 목록
기록 목록은 제목, 최대 두 줄의 정리된 본문 미리보기, 날짜와 노트북을 우선순위에 따라 표시하고 raw Markdown marker가 탐색을 방해하지 않게 해야 한다(MUST).

#### Scenario: Markdown 기록 미리보기
- **WHEN** 제목이나 본문이 heading, bullet 또는 emphasis Markdown을 포함한다
- **THEN** 목록은 선행 `#`, `*`와 formatting delimiter를 제거한 사람이 읽을 수 있는 요약을 표시한다

#### Scenario: 긴 혼합 언어 기록
- **WHEN** 기록이 긴 한국어·영어 혼합 본문을 가진다
- **THEN** 목록은 두 줄 이내로 안정적으로 축약하고 날짜와 선택 affordance가 밀려나지 않는다

### Requirement: 시각 접근성
개편된 모든 핵심 화면은 Dynamic Type, VoiceOver, keyboard navigation, Reduce Motion과 플랫폼 대비 기준을 지원해야 한다(MUST).

#### Scenario: Dynamic Type 확대
- **WHEN** 사용자가 접근성 글자 크기를 사용한다
- **THEN** 제목, metadata와 주요 action은 잘리거나 겹치지 않고 필요하면 여러 줄 또는 대체 layout으로 전환된다

#### Scenario: 키보드와 VoiceOver 탐색
- **WHEN** 사용자가 키보드 또는 VoiceOver로 sidebar, timeline과 editor를 이동한다
- **THEN** 논리적인 순서, 보이는 focus와 action의 의미 있는 label을 제공한다

#### Scenario: Reduce Motion
- **WHEN** 사용자가 Reduce Motion을 활성화한다
- **THEN** 선택과 focus mode 전환은 필수 정보 변화만 즉시 표시하고 장식적 position animation을 사용하지 않는다
