# 개발 및 배포 구성

## 식별자

- 제품명: Pilgrim Journal
- 권장 bundle identifier: `com.example.PilgrimJournal`
- 권장 CloudKit container: `iCloud.com.example.PilgrimJournal`

실제 배포 전 `example` 부분을 소유한 reverse-DNS identifier로 교체한다.

## Xcode capability

iOS와 macOS target 모두에 다음 capability가 필요하다.

1. iCloud
   - CloudKit 활성화
   - 동일한 private container 선택
2. Background Modes
   - Remote notifications 활성화

iOS target의 `Info.plist`에는 Face ID 앱 잠금 설명을 추가한다.

- `NSFaceIDUsageDescription`: `개인 일기 기록의 앱 잠금을 해제하기 위해 Face ID를 사용합니다.`

CloudKit production schema는 additive-only 정책으로 관리한다. 개발 container에서
생성·수정·동시 편집·삭제 tombstone·첨부·복원을 실제 Mac과 iPhone으로 검증한
뒤에만 production으로 승격한다.

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
