## 1. Apple 멀티플랫폼 프로젝트 기반

- [x] 1.1 Xcode SwiftUI Multiplatform 앱을 생성하고 iPhone·macOS 지원 destination과 최소 iOS 17·macOS 14를 구성한다
- [x] 1.2 공유 domain·data·import·search 모듈과 플랫폼별 app scene 경계를 Swift package로 구성한다
- [x] 1.3 Swift Testing 또는 XCTest 단위·통합·UI test target과 lint·build 검증 명령을 구성한다
- [x] 1.4 개발용 Apple team, bundle identifier, iCloud container identifier와 Debug·Release signing 구성을 문서화한다
- [x] 1.5 iOS·macOS target에 iCloud CloudKit과 Background Modes remote notification capability를 설정한다
- [x] 1.6 공통 오류, 기록 유형, 동기화 상태와 플랫폼별 file·menu service protocol을 정의한다
- [x] 1.7 로컬 실행 가능한 기본 앱 shell과 다섯 유형·미분류·검색·설정 navigation을 두 플랫폼에 구현한다

## 2. SwiftData·CloudKit 기술 검증

- [x] 2.1 안정 UUID, optional/scalar 연결, 수정 시각과 device ID를 사용하는 최소 SwiftData CloudKit 호환 schema를 만든다
- [ ] 2.2 Mac과 iPhone 실제 기기에서 같은 iCloud 계정으로 생성·수정·background 수신 왕복 spike를 수행한다
- [ ] 2.3 두 기기 오프라인 동시 편집, tombstone 삭제와 명시적 복원 수렴을 spike에서 검증한다
- [ ] 2.4 외부 저장 binary 첨부의 CloudKit asset 업로드·지연 다운로드·용량 오류를 spike에서 검증한다
- [ ] 2.5 대량 합성 기록 batch를 넣어 CloudKit queue, 메모리와 수렴 시간을 측정한다
- [ ] 2.6 spike 결과로 SwiftData go/no-go를 기록하고 실패 시 동일 저장소 protocol의 NSPersistentCloudKitContainer adapter로 전환한다
- [ ] 2.7 선택한 저장 adapter의 개발 schema를 초기화하고 production 승격 전 schema snapshot 검토 절차를 만든다

## 3. Canonical 데이터와 로컬 보조 저장소

- [x] 3.1 JournalEntry, EntryRevision, Attachment, ClassificationRule, RestoreEpoch canonical 모델과 migration version을 구현한다
- [x] 3.2 Day One source UUID, 안정 entry ID와 CloudKit unique constraint 없이 동작하는 application-level 중복 검사를 구현한다
- [x] 3.3 Mac 전용 ImportJob, ImportItem, source snapshot과 파일 지문 로컬 저장소를 구현한다
- [x] 3.4 검색 history token과 indexing queue를 위한 기기 로컬 상태 저장소를 구현한다
- [x] 3.5 앱 data·첨부 cache·임시 import·backup staging directory 해석과 sandbox 권한 오류 처리를 구현한다
- [x] 3.6 임시 local container와 in-memory CloudKit 대체물을 사용하는 저장소 단위 테스트 기반을 만든다
- [x] 3.7 canonical 모델의 encode/decode, schema migration과 source snapshot 비동기화를 테스트한다

## 4. Revision, 충돌과 동기화 상태

- [x] 4.1 모든 기록 저장에서 현재 JournalEntry와 불변 EntryRevision을 함께 생성하는 저장 명령을 구현한다
- [x] 4.2 updatedAt과 deviceID 안정 순서로 concurrent revision winner를 선택하는 resolver를 구현한다
- [x] 4.3 losing revision 조회와 이전 revision을 새 revision으로 복원하는 명령을 구현한다
- [x] 4.4 삭제 tombstone, 오래된 편집의 비부활과 명시적 복원 revision을 구현한다
- [x] 4.5 iCloud account 상태, local saved, pending, synced, retryable error를 구분하는 상태 model을 구현한다
- [x] 4.6 CloudKit remote change를 canonical UI와 search indexing queue에 전달하는 observer를 구현한다
- [x] 4.7 서로 다른 기록 편집, 같은 기록 동시 편집, 삭제·오래된 기기 연결과 복원 통합 테스트를 추가한다
- [ ] 4.8 Mac과 iPhone 실제 기기에서 비행기 모드 전환을 포함한 오프라인 수렴 시나리오를 검증한다
- [x] 4.9 `CKContainer.accountStatus`와 계정 변경 알림을 관찰해 Apple 접근 인증과 별개로 시스템 iCloud 사용 가능 상태와 local-only fallback을 전환한다
- [x] 4.10 iCloud 계정별 persistent store·검색 인덱스·pending queue를 격리하고 local-only 기록의 명시적 이전 use case를 구현한다

## 5. 기록 작성과 플랫폼 UI

- [x] 5.1 다섯 유형의 기록 생성·조회·수정과 공통 필드 검증 use case를 구현한다
- [x] 5.2 기도 상태·응답일, 성경 구절, 책 제목·저자, 일기 기분의 유형별 payload와 검증을 구현한다
- [x] 5.3 유형 변경 시 제거될 상세 정보를 미리 보여 주고 확인 후 새 revision으로 변환하는 명령을 구현한다
- [x] 5.4 Markdown 또는 plain text 본문, 날짜, 태그, 첨부와 유형별 입력을 제공하는 공유 편집 화면을 구현한다
- [x] 5.5 iPhone touch·navigation과 macOS window·menu·keyboard shortcut에 맞는 플랫폼별 편집 interaction을 구현한다
- [x] 5.6 저장하지 않은 이탈, 저장 오류, 유형 변경과 revision 이력·복원 UI를 구현한다
- [x] 5.7 휴지통 목록, 삭제와 복원 UI를 두 플랫폼에 구현한다
- [x] 5.8 다섯 유형 생성·편집·유형 변경·revision·휴지통의 단위 및 UI 테스트를 추가한다

## 6. 분류와 정리

- [x] 6.1 유형·미분류별 최신순 목록 조회와 cursor 기반 page query를 구현한다
- [x] 6.2 Day One 태그·템플릿 UUID·템플릿 제목 분류 규칙 CRUD와 우선순위 평가를 구현한다
- [x] 6.3 동일 우선순위 충돌 시 미분류를 반환하고 명시적 항목 선택이 규칙보다 우선하는 계획 model을 구현한다
- [x] 6.4 선택 기록의 유형 변경과 태그 추가를 revision 단위로 처리하는 batch use case를 구현한다
- [x] 6.5 유형별 timeline, 미분류 보관함, 다중 선택과 일괄 정리 화면을 두 플랫폼에 구현한다
- [x] 6.6 태그 이름 변경·제거와 분류 규칙 관리 화면을 구현한다
- [x] 6.7 분류 규칙을 CloudKit으로 동기화하고 동시 규칙 편집을 결정적으로 수렴시킨다
- [x] 6.8 태그·템플릿 규칙, 충돌, 개별 예외, batch와 규칙 동기화 회귀 테스트를 추가한다
- [x] 6.9 사용자 노트북 추가·사이드바 탐색·기록 연결과 일반 태그 분리를 구현하고 테스트한다

## 7. Day One v1.0 분석과 미리보기

- [x] 7.1 제공 샘플의 metadata·entries·필드 type과 URL 인코딩 filename 구조를 재현한 익명 합성 ZIP fixture를 만든다
- [x] 7.2 태그, 사진·영상·오디오, 누락 선택 필드와 형식 오류를 포함한 추가 합성 fixture를 만든다
- [x] 7.3 ZIP entry 경로 검증, 파일 수·크기·압축률 제한과 전체 해제 없는 stream reader를 구현한다
- [x] 7.4 특정 filename에 의존하지 않고 안전한 JSON 후보의 metadata.version과 entries 구조를 식별하는 detector를 구현한다
- [x] 7.5 text 우선, richText 이중 JSON parse fallback과 parse 경고를 구현한다
- [x] 7.6 시각·timeZone, location, weather, starred, isPinned, template과 기기 metadata adapter를 구현한다
- [x] 7.7 파일 지문, source UUID 중복, 누락 첨부, 날짜 범위와 선택 필드 수를 계산하는 read-only analyzer를 구현한다
- [x] 7.8 분석 결과에 태그·템플릿 분류 규칙과 개별 예외를 적용하는 preview use case를 구현한다
- [x] 7.9 macOS fileImporter, 분석 진행률, 요약, 경고와 분류 수정을 제공하는 가져오기 preview UI를 구현한다
- [x] 7.10 제공 개인 샘플이 repository·test log·snapshot에 복사되거나 본문 출력되지 않는 privacy regression check를 추가한다
- [x] 7.11 잘못된 ZIP, 암호화 ZIP, path traversal, 크기 제한, 이중 JSON과 분석 중 canonical 무변경 test를 추가한다
- [x] 7.12 Day One 미리보기의 다중 선택·전체 선택과 선택 항목 노트북 일괄 지정을 구현하고 테스트한다

## 8. Day One 가져오기 실행과 동기화

- [x] 8.1 항목별 transaction으로 canonical entry·revision과 Mac local import audit·source snapshot을 저장하는 executor를 구현한다
- [x] 8.2 Day One 첨부를 local attachment store로 복사하고 누락·손상을 항목 경고로 격리한다
- [x] 8.3 source UUID 중복 건너뛰기, 일부 완료 후 재실행과 기존 사용자 편집 비덮어쓰기를 구현한다
- [x] 8.4 안전한 항목 경계 취소, batch backpressure와 가져오기 진행률 event를 구현한다
- [x] 8.5 성공·건너뜀·실패·경고·미분류 항목을 탐색하는 macOS 결과 report UI를 구현한다
- [x] 8.6 Mac 로컬 가져오기 완료와 CloudKit·iPhone 수렴 상태를 구분해 표시한다
- [x] 8.7 정상, 부분 손상, 누락 첨부, 취소, 동일 파일과 일부 완료 재실행 통합 테스트를 추가한다
- [ ] 8.8 익명 합성 Day One batch를 Mac에서 가져와 iPhone에 수렴하는 실제 기기 E2E 테스트를 수행한다
- [ ] 8.9 태그·첨부가 포함된 추가 익명 실제 샘플이 확보되면 adapter compatibility regression을 보강한다

## 9. 첨부 파일 lifecycle

- [x] 9.1 체크섬, MIME, 원본 이름과 entry ID를 가진 attachment 저장·연결 use case를 구현한다
- [x] 9.2 외부 저장 binary를 CloudKit asset으로 올리고 local pending·uploaded·failed 상태를 관리한다
- [x] 9.3 iPhone에서 attachment metadata를 먼저 표시하고 요청 시 binary를 내려받는 lazy loader를 구현한다
- [x] 9.4 attachment placeholder, 진행률, 재시도와 본문 독립 오류 UI를 구현한다
- [x] 9.5 local 체크섬 deduplication과 reference가 남은 binary의 비삭제를 구현한다
- [x] 9.6 업로드·다운로드 실패, iCloud quota, 동일 checksum과 삭제 tombstone 통합 테스트를 추가한다

## 10. 검색과 타임라인

- [x] 10.1 Apple 플랫폼용 SQLite FTS5 wrapper를 선택하고 의존성·license·trigram 지원을 기록한다
- [x] 10.2 제목·본문·태그·유형별 상세 필드를 포함하는 기기 로컬 FTS5 trigram index와 fallback을 구현한다
- [x] 10.3 local save와 CloudKit remote history를 entry ID 기반 indexing queue로 반영한다
- [x] 10.4 검색어, 유형, 태그, 원래 현지 시작일·종료일을 결합한 search query를 구현한다
- [x] 10.5 검색 입력, filter, result, empty state와 조건 초기화 UI를 두 플랫폼에 구현한다
- [x] 10.6 index version·history token 불일치와 손상 시 canonical store에서 전체 재구축하는 경로를 구현한다
- [x] 10.7 한국어 부분 검색, remote change, 복합 filter, 날짜 경계와 휴지통 제외 테스트를 추가한다
- [ ] 10.8 수천 건 합성 데이터로 Mac·iPhone 검색·pagination 응답성과 index rebuild를 검증한다

## 11. 백업, 복원과 무결성

- [x] 11.1 JSON Lines canonical record·revision과 첨부를 위한 backup format·schema version·manifest 계약을 정의한다
- [x] 11.2 source snapshot 포함 여부를 선택하고 임시 ZIP 완성 후 이동하는 macOS backup exporter를 구현한다
- [x] 11.3 ZIP 안전성, format version, record schema와 모든 file checksum을 staging에서 검증하는 restore reader를 구현한다
- [x] 11.4 안정 ID 신규 항목 추가와 revision conflict preview를 제공하는 merge restore를 구현한다
- [x] 11.5 현재 안전 backup, RestoreEpoch, 누락 항목 tombstone과 restore revision을 사용하는 replace restore를 구현한다
- [x] 11.6 restore batch 실패 시 기존 상태 유지, 재시도와 안전 backup 복귀 경로를 구현한다
- [x] 11.7 backup·merge·replace 확인, 진행률, conflict와 오류를 제공하는 macOS 설정 UI를 구현한다
- [x] 11.8 canonical 참조, revision, attachment와 search token을 자동 삭제 없이 검사하는 integrity report를 구현한다
- [x] 11.9 backup 왕복, 손상 checksum, 비호환 version, merge conflict, replace 수렴과 rollback 통합 테스트를 추가한다
- [ ] 11.10 Mac replace 복원 결과가 오래 오프라인이던 iPhone 연결 후에도 유지되는 실제 기기 E2E 테스트를 수행한다

## 12. 개인정보, 접근성 및 출시 검증

- [x] 12.1 Apple 로그인 접근 인증, 시스템 iCloud 저장·용량 사용, 인증 후 local-only 상태, 자체 server 미사용과 앱 잠금의 UI 보호 범위를 설명하는 onboarding·privacy 안내를 작성한다
- [ ] 12.2 시스템 iCloud account 변경·로그아웃·재로그인에서 이전 계정·새 계정·local-only 데이터와 검색 인덱스가 섞이지 않는지 검증한다
- [ ] 12.3 VoiceOver, Dynamic Type, keyboard navigation, contrast, 긴 한국어 본문과 작은 Mac window를 점검한다
- [ ] 12.4 Mac·iPhone 오프라인 기록, 동기화, 가져오기, 첨부, 검색, backup·restore 전체 E2E를 실행한다
- [x] 12.5 대량 Day One ZIP의 memory·disk 한도, 진행률, 취소와 temporary file 정리를 성능 테스트한다
- [x] 12.6 Day One JSON ZIP 만드는 법, 첫 Mac 가져오기, iPhone 동기화, 오류와 backup·restore 사용자 문서를 작성한다
- [ ] 12.7 production CloudKit schema 승격 전 additive migration rehearsal과 schema snapshot review를 완료한다
- [ ] 12.8 macOS·iOS archive를 만들고 TestFlight 또는 등록 기기에서 설치·업데이트·데이터 보존을 smoke test한다

## 13. 기기별 앱 잠금

- [x] 13.1 6자 이상 비밀번호의 salt·느린 derivation verifier, 실패 상태와 잠금 설정을 `ThisDeviceOnly` Keychain에 저장하는 service를 구현한다
- [x] 13.2 앱 실행과 scene phase 전환에서 즉시·1분·5분·15분 유예 시간을 적용하는 lock coordinator를 구현한다
- [x] 13.3 비밀번호 생성·확인·변경과 Face ID·Touch ID 우선 해제·비밀번호 fallback 잠금 화면을 두 플랫폼에 구현한다
- [x] 13.4 background·잠금 중 scene과 app switcher snapshot의 기록 제목·본문·검색 결과를 가리는 privacy shield를 구현한다
- [x] 13.5 반복 실패의 증가형 재시도 제한과 OS 기기 소유자 인증을 사용하는 비밀번호 재설정 흐름을 구현한다
- [x] 13.6 Keychain 비동기화, 비밀번호 원문 비저장, 재실행 우회 방지, 생체 인증 fallback, 유예 시간과 Mac·iPhone 기기별 설정을 테스트한다

## 14. Sign in with Apple 접근 인증

- [x] 14.1 iOS·macOS target에 Sign in with Apple entitlement와 capability 설정을 추가하고 Developer Team 설정 절차를 문서화한다
- [x] 14.2 opaque Apple 사용자 식별자와 마지막 승인 상태를 기기 Keychain에 저장하는 인증 session service를 구현한다
- [x] 14.3 credential state 시작 검사, 일시 오류의 오프라인 fallback과 credential revoked notification을 처리하는 인증 coordinator를 구현한다
- [x] 14.4 이름 scope 없이 계정 표시용 이메일 scope를 요청하는 네이티브 Apple 로그인 버튼을 제공하고 인증 전 journal UI를 가리는 공통 로그인 화면을 구현한다
- [x] 14.5 설정의 로그아웃 확인과 session 제거 후 로그인 화면 복귀를 구현한다
- [x] 14.6 기존 로컬 데이터를 최초 Apple 사용자에게 귀속하고 다른 식별자의 데이터 접근·자동 병합을 차단한다
- [x] 14.7 로그인 성공·재실행·취소·실패·철회·오프라인·로그아웃·다른 사용자 차단 단위 및 UI 테스트를 추가한다
- [ ] 14.8 Apple Developer Team으로 서명한 Mac과 iPhone 실제 기기에서 첫 로그인·재로그인·권한 철회·업데이트 데이터 보존을 검증한다
- [x] 14.9 CloudKit private database를 Apple 로그인 사용자 해시에 귀속하고 불일치 접근 차단·local-only fallback을 테스트한다
