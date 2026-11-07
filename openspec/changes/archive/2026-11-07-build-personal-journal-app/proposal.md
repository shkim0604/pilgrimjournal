## Why

Day One에 쌓인 기록을 잃지 않고 가져오면서도, 앞으로의 기록은 기도노트·성경공부·독서노트·일기·메모라는 사용 목적에 맞게 Mac과 iPhone 어디서든 이어서 관리할 개인용 공간이 필요하다. Apple 기기 안에서 오프라인 작성과 iCloud 동기화를 함께 제공해 기존 기록의 연속성, 일상적인 접근성, 개인 데이터 통제권을 확보한다.

## What Changes

- macOS와 iPhone에서 같은 기록을 생성·열람·수정·삭제할 수 있는 SwiftUI 멀티플랫폼 앱을 제공한다.
- 별도 이메일·비밀번호 회원가입 없이 macOS와 iPhone에서 `Sign in with Apple`로 사용자를 인증하고 승인된 사용자만 기록 화면에 접근하게 한다.
- Apple 로그인 사용자 식별자는 기기 Keychain에 보관하고 승인 철회·로그아웃을 반영한다. 이름은 요청하거나 저장하지 않으며, 계정 표시를 위해 이메일 scope를 요청하되 Apple이 제공한 이메일은 기기 Keychain에만 보관하고 CloudKit에는 저장하지 않는다.
- 각 기기는 로컬 데이터를 우선 사용하고, 사용 가능한 경우 동일한 시스템 iCloud 계정의 CloudKit 개인 데이터베이스를 통해 변경 내용을 동기화한다.
- 최초 연결 시 CloudKit private database를 Apple 로그인 사용자의 단방향 해시에 귀속하고 이후 다른 Apple 로그인 사용자의 접근을 차단한다.
- 인증을 완료한 사용자는 iCloud를 일시적으로 사용할 수 없거나 오프라인이어도 기록 작성·검색·백업을 로컬 전용으로 계속 제공한다.
- 사용자가 기기별 앱 잠금 비밀번호를 선택적으로 설정하고 Face ID·Touch ID를 보조 잠금 해제로 사용할 수 있게 한다.
- Mac 앱에서 Day One JSON 내보내기 ZIP을 읽어 글, 작성/수정 시각, 시간대, 태그, 위치·날씨, 즐겨찾기·고정 상태, 지원 가능한 첨부와 원본 메타데이터를 가져온다.
- 제공된 Day One export v1.0 샘플처럼 URL 인코딩된 JSON 파일명, `metadata`/`entries` 구조, 일반 `text`와 JSON 문자열 `richText`가 함께 있는 형식을 지원한다.
- 가져오기 전에 분석 결과와 분류 제안을 미리 보여 주고, 완료 후 성공·건너뜀·실패 내역을 제공한다.
- 같은 Day One 항목을 다시 가져와도 중복 생성하지 않으며 원본 UUID와 원본 메타데이터를 보존한다.
- 기록을 `기도노트`, `성경공부`, `독서노트`, `일기`, `메모` 다섯 유형으로 관리하고, 메모를 제외한 유형에는 유형별 보조 정보를 제공한다.
- 다섯 기록 유형과 별개로 사용자가 이름을 붙인 노트북을 추가하고 기록을 모아 볼 수 있게 한다.
- Day One 태그·템플릿과 분류 규칙을 이용해 가져온 기록을 다섯 유형에 매핑하고, 미분류 항목을 일괄 또는 개별 정리할 수 있게 한다.
- Day One 미리보기에서 여러 기록 또는 전체 기록을 선택해 하나의 사용자 노트북으로 일괄 지정할 수 있게 한다.
- 전체 텍스트 검색, 유형·태그·기간 필터, 최신순 타임라인으로 기록을 다시 찾을 수 있게 한다.
- 동기화와 별개로 버전이 있는 전체 데이터 백업을 내보내고 검증 후 복원할 수 있게 한다.

## Capabilities

### New Capabilities

- `day-one-import`: Day One export v1.0 JSON ZIP의 검증, 미리보기, 중복 방지 가져오기, 결과 보고 및 원본 데이터 보존
- `journal-entry-management`: Mac과 iPhone에서 다섯 기록 유형의 생성·조회·수정·삭제와 유형별 메타데이터 관리
- `journal-organization`: 가져온 기록의 태그·템플릿 기반 분류 규칙, 미분류 보관함, 태그 및 일괄 분류
- `journal-search`: 각 기기의 로컬 인덱스를 이용한 본문 검색과 유형·태그·기간 필터 및 타임라인 탐색
- `local-data-portability`: Apple 로그인 접근 인증, 로컬 우선 저장, 동일 iCloud 계정 간 동기화, 첨부 파일 관리, 전체 백업 및 복원

### Modified Capabilities

없음.

## Impact

- 신규 Xcode SwiftUI 멀티플랫폼 애플리케이션과 macOS·iOS 배포 타깃이 추가된다.
- 두 타깃의 `Sign in with Apple` capability, AuthenticationServices 기반 인증 UI와 Keychain 사용자 상태 저장이 필요하다.
- Swift 기반 공유 도메인 모델, 로컬 영속 저장소, CloudKit 개인 데이터베이스 스키마, 기기별 검색 인덱스가 필요하다.
- 앱 잠금 verifier는 동기화하지 않고 각 기기의 Keychain에 저장하며, 앱 잠금은 화면 접근 보호이고 CloudKit 데이터의 종단 간 암호화가 아니다.
- Day One JSON/ZIP 가져오기는 Mac 전용 워크플로로 시작하며, 정규화된 결과는 iPhone으로 동기화된다.
- 제공된 실제 샘플은 저장소에 포함하지 않고, 확인한 구조를 재현한 익명 합성 fixture로 회귀 테스트한다.
- iCloud 동기화에는 Apple Developer Program, CloudKit container, iCloud 및 Background Modes entitlement와 같은 Apple 배포 구성이 필요하다.
- Windows, Android, 웹, 자체 계정 서버, 이메일·비밀번호 회원가입, 여러 사용자 협업 및 Day One 실시간 동기화는 초기 범위에 포함하지 않는다.
