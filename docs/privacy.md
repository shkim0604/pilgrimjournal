# 개인정보 처리 경계

- 기록은 기기 로컬 저장소와 사용자의 CloudKit 개인 데이터베이스에만 저장한다.
- public/shared CloudKit database, 광고, 분석 SDK와 자체 기록 서버를 사용하지 않는다.
- CloudKit 동기화 데이터는 사용자의 iCloud 용량을 사용한다.
- 개인 Day One ZIP과 원문은 source control, test snapshot, test log에 넣지 않는다.
- 실제 샘플 검증 출력은 export version, 항목 수와 구조 경고 수로 제한한다.
- 검색 인덱스와 전체 Day One source snapshot은 기기 로컬 데이터다.
- 별도 앱 계정이나 `Sign in with Apple`을 사용하지 않는다. 동기화는 기기에
  로그인된 시스템 iCloud 계정의 private database를 사용하며, iCloud를 사용할
  수 없으면 local-only로 계속 동작한다.
- 선택적 앱 잠금 비밀번호 원문은 저장하지 않는다. salt와 느린 derivation을
  적용한 verifier 및 실패 상태만 각 기기의 `ThisDeviceOnly` Keychain에 저장하며
  CloudKit과 앱 백업으로 동기화하지 않는다.
- 앱 잠금은 화면 접근을 보호하는 기능이다. journal database와 CloudKit record를
  앱 비밀번호로 종단 간 암호화하는 기능은 아니다.
