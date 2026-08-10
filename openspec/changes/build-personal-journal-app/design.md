## Context

현재 저장소에는 애플리케이션 코드나 기존 데이터 모델이 없다. 첫 버전의 대상은 한 사람이 동일한 Apple ID로 사용하는 Mac과 iPhone이며 Windows, Android, 웹은 대상이 아니다. 사용자는 두 기기 어디서든 기록을 작성하고 읽을 수 있어야 하고, 네트워크가 없을 때도 작업한 뒤 연결되면 자동으로 수렴해야 한다.

Day One 가져오기는 파일 선택과 대용량 ZIP 처리가 편한 Mac에서 수행하고 정규화된 기록을 iPhone으로 동기화한다. 제공된 실제 샘플은 정상적인 비암호화 ZIP 하나에 URL 인코딩된 JSON 파일 하나가 있으며, export version `1.0`, 최상위 `metadata`와 `entries`, 항목별 `text`와 JSON 문자열 `richText`, 시각·시간대·위치·날씨·즐겨찾기·고정·템플릿·기기 메타데이터를 포함한다. 이 샘플에는 태그와 미디어가 없으므로 해당 변형은 합성 fixture와 후속 샘플로 검증해야 한다.

일기는 민감한 데이터다. 기록 화면은 Sign in with Apple로 승인된 사용자에게만 열고, 핵심 기능은 자체 계정 서버 없이 로컬에서 동작해야 하며, 동기화할 때는 사용자의 CloudKit 개인 데이터베이스만 사용한다. CloudKit은 즉시 일관성이 아니라 최종 일관성을 제공하므로 충돌, 삭제 전파, 첨부 지연, 계정 부재와 할당량 오류를 앱의 정상 상태로 다뤄야 한다.

## Goals / Non-Goals

**Goals:**

- 하나의 SwiftUI 멀티플랫폼 프로젝트로 macOS와 iPhone 앱을 제공한다.
- 이름·이메일을 수집하지 않는 Sign in with Apple로 앱 접근을 인증하고 권한 철회와 로그아웃을 안전하게 처리한다.
- 각 기기에서 로컬 우선으로 생성·편집·검색하고 같은 iCloud 계정에서 자동 동기화한다.
- 동시 편집과 삭제 충돌을 결정적으로 수렴시키고 이전 내용을 복구 가능한 버전으로 남긴다.
- Day One export v1.0 ZIP을 Mac에서 안전하고 반복 가능한 방식으로 가져온다.
- 기도노트·성경공부·독서노트·일기를 두 기기에서 일관되게 제공한다.
- 한국어 검색을 포함한 검색 인덱스는 기기마다 로컬에서 재구축 가능하게 유지한다.
- 저장 엔진과 무관한 버전 백업으로 전체 데이터를 이동하고 복원할 수 있게 한다.

**Non-Goals:**

- Windows, Android, 웹 클라이언트
- 이메일·비밀번호 회원가입, 자체 인증·동기화 서버, 여러 사용자 협업과 공유
- Day One 앱이나 비공개 API와의 실시간 양방향 동기화
- iPhone에서 Day One 대용량 ZIP을 가져오는 기능
- AI 요약·자동 감정 분석·자동 신앙 조언
- CloudKit 외의 동기화 제공자와 앱 자체 종단 간 암호화
- Day One의 모든 독점 표현과 서식에 대한 픽셀 단위 재현

## Decisions

### 1. Swift와 SwiftUI 멀티플랫폼 타깃

Xcode의 SwiftUI 멀티플랫폼 앱 타깃으로 iOS와 macOS를 함께 구성한다. 도메인 모델, 저장소 protocol, 가져오기 parser, 분류, 검색 query, view model과 대부분의 화면을 공유 Swift package에 둔다. 파일 가져오기, 메뉴·키보드 명령, 창 관리와 같은 기능만 `#if os(macOS)` 또는 플랫폼별 scene으로 분리한다.

Flutter도 두 플랫폼을 지원하지만 CloudKit, background notification, iCloud entitlement, macOS 메뉴·창과 iOS 시스템 기능을 사용하려면 Dart와 Swift 사이의 plugin 또는 platform channel 계층이 추가된다. Android와 웹을 지원하지 않는 이 앱에서는 그 복잡성을 상쇄할 이점이 작으므로 Apple 네이티브 stack을 선택한다.

### 2. Sign in with Apple 접근 인증과 CloudKit 계정의 분리

두 플랫폼은 AuthenticationServices의 네이티브 Apple 로그인 화면을 앱 shell보다 먼저 표시한다. authorization request에는 이름·이메일 scope를 넣지 않고 성공 credential의 opaque `user` 식별자만 기기 Keychain에 저장한다. 앱 시작 시 `ASAuthorizationAppleIDProvider`로 credential state를 확인해 `authorized`이면 진입하고 `revoked` 또는 `notFound`이면 session을 지운 뒤 로그인 화면으로 돌아간다. credential revoked notification도 같은 전환을 수행한다.

이 앱은 자체 계정 서버가 없으므로 Apple identity token을 서버 session으로 교환하지 않는다. 일시적인 네트워크 오류로 credential state를 확인할 수 없을 때는 마지막으로 승인된 Keychain session으로 오프라인 로컬 접근을 유지하고 연결 후 다시 확인한다. 로그아웃은 인증 session만 제거하며 journal 데이터는 삭제하지 않는다.

업데이트 전에 생성된 기존 로컬 데이터는 해당 설치에서 처음 로그인한 Apple 사용자 식별자에 귀속한다. 다른 식별자가 로그인하면 기존 범위를 노출하거나 병합하지 않고, 사용자별 저장소 격리가 완료되기 전에는 안전하게 접근을 차단한다. Sign in with Apple은 앱 접근 identity이고 CloudKit private database 선택은 시스템 iCloud 계정이 담당하므로 두 상태를 별도로 표시하고 검증한다.

Apple은 Sign in with Apple 계정과 시스템 iCloud 계정의 이메일 또는 Apple ID를 앱이 직접 비교하는 API를 제공하지 않는다. 따라서 현재 CloudKit private database의 고정 binding record에 로그인 credential의 opaque `user` 값을 앱 범위에서 SHA-256한 값만 저장한다. 빈 database는 최초 로그인 사용자에게 원자적으로 귀속하고, 기존 binding과 다른 사용자는 journal UI 진입을 차단한다. 원본 `user`, 이름과 이메일은 CloudKit에 저장하지 않는다. iCloud를 확인할 수 없는 동안은 기기 Keychain의 기존 사용자 귀속을 보안 경계로 사용해 local-only 접근만 허용한다.

기기별 앱 잠금은 Apple 로그인 이후의 추가 privacy gate다. 인증 session이 없거나 철회되면 앱 잠금 성공 여부와 무관하게 기록을 표시하지 않는다.

### 2-1. SwiftData 로컬 저장과 CloudKit 자동 동기화

SwiftData `ModelContainer`의 CloudKit private database 구성을 사용해 각 기기에 로컬 replica를 두고 동일 iCloud 계정에서 자동 동기화한다. iCloud와 remote notification background mode capability를 두 타깃에 설정한다. iCloud 계정이 없거나 일시적으로 사용할 수 없을 때도 로컬 저장은 계속되고 앱은 동기화 불가 상태를 명확히 표시한다.

앱은 Apple 로그인 식별자와 별개로 `CKContainer.accountStatus`와 계정 변경 알림을 통해 시스템 iCloud 사용 가능 여부를 관찰한다. 계정이 사용 가능하면 해당 사용자의 private database를 연결하고, 사용할 수 없으면 이미 인증된 사용자의 별도 local-only 저장 범위에서 핵심 기능을 계속 제공한다.

iCloud 로그아웃 또는 계정 교체는 보안 경계로 취급한다. 앱은 이전 계정에 연결된 persistent store를 먼저 닫고 검색 인덱스와 pending queue를 계정 범위별로 분리한 뒤 새 계정 저장소를 연다. 이전 계정 데이터나 local-only 기록을 새 계정으로 자동 병합하지 않는다. local-only 기록을 처음 연결한 iCloud 계정으로 옮길 때는 대상과 결과를 설명하고 사용자의 명시적 확인을 받은 뒤 revision 단위로 복사한다.

초기 구현의 첫 기술 검증에서 실제 기기 두 대로 schema, 대량 import, background 수신, 외부 저장 첨부를 시험한다. SwiftData 자동 동기화가 이 계약을 충족하지 못하면 UI·도메인 protocol을 유지하고 `NSPersistentCloudKitContainer` 기반 Core Data adapter로 교체한다. 이 fallback은 저장소 경계 안에 제한한다.

CloudKit 호환성을 위해 데이터 모델은 다음 원칙을 따른다.

- 데이터베이스 unique constraint에 의존하지 않고 모든 모델에 앱이 관리하는 안정 UUID를 둔다.
- 관계의 존재와 처리 순서를 가정하지 않도록 연결은 optional relationship 또는 scalar UUID로 표현한다.
- Day One 원본 UUID 중복은 가져오기 사전 조회와 결정적 식별자로 방지한다.
- production에 배포된 CloudKit schema는 삭제·변경하지 않고 additive migration만 수행한다.

### 3. 동기화 모델과 로컬 보조 모델 분리

CloudKit에 동기화할 canonical 모델은 다음과 같다.

- `JournalEntry`: 안정 ID, 유형, 제목, 현재 본문, 기록 시각과 원본 시간대, 태그 이름, 즐겨찾기·고정, 유형별 상세 payload, source UUID, 수정 시각·기기 ID, 삭제 tombstone
- `EntryRevision`: entry ID, revision ID, 부모 revision, 전체 편집 snapshot, 작성 시각·기기 ID
- `Attachment`: 안정 ID, entry ID, 원본 이름, MIME, 체크섬, 외부 저장 binary, 수정 시각, 삭제 tombstone
- `ClassificationRule`: Day One 태그 또는 템플릿 식별자, 대상 유형, 우선순위, 수정 시각
- `RestoreEpoch`: replace 복원의 범위와 시각을 나타내는 동기화 marker

다음은 기기 로컬에만 저장한다.

- Mac의 `ImportJob`, `ImportItem`, 전체 Day One 원본 snapshot과 파일 지문
- 각 기기의 검색 FTS 인덱스와 마지막 색인 token
- 일시적 다운로드, 가져오기, 백업 staging 파일

원본 JSON 전체를 iPhone까지 동기화하면 저장량과 개인정보 노출 면적이 불필요하게 커진다. 정규화된 필드와 source UUID만 동기화하고 전체 snapshot은 Mac 로컬 백업에 포함한다.

사용자 노트북은 기록 유형을 대체하지 않는 별도 탐색 단위다. 초기 배포의 CloudKit schema를 파괴적으로 바꾸지 않도록 노트북 연결은 예약된 canonical 태그 표현으로 기록과 revision에 포함하고, 일반 태그 UI에서는 숨긴다. 사용자가 만든 노트북 이름 목록은 기기에 보관하되 다른 기기에서 해당 기록을 수신하면 예약 메타데이터에서 자동으로 복원한다. 한 기록은 한 사용자 노트북에 속할 수 있고 유형·일반 태그는 그대로 유지한다.

### 4. 버전 이력을 이용한 충돌 수렴

모든 저장은 현재 `JournalEntry`를 갱신하는 동시에 불변 `EntryRevision`을 추가한다. 서로 다른 기기에서 같은 base revision을 편집하면 `updatedAt`, 이어서 `deviceID`의 안정 순서로 현재 winner를 정하되 두 revision을 모두 보존한다. 사용자는 기록 이력에서 다른 revision을 확인하고 복원할 수 있다.

삭제는 즉시 물리 삭제하지 않고 `deletedAt` tombstone을 동기화한다. 삭제 이후 더 오래된 편집이 도착해도 기록을 부활시키지 않는다. 사용자가 명시적으로 복원하면 새 revision과 복원 시각을 기록해 tombstone보다 최신 의도로 전파한다. 정리 가능한 revision과 tombstone은 모든 알려진 기기가 충분히 동기화된 뒤 별도 보존 정책으로 처리하며 MVP에서는 자동 영구 삭제하지 않는다.

CloudKit 자체 conflict 결과에만 의존하는 대안은 마지막 저장 이외의 본문을 잃을 수 있어 일기 데이터에 적합하지 않다.

### 5. 첨부 파일은 CloudKit asset으로 동기화

첨부는 `Attachment` 모델의 외부 저장 binary로 보관해 CloudKit asset으로 동기화하고 본문 기록과 scalar entry ID로 연결한다. 체크섬으로 로컬 중복을 줄이되 CloudKit이 unique를 보장한다고 가정하지 않는다. iPhone은 목록을 먼저 표시하고 첨부가 로컬에 없으면 필요할 때 다운로드한다. 다운로드 전에는 placeholder, 진행률, 재시도를 제공한다.

첨부 오류는 본문을 차단하지 않는다. iCloud quota 또는 네트워크 오류가 나면 해당 첨부를 `pending` 또는 `failed` 상태로 두고 로컬 원본을 유지한다.

### 6. 샘플에 근거한 Day One export v1.0 parser

가져오기는 `ZIP 검증 → JSON 후보 검색 → manifest 분석 → 미리보기 → 사용자 분류 확인 → 항목별 실행 → 결과 보고` 단계로 구성한다. ZIP entry 이름은 URL decode 후 표시하되 특정 일기 이름에 의존하지 않고 안전한 `.json` 후보의 최상위 구조로 식별한다.

export v1.0 adapter는 다음 순서로 본문을 정규화한다.

1. `text`가 있으면 이를 canonical 본문으로 사용한다.
2. `text`가 없고 `richText`가 있으면 JSON 문자열을 한 번 더 parse해 텍스트 content를 복원한다.
3. `richText` parse에 실패해도 `text`가 있으면 항목을 가져오고 경고한다.
4. 원본 `richText`, template과 미지원 필드는 Mac의 source snapshot에 보존한다.

생성·수정 시각은 UTC instant와 `timeZone`을 함께 보존한다. 위치·날씨·즐겨찾기·고정 상태는 canonical 필드로 옮기고 생성 기기·OS·editing time·template 세부 정보는 source metadata로 보존한다. 태그가 없으면 템플릿 UUID·제목 규칙을 분류에 사용할 수 있고, 어느 규칙과도 일치하지 않으면 미분류로 둔다.

ZIP은 전체 해제하지 않고 entry별로 읽으며 경로 탈출, 압축 해제 총량, 파일 수, 파일별 크기와 압축률 제한을 적용한다. 제공된 개인 샘플은 repository fixture로 복사하지 않고 동일한 schema를 가진 익명 합성 ZIP을 만든다.

### 7. 가져오기는 Mac에서, 결과는 CloudKit으로 전파

분석 단계는 저장소를 변경하지 않는다. 실행 단계는 항목별 transaction 경계로 canonical entry와 local import audit를 함께 기록한다. Day One UUID가 이미 있으면 기존 entry를 덮어쓰지 않고 건너뛴다. 가져오기 직후 canonical entry는 일반 편집과 같은 CloudKit 동기화 대상이 되고 iPhone은 batch를 점진적으로 받는다.

대량 가져오기가 일상적인 iPhone 편집을 막지 않도록 batch 크기와 backpressure를 적용한다. Mac에서 가져오기가 끝났다는 사실과 iPhone에서 모든 항목이 도착했다는 사실을 구분해 상태를 표시한다.

### 8. 기기별 재구축 가능한 한국어 검색 인덱스

canonical 데이터는 SwiftData에 저장하고 검색 전용 SQLite FTS5 trigram 인덱스는 각 기기 로컬에 둔다. SwiftData history와 앱 저장 이벤트를 entry ID 기반 색인 queue로 변환한다. 원격 변경을 받거나 인덱스 version이 바뀌면 증분 갱신하고, token 불일치나 손상을 감지하면 canonical store에서 전체 재구축한다.

제목, 본문, 태그, 성경 구절, 책 제목·저자를 색인한다. FTS5 trigram을 사용할 수 없는 환경에서는 정규화된 포함 검색 fallback으로 기능을 유지한다. 검색 인덱스는 derived data이므로 CloudKit이나 백업에 포함하지 않는다.

### 9. 저장 엔진과 독립적인 전체 백업과 복원

Mac 앱은 canonical record와 revision을 JSON Lines, 첨부를 별도 파일, Mac 로컬 import snapshot을 선택 항목으로 담고 format version·schema version·체크섬 manifest를 포함한 ZIP을 만든다. SwiftData의 내부 SQLite 파일 자체는 백업하지 않는다.

복원은 임시 위치에서 ZIP 안전성, manifest, version, 체크섬을 모두 검증한 뒤 현재 상태의 안전 백업을 먼저 만든다.

- `merge`: 안정 ID가 없는 항목을 추가하고 기존 항목은 revision 비교 후 사용자에게 충돌을 보여 준다.
- `replace`: restore epoch을 만든 뒤 백업에 없는 현재 항목에는 tombstone을 생성하고, 백업 항목에는 새 restore revision을 생성한다.

이 방식은 복원 결과를 정상적인 CloudKit 변경으로 전파해 다른 기기도 같은 상태로 수렴시킨다. 복원이 실패하면 staging 데이터만 폐기하고 현재 canonical store를 유지한다.

### 10. 개인 정보와 운영 경계

CloudKit private database는 같은 시스템 iCloud 계정의 사용자 데이터에 사용하고 public/shared database는 사용하지 않는다. Sign in with Apple은 접근 인증에만 사용하며 이메일·이름을 수집하지 않고 identity token이나 기록을 자체 서버로 전송하지 않는다. 분석과 광고도 포함하지 않는다. 동기화를 활성화하면 데이터가 iCloud에 저장되고 사용자의 iCloud 용량을 사용한다는 사실과, 인증 후에는 iCloud 없이도 local-only로 사용할 수 있다는 사실을 onboarding에 명확히 알린다.

기기 로컬 파일은 OS data protection과 sandbox에 맡긴다. 별도 데이터 암호화 키와 암호화 백업은 후속 보안 변경으로 다룬다.

### 11. 기기별 선택적 앱 잠금

앱 잠금은 사용자 기록 화면에 대한 추가 접근 보호로 제공하고 기본값은 비활성으로 둔다. 사용자는 설정에서 6자 이상의 비밀번호를 만들고 잠금 시간을 즉시·1분·5분·15분 중 선택한다. 앱을 새로 실행하거나 선택한 시간이 지난 뒤 background에서 돌아오면 canonical 저장소 화면을 표시하기 전에 잠금 화면을 보여 준다.

비밀번호 원문은 저장하거나 CloudKit·백업·분석 로그에 포함하지 않는다. 무작위 salt와 의도적으로 느린 password derivation으로 만든 verifier만 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 수준의 Keychain 항목에 저장한다. verifier, 실패 횟수, 잠금 설정은 기기 로컬이며 다른 기기로 동기화하지 않는다. 사용자는 Mac과 iPhone에서 각각 잠금을 설정한다.

기기가 지원하고 사용자가 허용하면 `LocalAuthentication`의 Face ID·Touch ID를 빠른 잠금 해제로 제공하고 앱 비밀번호를 fallback으로 유지한다. 비밀번호 변경은 현재 비밀번호 확인 후 허용한다. 비밀번호를 잊은 경우에는 OS의 기기 소유자 인증을 통과한 뒤 새 비밀번호를 설정할 수 있게 하며 개발자가 복구용 비밀이나 사용자 비밀번호를 보유하지 않는다.

실패한 비밀번호 입력은 누적 횟수에 따라 재시도 시간을 늘리고 앱 재실행으로 지연을 우회할 수 없게 기기 로컬 보안 상태에 기록한다. 앱이 background로 이동하거나 잠긴 동안에는 scene과 app switcher snapshot 위에 불투명한 privacy shield를 표시해 제목·본문·검색 결과가 노출되지 않게 한다.

이 기능은 앱 UI 접근을 막는 privacy lock이며 journal database와 CloudKit record를 비밀번호로 종단 간 암호화하지 않는다. 설정과 개인정보 안내에서 이 경계를 명시해 사용자가 기기 암호화 이상의 보호로 오해하지 않게 한다.

## Risks / Trade-offs

- [SwiftData와 CloudKit schema 제약으로 모델이 동기화되지 않을 수 있음] → 첫 구현 단계에서 두 실제 기기 spike를 완료하고 production schema 승격 전에 모든 관계·첨부·삭제 시나리오를 검증하며 실패 시 Core Data adapter로 전환한다.
- [CloudKit은 즉시 동기화 완료를 보장하지 않음] → 로컬 성공과 원격 수렴 상태를 구분하고 마지막 관찰 변경, 계정 상태, pending attachment를 사용자에게 표시한다.
- [동시 편집에서 한 본문이 현재 값에서 밀릴 수 있음] → 모든 저장을 불변 revision으로 남기고 결정적 winner와 이력 복원을 제공한다.
- [대량 Day One 가져오기가 CloudKit queue와 iPhone 저장 공간을 압박할 수 있음] → batch, backpressure, 첨부 지연 다운로드와 건수 기반 진행 상태를 적용한다.
- [사용자의 iCloud 계정 부재·용량 부족·일시 오류] → 로컬 기록을 유지하고 재시도 가능한 동기화 오류를 표시하며 백업 내보내기 경로를 제공한다.
- [iCloud 로그아웃·계정 교체 시 다른 사용자의 로컬 replica가 노출되거나 섞일 수 있음] → 계정 변경을 저장소 경계로 처리하고 persistent store·검색 인덱스·queue를 계정별로 격리하며 자동 병합을 금지한다.
- [Apple 로그인 사용자와 시스템 iCloud 계정이 다르거나 같은 설치에서 사용자가 바뀔 수 있음] → 인증과 동기화 상태를 분리하고 기존 데이터는 최초 사용자에게 귀속하며 다른 식별자에는 저장소 격리 전까지 접근을 차단한다.
- [약한 앱 비밀번호가 추측되거나 반복 시도로 노출될 수 있음] → 최소 길이, 무작위 salt, 느린 derivation, Keychain 기기 전용 저장과 증가형 재시도 지연을 적용한다.
- [앱 잠금이 데이터 자체 암호화로 오해될 수 있음] → 설정·onboarding·privacy 문서에 UI 접근 보호 범위와 OS data protection·CloudKit 저장 경계를 명확히 설명한다.
- [실제 Day One export 변형을 놓칠 수 있음] → 제공 샘플 schema를 익명 fixture로 재현하고 버전·선택 필드·태그·미디어 fixture를 추가하며 미지원 필드는 원본 snapshot에 보존한다.
- [샘플에 첨부와 태그가 없어 실제 참조 형식을 확인하지 못함] → 합성 fixture로 계약을 먼저 구현하고 해당 데이터가 있는 추가 익명 샘플이 생기면 regression fixture를 보강한다.
- [로컬 FTS 인덱스가 canonical store와 어긋날 수 있음] → history token, version 검사와 전체 재색인 경로를 제공한다.
- [CloudKit production schema는 파괴적 변경이 어려움] → 공개 전 migration rehearsal과 schema snapshot review를 필수 release gate로 둔다.

## Migration Plan

1. Xcode SwiftUI 멀티플랫폼 project와 공유 domain package를 만든다.
2. 최소 지원 버전을 iOS 17·macOS 14로 시작하고 두 타깃에 Sign in with Apple capability를 설정해 실제 대상 기기에서 로그인·철회·오프라인 재실행을 확인한다.
3. 작은 CloudKit 호환 schema로 Mac·iPhone 간 생성, 수정, 충돌, 삭제, 첨부의 기술 spike를 통과한다.
4. production schema 승격 전 전체 canonical 모델과 migration test를 확정한다.
5. 제공 Day One v1.0 구조를 재현한 익명 fixture로 Mac 가져오기와 중복 방지를 검증한다.
6. 사용자가 실제 ZIP을 Mac에서 분석·가져오고 결과 보고서를 확인한다.
7. iPhone에서 가져온 기록 수렴, 오프라인 편집, 첨부 다운로드와 검색 재색인을 확인한다.
8. 첫 사용 데이터의 전체 백업을 생성하고 복원 rehearsal을 거친 뒤 정식 배포한다.

첫 출시는 기존 앱 데이터가 없으므로 앱 내부 schema migration은 없다. CloudKit spike 실패 시 production container를 승격하지 않고 Core Data adapter로 교체한다. 가져오기 실패는 같은 파일을 안전하게 다시 실행할 수 있고, 복원 실패는 기존 데이터를 유지한다.

## Open Questions

- 실제 사용할 iPhone의 OS가 iOS 17 이상인지 확인한다. 더 낮은 버전이 필요하면 SwiftData 선택을 재검토해야 한다.
- CloudKit 기기 간 시험과 배포를 위해 사용할 Apple Developer Program team과 iCloud container identifier를 구현 시작 시 확정한다.
- 사진·영상·오디오와 Day One 태그가 포함된 익명 샘플이 확보되면 실제 필드명을 합성 fixture와 비교한다.
- 암호화 백업, 앱 자체 종단 간 암호화와 iCloud 외 별도 내보내기 자동화 중 다음 보안·운영 우선순위는 MVP 사용 후 결정한다.
