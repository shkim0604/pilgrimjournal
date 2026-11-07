## ADDED Requirements

### Requirement: 로컬 우선 핵심 동작
macOS와 iPhone 앱은 기록 생성·편집·검색에 네트워크 연결을 요구해서는 안 되며(MUST), Day One 가져오기와 백업·복원은 Mac에서 오프라인으로 실행할 수 있어야 한다(MUST).

#### Scenario: 오프라인 기록 작성
- **WHEN** 기기가 네트워크에 연결되어 있지 않다
- **THEN** 사용자는 로컬 기록을 생성·편집·검색할 수 있고 변경은 pending sync 상태로 보존된다

#### Scenario: iCloud 계정 없음
- **WHEN** 기기에 사용할 수 있는 iCloud 계정이 없다
- **THEN** 이미 Apple 로그인을 완료한 사용자는 로컬 핵심 기능을 유지하고 동기화가 비활성임을 명확히 확인한다

### Requirement: Sign in with Apple 접근 인증
앱은 별도 이메일·비밀번호 계정 없이 `Sign in with Apple`을 사용해 기록 화면 접근을 인증해야 한다(MUST). 앱은 Apple ID 비밀번호와 이름 scope를 요청하거나 저장해서는 안 되며(MUST NOT), 계정 표시를 위해 이메일 scope를 요청해야 한다(MUST). Apple이 발급한 opaque 사용자 식별자는 기기 Keychain에 저장해야 하며(MUST), Apple이 이메일을 제공한 경우 해당 이메일을 계정 표시 목적으로만 기기 Keychain에 저장할 수 있고(MAY) CloudKit·백업·로그에는 포함해서는 안 된다(MUST NOT).

#### Scenario: 첫 실행 Apple 로그인
- **WHEN** 사용자가 앱을 처음 실행한다
- **THEN** 시스템은 기록 제목·본문·검색 결과를 표시하기 전에 네이티브 Apple 로그인 버튼을 제공하고 인증 성공 후에만 앱 shell을 연다

#### Scenario: 인증 정보 최소 수집과 계정 표시
- **WHEN** 앱이 Apple 로그인 authorization request를 만든다
- **THEN** 시스템은 이름 scope 없이 이메일 scope만 요청하고 credential의 opaque 사용자 식별자를 저장하며, Apple이 이메일을 제공한 경우에만 해당 이메일을 기기 Keychain session에 저장한다

#### Scenario: 재로그인에서 이메일을 다시 제공하지 않음
- **WHEN** Apple이 재로그인 credential에 이메일을 포함하지 않는다
- **THEN** 시스템은 기존 Keychain 이메일이 있으면 유지하고 없으면 opaque 사용자 식별자를 계정 표시에 사용하며 로그인을 실패시키지 않는다

#### Scenario: 승인된 사용자의 재실행
- **WHEN** Keychain에 저장된 사용자 식별자의 credential state가 authorized이다
- **THEN** 시스템은 마지막 승인 session으로 앱 접근을 즉시 허용하고 로그인 확인 화면을 반복 표시하지 않으며 credential state와 CloudKit 귀속은 백그라운드에서 갱신한다

#### Scenario: 오프라인 재실행
- **WHEN** 이전에 승인된 사용자가 네트워크 오류로 credential state를 확인할 수 없는 상태에서 앱을 연다
- **THEN** 시스템은 마지막 승인 상태를 사용해 로컬 기록 접근을 유지하고 다음 연결 시 credential state를 다시 확인한다

#### Scenario: 권한 철회 또는 credential 없음
- **WHEN** 저장된 사용자 식별자의 credential state가 revoked 또는 notFound이거나 credential revoked notification을 받는다
- **THEN** 시스템은 기록 화면을 즉시 가리고 저장된 인증 session을 제거한 뒤 Apple 로그인 화면을 표시한다

#### Scenario: 사용자 로그아웃
- **WHEN** 사용자가 설정에서 로그아웃을 확인한다
- **THEN** 시스템은 journal 데이터를 삭제하지 않고 인증 session만 제거하며 로그인 화면으로 돌아간다

#### Scenario: 기존 로컬 데이터 귀속
- **WHEN** 앱 업데이트 전에 생성된 로컬 기록이 있는 기기에서 처음 Apple 로그인을 완료한다
- **THEN** 시스템은 해당 데이터 범위를 처음 로그인한 Apple 사용자 식별자에 귀속하고 이후 다른 식별자에는 노출하지 않는다

### Requirement: 앱 내 계정 삭제
Sign in with Apple로 앱에 접근하는 사용자는 앱 안에서 계정과 데이터를 삭제할 수 있어야 한다(MUST). 삭제는 최종 확인 후에만 실행해야 하며(MUST), 클라우드 단계가 실패하면 로컬 데이터를 삭제해서는 안 된다(MUST NOT). 같은 기기의 다른 Apple 사용자 데이터를 삭제해서는 안 된다(MUST NOT).

#### Scenario: iCloud 연결 상태의 계정 삭제
- **WHEN** iCloud가 연결된 사용자가 설정 › Apple 로그인 › 계정 삭제에서 최종 확인을 한다
- **THEN** 시스템은 열린 저장소를 닫고 CloudKit private database의 Apple 사용자 binding record와 mirroring zone을 삭제한 뒤 이 사용자의 로컬 범위, 범위별 설정, iCloud 키-값 노트북·유형 키, Keychain 로그인 session과 앱 잠금 항목을 삭제하고 로그인 화면에 삭제 완료와 Apple 로그인 연결 해제 경로를 안내한다

#### Scenario: 클라우드 삭제 실패
- **WHEN** 네트워크 또는 iCloud 오류로 CloudKit 삭제가 실패한다
- **THEN** 시스템은 로컬 데이터와 로그인 상태를 그대로 두고 다시 시도 또는 기록으로 돌아가기를 제공한다

#### Scenario: 다른 사용자에게 귀속된 iCloud
- **WHEN** 현재 iCloud binding이 삭제를 요청한 사용자와 다른 Apple 사용자 해시를 가진다
- **THEN** 시스템은 iCloud와 로컬 데이터를 모두 삭제하지 않고 오류를 표시한다

#### Scenario: local-only 상태의 계정 삭제
- **WHEN** iCloud를 사용할 수 없는 기기에서 사용자가 계정 삭제를 확인한다
- **THEN** 시스템은 클라우드 단계를 건너뛰고 이 기기의 해당 사용자 데이터와 로그인 정보만 삭제하며, 확인 화면에서 iCloud 기록은 남는다는 사실을 미리 알린다

#### Scenario: 같은 기기의 다른 Apple 사용자 데이터
- **WHEN** 기기에 다른 Apple 사용자의 계정 범위나 그 사용자가 claim한 legacy 저장소가 있다
- **THEN** 시스템은 해당 데이터를 남기고, 삭제 후에는 다른 Apple 사용자가 차단 없이 새로 로그인할 수 있게 한다

#### Scenario: 다른 기기의 로컬 사본
- **WHEN** 사용자가 계정 삭제 확인 화면을 연다
- **THEN** 시스템은 다른 기기에서 먼저 앱을 삭제하지 않으면 그 기기의 로컬 사본이 iCloud에 다시 올라갈 수 있다고 경고한다

### Requirement: 시스템 iCloud 계정 사용과 계정 격리
Apple 로그인은 앱 접근 인증에만 사용하고 앱은 기기의 시스템 iCloud 계정 상태를 별도로 관찰해야 한다(MUST). 서로 다른 Apple 로그인 사용자, iCloud 계정과 local-only 범위의 persistent store, 검색 인덱스와 pending queue는 격리되어야 한다(MUST).

#### Scenario: Apple 로그인 후 iCloud 사용 가능
- **WHEN** 인증된 사용자의 기기에서 시스템 iCloud private database를 사용할 수 있다
- **THEN** 시스템은 해당 private database를 Apple 로그인 사용자의 단방향 해시에 귀속하거나 기존 귀속이 같은지 확인한 뒤 동기화를 활성화한다

#### Scenario: iCloud 저장 공간의 Apple 사용자 불일치
- **WHEN** 현재 시스템 iCloud private database가 로그인한 사용자와 다른 Apple 사용자 해시에 이미 귀속되어 있다
- **THEN** 시스템은 기존 기록을 표시하거나 병합하지 않고 journal UI 접근을 차단하며 iCloud 계정을 확인하도록 안내한다

#### Scenario: iCloud 연결 정보 최소 수집
- **WHEN** 시스템이 private database에 Apple 사용자 귀속을 기록한다
- **THEN** 시스템은 앱 범위 단방향 해시만 저장하고 Apple 로그인의 원본 사용자 식별자·이름·이메일을 CloudKit에 저장하지 않는다

#### Scenario: iCloud 계정 로그아웃 또는 교체
- **WHEN** 앱 사용 중 시스템 iCloud 계정이 로그아웃되거나 다른 계정으로 변경된다
- **THEN** 시스템은 이전 계정 저장소를 닫고 해당 데이터가 새 계정 또는 local-only 화면에 노출되거나 자동 병합되지 않게 한다

#### Scenario: local-only 기록을 iCloud로 이전
- **WHEN** local-only 기록이 있는 사용자가 이후 시스템 iCloud 계정을 활성화한다
- **THEN** 시스템은 이전 대상과 영향을 설명하고 사용자가 명시적으로 확인한 경우에만 해당 기록을 새 iCloud 계정 저장소에 revision으로 복사한다

#### Scenario: 다른 Apple 사용자 로그인
- **WHEN** 기존 데이터 범위에 귀속된 식별자와 다른 Apple 사용자가 같은 앱 설치본에 로그인한다
- **THEN** 시스템은 기존 기록을 표시하거나 자동 병합하지 않고 별도 데이터 범위를 준비하거나 지원되지 않는 경우 안전하게 접근을 차단한다

### Requirement: 선택적 기기별 앱 잠금
앱은 사용자가 설정에서 기기별 앱 잠금 비밀번호를 선택적으로 활성화할 수 있게 해야 한다(MUST). 비밀번호 원문과 verifier는 CloudKit·백업·로그에 포함해서는 안 되며(MUST NOT), verifier는 salt와 느린 password derivation을 적용해 기기 전용 Keychain에만 저장해야 한다(MUST).

#### Scenario: 앱 잠금 설정
- **WHEN** 사용자가 6자 이상의 비밀번호를 두 번 동일하게 입력하고 잠금 시간을 선택한다
- **THEN** 시스템은 원문을 저장하지 않고 기기 전용 verifier와 설정을 저장한 뒤 앱 잠금을 활성화한다

#### Scenario: 잠긴 앱 실행
- **WHEN** 잠금이 활성화된 앱을 새로 실행하거나 선택한 background 유예 시간이 지난 뒤 연다
- **THEN** 시스템은 기록 제목·본문·검색 결과를 표시하기 전에 비밀번호 또는 허용된 생체 인증을 요구한다

#### Scenario: 생체 인증 실패 또는 취소
- **WHEN** Face ID·Touch ID가 실패하거나 사용자가 생체 인증을 취소한다
- **THEN** 시스템은 기록을 노출하지 않고 앱 비밀번호 입력 fallback을 제공한다

#### Scenario: 반복 비밀번호 실패
- **WHEN** 사용자가 잘못된 비밀번호를 반복 입력한다
- **THEN** 시스템은 실패 횟수에 따라 재시도 시간을 늘리고 앱 재실행 후에도 현재 지연을 유지한다

#### Scenario: background 화면 보호
- **WHEN** 앱이 background로 이동하거나 잠금 상태가 된다
- **THEN** 시스템은 app switcher snapshot을 포함한 scene 위에 불투명한 privacy shield를 표시한다

#### Scenario: 다른 기기에서 앱 사용
- **WHEN** 한 기기에서 앱 잠금을 설정한 사용자가 같은 iCloud 계정의 다른 기기에서 앱을 연다
- **THEN** 시스템은 비밀번호 verifier와 잠금 설정을 동기화하지 않고 다른 기기의 설정을 독립적으로 유지한다

#### Scenario: 비밀번호 재설정
- **WHEN** 사용자가 비밀번호를 잊고 OS의 기기 소유자 인증을 성공한다
- **THEN** 시스템은 기존 일기 데이터를 삭제하거나 개발자 서버에 복구 정보를 요청하지 않고 새 기기별 비밀번호를 설정하게 한다

#### Scenario: 앱 잠금 보호 범위 안내
- **WHEN** 사용자가 앱 잠금을 활성화하거나 개인정보 안내를 연다
- **THEN** 시스템은 앱 잠금이 UI 접근 보호이며 journal database와 CloudKit record의 비밀번호 기반 종단 간 암호화가 아님을 설명한다

### Requirement: CloudKit 개인 데이터 동기화
시스템은 같은 시스템 iCloud 계정의 CloudKit private database를 이용해 canonical 기록, revision, 분류 규칙, tombstone과 첨부를 Mac과 iPhone 사이에 동기화해야 한다(MUST).

#### Scenario: 같은 계정의 두 기기
- **WHEN** Mac과 iPhone이 같은 iCloud 계정과 앱 container를 사용하고 네트워크에 연결된다
- **THEN** 한 기기의 canonical 변경은 다른 기기의 로컬 저장소에 최종적으로 나타난다

#### Scenario: 다른 iCloud 계정
- **WHEN** 두 기기가 서로 다른 iCloud 계정을 사용한다
- **THEN** 시스템은 두 계정의 개인 데이터를 서로 동기화하거나 노출하지 않는다

#### Scenario: 외부 앱 서버 없음
- **WHEN** 사용자가 기록과 첨부를 동기화한다
- **THEN** 시스템은 public/shared CloudKit database나 개발자가 운영하는 별도 데이터 서버로 내용을 전송하지 않는다

### Requirement: 동기화 상태와 복구 가능한 오류
시스템은 로컬 저장 성공과 원격 동기화 상태를 구분하고 계정·네트워크·용량·첨부 오류를 데이터 손실 없이 표시해야 한다(MUST).

#### Scenario: 로컬 저장 후 동기화 지연
- **WHEN** 기록은 로컬에 저장됐지만 CloudKit 전송이 아직 완료되지 않았다
- **THEN** 시스템은 기록을 정상적으로 사용할 수 있게 하고 pending 상태를 표시한다

#### Scenario: iCloud 용량 또는 일시 오류
- **WHEN** CloudKit이 용량 부족이나 일시 오류를 반환한다
- **THEN** 시스템은 로컬 원본을 유지하고 오류 이유와 재시도 가능한 상태를 표시한다

### Requirement: 오프라인 변경 수렴
시스템은 Mac과 iPhone이 각각 오프라인에서 만든 변경을 연결 후 동기화하고 결정적으로 수렴시켜야 한다(MUST).

#### Scenario: 서로 다른 기록 편집
- **WHEN** 오프라인 Mac과 iPhone이 서로 다른 기록을 편집한 뒤 연결된다
- **THEN** 시스템은 두 변경을 모두 보존하고 각 기기에 전파한다

#### Scenario: 같은 기록 동시 편집
- **WHEN** 두 기기가 같은 base revision의 동일 기록을 각각 편집한다
- **THEN** 시스템은 결정적 winner를 현재 내용으로 선택하고 losing revision을 이력에서 복원 가능하게 유지한다

### Requirement: 삭제와 복원의 수렴
시스템은 삭제 tombstone과 명시적 복원 revision을 동기화해 오래된 기기가 삭제된 기록을 자동 부활시키지 않게 해야 한다(MUST).

#### Scenario: 삭제 후 오래된 기기 연결
- **WHEN** Mac에서 삭제가 동기화된 뒤 오래 오프라인이던 iPhone이 이전 기록 상태로 연결된다
- **THEN** 시스템은 tombstone을 유지하고 iPhone의 오래된 내용은 현재 기록으로 되살리지 않는다

#### Scenario: 사용자 복원
- **WHEN** 사용자가 삭제된 기록을 명시적으로 복원한다
- **THEN** 시스템은 tombstone보다 최신 복원 revision을 생성하고 양쪽 기기의 일반 목록에 기록을 되돌린다

### Requirement: 첨부 파일 동기화와 지연 다운로드
시스템은 첨부 파일을 CloudKit asset으로 동기화하고 본문과 독립적으로 다운로드·재시도할 수 있게 해야 한다(MUST).

#### Scenario: iPhone의 지연 다운로드
- **WHEN** iPhone이 첨부 메타데이터는 받았지만 binary는 아직 로컬에 없다
- **THEN** 시스템은 기록 본문과 placeholder를 표시하고 사용자가 첨부를 열 때 다운로드한다

#### Scenario: 첨부 다운로드 실패
- **WHEN** 첨부 다운로드가 네트워크 또는 용량 오류로 실패한다
- **THEN** 시스템은 본문을 계속 표시하고 첨부 오류와 재시도 동작을 제공한다

#### Scenario: 동일 체크섬 첨부
- **WHEN** 내용 체크섬이 같은 첨부 파일을 여러 기록이 사용한다
- **THEN** 시스템은 각 기록 연결을 유지하면서 기기 로컬 binary 중복을 줄일 수 있다

### Requirement: 전체 백업 생성
macOS 앱은 canonical 데이터, revision, tombstone, 분류 규칙, 첨부와 선택된 Mac 로컬 import snapshot을 저장 엔진과 독립적인 단일 백업 ZIP으로 생성해야 한다(MUST).

#### Scenario: 백업 성공
- **WHEN** 사용자가 쓰기 가능한 위치를 선택해 백업을 실행한다
- **THEN** 시스템은 JSON Lines 데이터, 첨부, format·schema version과 파일별 체크섬 manifest를 일관된 백업으로 생성한다

#### Scenario: 백업 쓰기 실패
- **WHEN** 대상 공간 부족이나 권한 문제로 백업을 완성할 수 없다
- **THEN** 시스템은 불완전한 파일을 유효한 백업으로 표시하지 않고 원인을 설명하며 현재 앱 데이터를 변경하지 않는다

### Requirement: 검증 후 merge 복원
macOS 앱은 백업을 임시 위치에서 검증하고 현재 안전 백업을 만든 뒤 기존 canonical 데이터와 merge할 수 있게 해야 한다(MUST).

#### Scenario: 유효한 merge 복원
- **WHEN** 사용자가 호환되는 백업을 선택하고 merge를 확인한다
- **THEN** 시스템은 manifest와 체크섬을 검증하고 없는 안정 ID는 추가하며 기존 ID의 충돌은 revision 비교 결과를 보여 준다

#### Scenario: 손상되거나 호환되지 않는 백업
- **WHEN** 백업의 체크섬이 맞지 않거나 format version을 지원하지 않는다
- **THEN** 시스템은 복원을 중단하고 기존 데이터를 그대로 유지하며 검증 실패 이유를 표시한다

### Requirement: 검증 후 replace 복원
macOS 앱은 사용자가 명시적으로 확인하면 검증된 백업 상태로 canonical 데이터를 교체하고 결과를 다른 기기로 수렴시켜야 한다(MUST).

#### Scenario: replace 복원
- **WHEN** 사용자가 현재 안전 백업 생성 후 replace 복원을 확인한다
- **THEN** 시스템은 restore epoch을 만들고 백업에 없는 현재 항목에 tombstone을, 백업 항목에 restore revision을 생성한다

#### Scenario: replace 복원 중 실패
- **WHEN** restore 변경 생성 중 오류가 발생한다
- **THEN** 시스템은 미완료 batch를 활성 상태로 표시하지 않고 안전 백업과 재시도 경로를 유지한다

### Requirement: 저장소 무결성 검사
시스템은 canonical 참조, revision, 첨부와 로컬 검색 인덱스의 불일치를 탐지하고 사용자 데이터 자동 삭제 없이 보고해야 한다(MUST).

#### Scenario: 누락 첨부 탐지
- **WHEN** 첨부 메타데이터가 있지만 local binary와 CloudKit asset을 모두 읽을 수 없다
- **THEN** 시스템은 영향을 받는 기록을 식별하고 본문을 유지한 채 오류로 보고한다

#### Scenario: 검색 인덱스 불일치
- **WHEN** canonical 기록과 로컬 검색 인덱스의 history token이 맞지 않는다
- **THEN** 시스템은 canonical 데이터를 변경하지 않고 검색 인덱스를 재구축한다
