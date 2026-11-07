# 개인정보 처리 경계

- 기록은 기기 로컬 저장소와 사용자의 CloudKit 개인 데이터베이스에만 저장한다.
  사용자가 직접 공유한 노트북·기록만 예외다(아래).
- 노트북 이름 목록(삭제한 이름 포함), 유형 카탈로그, 기도 템플릿은 기기 간 공유를
  위해 iCloud 키-값 저장소에도 둔다. 기록 본문은 여기에 넣지 않는다.
- public CloudKit database, 광고, 분석 SDK와 자체 기록 서버를 사용하지 않는다.
- 공유는 사용자가 노트북이나 기록 하나를 골라 **공유…**로 초대한 iCloud 사용자에게만
  한다(CKShare, `share.publicPermission = .none`). 공유한 것은 소유자 개인
  데이터베이스의 `pilgrim-share-<uuid>` zone으로 옮겨지고, 초대받은 사람은 자기 shared
  database로 받는다. 제목·본문·태그·유형별 내용·이력은 `encryptedValues`로 종단 간
  암호화하고, Day One 원본 필드는 공유 record에 넣지 않는다. 사진이 든 기록은 아직
  공유할 수 없다. 공유를 끝내면 zone을 지워 모두의 서버 사본이 사라진다.
- CloudKit 동기화 데이터는 사용자의 iCloud 용량을 사용한다.
- 개발자 관리 콘솔(`web/admin`)은 스키마·패키지 구조·저장소 문서만 보여 주며 사용자 기록,
  Apple 로그인 식별자, 이메일, iCloud 정보를 받거나 저장하지 않는다. 콘솔이 저장하는 것은
  관리자 계정 해시와 세션뿐이다.
- 개인 Day One ZIP과 원문은 source control, test snapshot, test log에 넣지 않는다.
- 실제 샘플 검증 출력은 export version, 항목 수와 구조 경고 수로 제한한다.
- 검색 인덱스와 전체 Day One source snapshot은 기기 로컬 데이터다.
- 이메일·비밀번호 회원가입 없이 `Sign in with Apple`로 앱 접근을 인증한다.
  이름 scope는 요청하지 않는다. 현재 계정 표시를 위해 email scope를 요청하며,
  Apple이 준 이메일(가림 처리된 주소일 수 있음)은 opaque 사용자 식별자·마지막
  승인 상태와 함께 기기별 `ThisDeviceOnly` Keychain에만 저장하고 CloudKit에는
  올리지 않는다.
- Apple 로그인은 앱 접근용이며 동기화 계정을 대체하지 않는다. 기록 동기화는
  기기에 로그인된 시스템 iCloud 계정의 private database를 사용하고, 인증을
  완료한 사용자는 iCloud를 사용할 수 없어도 local-only로 계속 동작한다.
- 최초 iCloud 연결 시 private database에 Apple 로그인의 opaque 사용자 식별자를
  앱 범위에서 단방향 해시한 연결 값만 저장한다. 같은 iCloud 저장 공간을 다른
  Apple 로그인 사용자가 열면 기록 화면을 차단하며 원본 식별자·이메일·이름은
  CloudKit에 저장하지 않는다.
- 로그아웃과 권한 철회는 인증 session만 제거하고 기록을 자동 삭제하지 않는다.
  기존 로컬 기록은 이 설치에서 최초로 로그인한 Apple 사용자에게 귀속하며 다른
  사용자 식별자에는 노출하거나 자동 병합하지 않는다.
- 데이터 삭제는 아래 "계정 삭제" 절의 명시적인 앱 내 흐름으로만 일어난다.
- 선택적 앱 잠금 비밀번호 원문은 저장하지 않는다. salt와 느린 derivation을
  적용한 verifier 및 실패 상태만 각 기기의 `ThisDeviceOnly` Keychain에 저장하며
  CloudKit과 앱 백업으로 동기화하지 않는다.
- 앱 잠금은 화면 접근을 보호하는 기능이다. journal database와 CloudKit record를
  앱 비밀번호로 종단 간 암호화하는 기능은 아니다.

## 계정 삭제

App Store 심사 지침 5.1.1(v)에 따라 앱 안에서 계정을 삭제할 수 있다. 경로는
설정 › Apple 로그인 › 계정 삭제이며, 구현은 `AccountDeletionService`
(`Sources/JournalData/AccountDeletionService.swift`)다.

삭제 순서와 범위:

1. 열린 저장소를 먼저 닫는다. 열린 CloudKit mirroring이 지워진 zone을 다시
   만들고 기록을 다시 올리지 못하게 하기 위해서다.
2. 현재 시스템 iCloud가 연결되어 있으면 iCloud에서 지운다(`CloudKitAccountDataEraser`).
   binding이 다른 Apple 사용자 것이면 아무것도 지우지 않는다.
   1. 기본 zone의 binding record(`pilgrim-journal-apple-user-binding-v1`)를 지운다.
   2. 다른 가족이 공유해 이 사용자가 받은 공간에서 나간다: shared database의
      `pilgrim-share-*` zone마다 zone 전체 share를 지운다. 소유자의 사본은 남고 이
      사용자만 참여자에서 빠진다.
   3. 개인 데이터베이스의 기본 zone 밖 zone을 모두 지운다: 기록의
      `com.apple.coredata.cloudkit*` zone과 이 사용자가 공유한 `pilgrim-share-*` zone.
      공유한 zone을 지우면 share도 함께 지워져 함께 보던 가족에게서도 사라진다
      (삭제 확인 화면에서 알린다).

   어느 하나라도 실패하면 — CloudKit이 zone·share를 하나씩 결과로 돌려주므로, 요청은
   성공했지만 일부만 지워진 경우도 포함한다(`CloudKitWipeError`) — 로컬 데이터는
   건드리지 않고 남은 개수와 원인을 담은 오류로 다시 시도하게 한다. 다시 시도하면 모든
   단계를 처음부터 반복하고, 이미 지워진 zone·share는 성공으로 친다. 공유 나가기를
   zone 삭제보다 먼저 하는 이유: 나가기는 남의 사본에 대한 접근만 끊으므로, 거기서
   실패해도 이 사용자의 기록과 공유한 노트북은 iCloud에 그대로 있다. 반대로 공유한
   zone이 지워진 뒤 실패해 앱을 다시 열면 그 공간의 로컬 캐시도 동기화로 지워진다.
3. 이 Apple 사용자의 로컬 파일을 지운다: `Accounts/<appleUserHash>/` 전체(모든
   저장 범위, 첨부, 검색 인덱스, staging), `AccountScopes/<appleUserHash>/`,
   이 사용자가 claim한 경우에만 legacy 저장소(`Canonical.store`,
   `LocalAuxiliary.store`, `journal-local.json`)와 `legacy-claim.json`,
   `tmp/AttachmentPreview/`. 같은 기기의 다른 Apple 사용자 데이터는 남긴다.
4. 이 사용자의 저장 범위별 UserDefaults suite를 지우고, iCloud 범위였다면 iCloud
   키-값 저장소의 키 네 개를 지운다: 노트북 목록(`journal-notebooks`), 삭제한 노트북
   목록(`journal-deleted-notebooks`), 유형 카탈로그(`journal-kind-catalog`), 기도
   템플릿(`journal-prayer-templates`).
5. 마지막으로 Keychain의 Apple 로그인 session(귀속 사용자와 이메일 포함)과 앱 잠금
   항목을 지우고, 첫 실행 안내를 다시 보이도록 되돌린 뒤 로그인 화면으로 돌아간다.

Apple 토큰 revoke를 하지 않는 이유: Sign in with Apple REST API의 토큰 폐기는
개발자 비밀 키로 서명한 client secret이 필요하고, 그 키는 앱에 넣을 수 없어 서버가
있어야 한다. 이 앱은 자체 서버를 두지 않는다(위 경계). 앱은 identity token을
서버로 보내거나 저장하지 않으므로 폐기할 서버 측 session도 없다. 대신 삭제 후
화면과 지원 페이지에서 "설정 › Apple 계정 › Apple로 로그인 › Pilgrim › 사용 중단"으로
Apple 측 연결을 끊는 방법을 안내한다.

알려진 한계: 다른 기기에 남은 로컬 사본은 그 기기에서 앱을 다시 열면 iCloud에
다시 올라갈 수 있다. 삭제 확인 화면에서 다른 기기의 앱을 먼저 지우라고 안내하며,
다른 기기가 스스로 지우게 하는 삭제 표시 record는 후속 과제다
(`docs/implementation-todo.md`). iCloud에 연결되지 않은 상태에서 삭제하면 이 기기
데이터만 지워지며 화면에서 그 사실을 알린다. 이때는 공유한 zone과 받은 공유도
iCloud에 남는다. 공유는 다른 사람의 데이터베이스와 맞닿아 있어 두 가지는 지우지
않는다: 가족이 이 사용자의 공간에서 나가며 자기 기록에 남긴 사본, 그리고 이 사용자가
남이 공유한 노트북에 써 넣은 기록(그 노트북 소유자의 개인 데이터베이스에 있다). 둘 다
그 가족의 데이터로 보고, 이 사용자는 참여자에서 빠지는 것으로 끝난다.
