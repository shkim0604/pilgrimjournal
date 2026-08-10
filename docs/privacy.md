# 개인정보 처리 경계

- 기록은 기기 로컬 저장소와 사용자의 CloudKit 개인 데이터베이스에만 저장한다.
- public/shared CloudKit database, 광고, 분석 SDK와 자체 기록 서버를 사용하지 않는다.
- CloudKit 동기화 데이터는 사용자의 iCloud 용량을 사용한다.
- 개인 Day One ZIP과 원문은 source control, test snapshot, test log에 넣지 않는다.
- 실제 샘플 검증 출력은 export version, 항목 수와 구조 경고 수로 제한한다.
- 검색 인덱스와 전체 Day One source snapshot은 기기 로컬 데이터다.
- 이메일·비밀번호 회원가입 없이 `Sign in with Apple`로 앱 접근을 인증한다.
  이름·이메일 scope는 요청하지 않고 Apple의 opaque 사용자 식별자와 마지막 승인
  상태만 기기별 `ThisDeviceOnly` Keychain에 저장한다.
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
- 선택적 앱 잠금 비밀번호 원문은 저장하지 않는다. salt와 느린 derivation을
  적용한 verifier 및 실패 상태만 각 기기의 `ThisDeviceOnly` Keychain에 저장하며
  CloudKit과 앱 백업으로 동기화하지 않는다.
- 앱 잠금은 화면 접근을 보호하는 기능이다. journal database와 CloudKit record를
  앱 비밀번호로 종단 간 암호화하는 기능은 아니다.
