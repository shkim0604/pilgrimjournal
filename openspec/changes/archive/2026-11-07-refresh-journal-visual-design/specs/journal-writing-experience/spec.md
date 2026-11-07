## ADDED Requirements

### Requirement: 집중형 paper editor
Mac과 iPhone 편집 화면은 본문을 가장 높은 시각 우선순위로 두고 제목, metadata, 본문과 footer가 명확히 구분된 paper editor를 제공해야 한다(MUST).

#### Scenario: Mac에서 새 기록 작성
- **WHEN** 사용자가 Mac에서 새 기록을 연다
- **THEN** 편집기는 최대 가독 폭의 paper surface, 명확한 제목과 넉넉한 본문 행간을 제공하고 분산된 도구가 본문을 압도하지 않는다

#### Scenario: iPhone에서 새 기록 작성
- **WHEN** 사용자가 iPhone에서 새 기록을 연다
- **THEN** 편집기는 화면 폭을 본문에 사용하고 metadata와 서식 action을 compact control과 keyboard accessory로 제공한다

#### Scenario: 긴 본문
- **WHEN** 사용자가 긴 한국어·영어 혼합 기록을 읽거나 편집한다
- **THEN** 편집기는 안정적인 line length, Dynamic Type과 scroll position을 유지한다

### Requirement: 한 줄 metadata와 현재 맥락
편집 화면은 노트북, 기록 유형, 날짜, 즐겨찾기, 고정과 이력을 compact metadata 영역에 모으고 새 기록이 시작된 탐색 맥락을 유지해야 한다(MUST).

#### Scenario: 노트북에서 새 기록
- **WHEN** 사용자가 특정 노트북을 탐색하다 새 기록을 연다
- **THEN** 해당 노트북이 metadata에 자동 선택되어 있고 사용자는 본문 입력 전에 이를 확인하거나 변경할 수 있다

#### Scenario: 좁은 화면의 metadata
- **WHEN** 모든 metadata control이 한 줄에 들어가지 않는다
- **THEN** 시스템은 핵심 맥락을 chip으로 유지하고 나머지를 sheet 또는 overflow menu로 제공하며 본문 폭을 침범하지 않는다

### Requirement: 방해하지 않는 자동 저장 피드백
편집기는 정상적인 기록에서 별도의 저장 동작을 요구하지 않고 자동 저장의 진행, 완료와 오류 상태를 명확하지만 방해되지 않게 표시해야 한다(MUST).

#### Scenario: 입력 중 자동 저장
- **WHEN** 사용자가 제목, 본문 또는 metadata를 변경한다
- **THEN** 편집기는 debounce 후 저장하며 `저장 중`에서 `저장됨`으로 안정적으로 전환한다

#### Scenario: 저장 오류
- **WHEN** 로컬 저장이 실패한다
- **THEN** 편집기는 오류를 숨기지 않고 원인을 설명하며 재시도 action을 제공하고 입력 내용을 화면에 유지한다

#### Scenario: 빠른 연속 입력
- **WHEN** 사용자가 빠르게 본문을 계속 입력한다
- **THEN** 저장 상태가 매 keystroke마다 깜빡이지 않고 마지막 변경을 기준으로 갱신된다

### Requirement: 즉시 서식 Markdown 편집
편집기는 지원하는 Markdown 문법을 입력과 동시에 시각적 서식으로 표시하고 일반 작성 중 formatting marker를 숨겨야 한다(MUST).

#### Scenario: 제목과 강조 입력
- **WHEN** 사용자가 heading, bold 또는 italic Markdown을 입력한다
- **THEN** 편집기는 해당 내용을 즉시 서식화하고 커서가 문법 영역을 벗어나면 marker를 감춘다

#### Scenario: bullet 자동 변환
- **WHEN** 사용자가 줄 시작에서 `*`와 공백을 입력한다
- **THEN** 편집기는 bullet 항목으로 전환하고 다음 줄에서도 자연스러운 목록 입력을 이어간다

#### Scenario: 기존 Markdown 기록
- **WHEN** 사용자가 가져온 Markdown 본문을 연다
- **THEN** 지원 문법은 데이터 변환이나 delimiter 손실 없이 즉시 서식으로 표시된다

#### Scenario: Day One escape marker
- **WHEN** Day One에서 가져온 본문에 `\\.`처럼 문장부호를 escape한 Markdown이 있다
- **THEN** 편집기는 커서가 해당 문법에 닿지 않을 때 escape marker를 숨기고 저장 원문은 변경하지 않는다

#### Scenario: Day One 호환 서식
- **WHEN** 사용자가 제목 1~6, 번호·불릿·중첩 목록, 체크리스트, 인용, 취소선, 하이라이트 또는 코드 문법을 입력한다
- **THEN** 편집기는 지원 서식을 즉시 표시하고 목록 입력은 다음 줄에서 자연스럽게 이어진다

### Requirement: 발견 가능한 서식 명령
편집기는 `/` 명령 palette와 텍스트 선택 시 나타나는 contextual toolbar를 제공하면서 평상시 본문 공간을 가리지 않아야 한다(MUST).

#### Scenario: slash command 열기
- **WHEN** 사용자가 빈 줄 또는 명령 가능한 위치에서 `/`를 입력한다
- **THEN** 편집기는 제목 1~3, 오늘 날짜, 구분선, bullet과 지원 명령을 검색 가능한 목록으로 표시한다

#### Scenario: 텍스트 선택
- **WHEN** 사용자가 본문 일부를 선택한다
- **THEN** 편집기는 bold, italic, heading, bullet, quote와 link 중 지원 action을 가까운 contextual toolbar로 제공한다

#### Scenario: 키보드 사용자
- **WHEN** 사용자가 마우스나 touch 없이 편집한다
- **THEN** command palette와 서식 action을 방향키, Return, Escape와 문서화된 shortcut으로 조작할 수 있다

### Requirement: 태그 chip과 보조 정보 footer
편집기는 일반 태그를 노트북과 구분되는 chip으로 표시하고 본문 아래에 글자 수와 마지막 수정 시각을 낮은 강조로 제공해야 한다(MUST).

#### Scenario: 태그 추가와 제거
- **WHEN** 사용자가 태그를 입력하거나 기존 태그를 제거한다
- **THEN** 편집기는 중복 없는 chip으로 즉시 반영하고 예약된 노트북 metadata를 일반 태그로 노출하지 않는다

#### Scenario: 본문 통계
- **WHEN** 사용자가 기록을 편집한다
- **THEN** footer는 글자 수와 마지막 수정 정보를 표시하되 본문 입력 focus를 빼앗지 않는다

### Requirement: Mac 집중 모드
Mac 앱은 현재 편집 상태를 유지한 채 sidebar와 timeline을 숨겨 본문만 표시하는 집중 모드를 제공해야 한다(MUST).

#### Scenario: 집중 모드 진입
- **WHEN** 사용자가 toolbar action 또는 keyboard shortcut으로 집중 모드를 켠다
- **THEN** 현재 editor, cursor, selection과 미저장 입력을 유지하면서 탐색 열을 숨긴다

#### Scenario: 집중 모드 종료
- **WHEN** 사용자가 집중 모드를 끄거나 Escape 동작을 사용한다
- **THEN** 이전 sidebar와 timeline 선택을 복원하고 동일 기록의 편집 위치를 유지한다

#### Scenario: Reduce Motion 집중 모드
- **WHEN** Reduce Motion이 켜진 상태에서 집중 모드를 전환한다
- **THEN** 탐색 열은 장식적인 이동 animation 없이 나타나거나 사라진다
