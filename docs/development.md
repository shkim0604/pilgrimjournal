# 개발 및 배포 구성

## 식별자

- 제품명: Pilgrim Journal
- bundle identifier: `com.dhouse.PilgrimJournal`
- CloudKit container: `iCloud.com.dhouse.PilgrimJournal`

## Xcode capability

iOS와 macOS target 모두에 다음 capability가 필요하다.

1. Sign in with Apple
   - Xcode의 Signing & Capabilities에서 두 플랫폼 target에 추가
   - iOS와 macOS App ID를 Apple Developer의 같은 primary App ID 그룹으로 구성
   - 실제 기기에서는 Two-Factor Authentication이 활성화된 Apple 계정 사용
2. iCloud
   - CloudKit 활성화
   - 동일한 private container 선택
3. Background Modes
   - Remote notifications 활성화

저장소의 `PilgrimJournal.entitlements`에는 Sign in with Apple, CloudKit private
container와 iCloud key-value store entitlement가 포함되어 있다. 실제 로그인과
CloudKit은 소유한 Apple Developer Team과 provisioning profile로 서명해야 하며
`CODE_SIGNING_ALLOWED=NO` 빌드는 UI·컴파일 검증만 가능하다.

CloudKit private database의 고정 account-binding record에는 Apple 로그인의 opaque
사용자 식별자를 앱 범위에서 SHA-256한 값만 저장한다. 같은 private database를 다른
Apple 로그인 사용자가 열면 journal UI를 차단한다. Apple은 로그인 계정과 시스템
iCloud 계정의 이메일을 앱에 제공하지 않으므로 최초 연결은 현재 iCloud private
database를 현재 Apple 로그인 사용자에게 귀속시키는 동작이다.

iOS target의 `Info.plist`에는 Face ID 앱 잠금 설명을 추가한다.

- `NSFaceIDUsageDescription`: `개인 일기 기록의 앱 잠금을 해제하기 위해 Face ID를 사용합니다.`

CloudKit production schema는 additive-only 정책으로 관리한다. 개발 container에서
생성·수정·동시 편집·삭제 tombstone·첨부·복원을 실제 Mac과 iPhone으로 검증한
뒤에만 production으로 승격한다.

앱은 `NSPersistentCloudKitContainer.eventChangedNotification`의 setup·import·export
이벤트를 관찰한다. 진행 중에는 동기화 대기로 표시하고, export/import 완료 시
완료 시각을 갱신한다. Remote import가 완료되면 canonical 목록과 로컬 검색 색인을
새로고침하며 실패 이벤트는 재시도 가능한 오류로 표시한다. 이 이벤트 처리는
자동화 테스트 대상이지만, 실제 두 기기의 네트워크 수렴은 아래 실제 기기 관문을
별도로 통과해야 한다.

## 저장 adapter 관문

초기 adapter는 SwiftData를 사용한다. 실제 기기 spike에서 다음 조건을 모두
통과해야 한다.

- 같은 계정의 두 기기에서 background 수렴
- 오프라인 동시 편집 revision 보존
- 삭제 tombstone과 명시적 복원
- 외부 저장 첨부 업로드와 지연 다운로드
- 대량 Day One import 후 앱 응답성 유지

하나라도 충족하지 못하면 도메인 protocol은 유지하고
`NSPersistentCloudKitContainer` adapter로 교체한다.
