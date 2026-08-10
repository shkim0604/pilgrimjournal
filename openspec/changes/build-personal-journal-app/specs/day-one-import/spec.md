## ADDED Requirements

### Requirement: Day One export v1.0 파일 분석
macOS 앱은 지원하는 Day One export v1.0 JSON ZIP을 데이터 변경 없이 분석하고 가져오기 전 요약을 제공해야 한다(MUST).

#### Scenario: 제공 샘플 구조 미리보기
- **WHEN** ZIP 안의 안전한 JSON 후보가 `metadata.version` 값 `1.0`과 `entries` 배열을 포함한다
- **THEN** 시스템은 JSON 파일명이 URL 인코딩되어 있거나 특정 이름이 아니어도 구조로 식별하고 전체 기록 수, 날짜 범위, 선택 필드 수, 중복 예상 수와 경고 수를 표시한다

#### Scenario: 분석 단계 무변경
- **WHEN** 사용자가 Day One ZIP을 선택해 미리보기까지만 수행한다
- **THEN** 시스템은 canonical 기록, 가져오기 이력 또는 CloudKit 동기화 대상을 생성하지 않는다

#### Scenario: 지원하지 않는 파일
- **WHEN** 선택한 파일이 암호화되어 있거나 읽을 수 있는 Day One JSON이 없거나 ZIP 안전 제한을 위반한다
- **THEN** 시스템은 이유를 설명하며 가져오기 실행을 허용하지 않고 기존 데이터를 변경하지 않는다

### Requirement: 본문 정규화
macOS 앱은 Day One 항목의 `text`를 canonical 본문으로 우선 사용하고 JSON 문자열 `richText`를 안전하게 처리해야 한다(MUST).

#### Scenario: text와 richText가 함께 존재
- **WHEN** 항목에 일반 문자열 `text`와 JSON 문자열 `richText`가 모두 있다
- **THEN** 시스템은 `text`를 편집 가능한 canonical 본문으로 저장하고 원본 `richText`는 source snapshot에 보존한다

#### Scenario: text 없이 유효한 richText 존재
- **WHEN** 항목에 `text`가 없고 parse 가능한 `richText`만 있다
- **THEN** 시스템은 `richText` 내부 text content에서 읽을 수 있는 본문을 복원하고 원본 JSON 문자열을 보존한다

#### Scenario: richText parse 실패와 text 존재
- **WHEN** `richText`를 parse할 수 없지만 `text`는 유효하다
- **THEN** 시스템은 `text`로 기록을 가져오고 rich text 경고를 결과에 표시한다

### Requirement: Day One 메타데이터 보존
macOS 앱은 원본 UUID, 생성·수정 시각, 시간대, 위치·날씨, 즐겨찾기·고정 상태와 지원 가능한 메타데이터를 보존해야 한다(MUST).

#### Scenario: 제공 샘플의 메타데이터
- **WHEN** 항목에 `creationDate`, `modifiedDate`, `timeZone`, `location`, `weather`, `starred`, `isPinned`가 있다
- **THEN** 시스템은 조회 가능한 canonical 필드로 정규화하고 원본 UTC instant와 시간대를 함께 보존한다

#### Scenario: 템플릿과 기기 정보
- **WHEN** 항목에 template, 생성 기기·모델·OS, editing time 또는 앱이 직접 표시하지 않는 필드가 있다
- **THEN** 시스템은 지원 필드의 가져오기를 계속하고 전체 원본 값을 Mac 로컬 source snapshot에 보존한다

#### Scenario: 알 수 없는 선택 필드
- **WHEN** Day One 항목에 adapter가 해석하지 못하는 필드가 있다
- **THEN** 시스템은 항목을 실패시키지 않고 해당 필드를 source snapshot에 남기며 경고로 보고한다

### Requirement: 태그와 템플릿 기반 분류
macOS 앱은 Day One 태그와 템플릿 식별자·제목에 분류 규칙을 적용하고 근거가 없는 기록을 미분류로 유지해야 한다(MUST).

#### Scenario: 태그 없는 샘플 항목
- **WHEN** Day One 항목에 태그가 없고 template 규칙만 일치한다
- **THEN** 시스템은 template 규칙의 대상 유형을 제안하고 적용 근거를 미리보기에 표시한다

#### Scenario: 어떤 분류 규칙도 없음
- **WHEN** 항목의 태그와 template이 활성 규칙과 일치하지 않는다
- **THEN** 시스템은 내용을 추측하지 않고 미분류로 제안한다

### Requirement: 첨부 파일 가져오기
macOS 앱은 Day One 항목이 참조하는 사진과 지원하는 파일을 로컬 저장소에 복사하고 canonical 기록과 연결해야 한다(MUST).

#### Scenario: 정상 첨부
- **WHEN** JSON이 참조하는 첨부 파일이 ZIP 안에 있고 안전 제한을 충족한다
- **THEN** 시스템은 체크섬을 계산해 첨부 모델을 만들고 기록과 연결하며 CloudKit 동기화 대상으로 표시한다

#### Scenario: 누락되거나 손상된 첨부
- **WHEN** 참조된 첨부 파일이 없거나 읽을 수 없다
- **THEN** 시스템은 본문 기록의 가져오기를 계속하고 누락된 파일명과 원본 기록을 결과 보고서에 표시한다

### Requirement: 반복 가능한 가져오기
macOS 앱은 원본 UUID가 같은 Day One 항목을 두 번 생성해서는 안 되며(MUST), 기존 편집 내용을 재가져오기로 덮어써서는 안 된다(MUST).

#### Scenario: 같은 파일 재가져오기
- **WHEN** 사용자가 이전에 성공적으로 가져온 원본 UUID가 포함된 파일을 다시 가져온다
- **THEN** 시스템은 해당 항목을 중복으로 건너뛰고 기존 기록을 변경하지 않으며 건너뜀 수를 보고한다

#### Scenario: 일부만 처리된 파일 재가져오기
- **WHEN** 이전 작업에서 일부 항목만 성공한 파일을 다시 가져온다
- **THEN** 시스템은 성공했던 항목은 건너뛰고 아직 성공하지 않은 항목만 처리한다

### Requirement: 장애 격리와 결과 보고
macOS 앱은 개별 항목 오류를 다른 유효 항목과 격리하고 성공·건너뜀·실패·경고·미분류 결과를 제공해야 한다(MUST).

#### Scenario: 일부 항목이 손상된 가져오기
- **WHEN** 가져오기 파일의 한 항목은 손상되었지만 나머지 항목은 유효하다
- **THEN** 시스템은 유효 항목을 가져오고 손상 항목의 원본 식별자와 실패 이유를 결과에 표시한다

#### Scenario: 사용자가 가져오기 취소
- **WHEN** 사용자가 진행 중인 가져오기를 취소한다
- **THEN** 시스템은 현재 항목을 안전한 경계에서 중단하고 완료된 항목 수를 보고하며 재실행 가능한 상태를 유지한다

### Requirement: 가져온 기록의 기기 간 전파
성공적으로 가져온 canonical 기록은 일반 사용자가 작성한 기록과 동일한 CloudKit 동기화 대상이 되어야 한다(MUST).

#### Scenario: Mac 가져오기 후 iPhone 수신
- **WHEN** Mac에서 가져오기가 완료되고 Mac과 iPhone이 같은 iCloud 계정으로 연결된다
- **THEN** iPhone은 canonical 기록을 점진적으로 수신하고 각 기록을 해당 유형 또는 미분류 보관함에 표시한다

#### Scenario: 원본 snapshot 비동기화
- **WHEN** Day One 항목의 전체 원본 snapshot이 Mac에 저장된다
- **THEN** 시스템은 canonical 필드와 source UUID만 동기화하고 전체 원본 snapshot은 iPhone에 전송하지 않는다

### Requirement: 선택 항목의 노트북 일괄 지정
macOS 앱은 Day One 가져오기 미리보기에서 여러 항목을 선택하거나 전체 선택한 뒤 하나의 사용자 노트북 이름을 일괄 지정할 수 있게 해야 한다(MUST).

#### Scenario: 여러 항목 노트북 지정
- **WHEN** 사용자가 미리보기 항목 여러 개를 선택하고 노트북 이름을 지정한다
- **THEN** 시스템은 선택된 항목의 가져오기 계획에만 해당 노트북을 연결하고 기록 유형과 일반 태그를 유지한다

#### Scenario: 전체 선택
- **WHEN** 사용자가 전체 선택을 누른다
- **THEN** 시스템은 현재 미리보기의 모든 항목을 선택하고 다시 누르면 전체 선택을 해제한다

#### Scenario: 선택하지 않은 항목
- **WHEN** 일부 항목만 선택해 노트북을 지정한다
- **THEN** 시스템은 선택하지 않은 항목의 노트북 계획을 변경하지 않는다
