# 1.0.1 (25) 정식 출시 완료

2026-09-27 App Store Connect 실조회 결과:

- iOS·macOS 모두 1.0.1에 빌드 25 연결 확인.
- 두 플랫폼 모두 심사 승인 후 `PENDING_DEVELOPER_RELEASE` 상태였음.
- 양쪽 `appStoreVersionReleaseRequests` 생성 성공.
- 후속 조회에서 모두 `READY_FOR_SALE` / `READY_FOR_DISTRIBUTION` 확인.

## 최초 배포 준비 기록 (아래 인증 실패는 이후 해결됨)

- iOS 및 macOS Release 서명 아카이브 생성 성공.
- 전체 `scripts/check.sh` 통과: 테스트 210개, JournalChecks 통과.
- 로컬 보관: `.release/build25/PilgrimJournal-iOS.xcarchive`, `.release/build25/PilgrimJournal-macOS.xcarchive`.
- 업로드용 원본: `/tmp/pilgrim-release-build25/` (iCloud 동기화 밖).
- iOS export/upload 시도는 `Failed to Use Accounts`로 실패. App Store Connect 팀 접근 인증이 필요하다. 업로드·심사 제출·출시는 완료되지 않았다.
- 기존 API 키 파일은 확인했으나 Issuer ID가 없어 사용하지 않았다. Xcode 계정 또는 App Store Connect 로그인으로 인증을 해결한 뒤 재개한다.
- 스토어의 현재 출시 버전은 로그인 전이라 확인하지 못했다. 공개 버전 상태에 따라 marketing version 조정 및 재아카이브가 필요할 수 있다.
- 실제 한글 IME·iPhone 입력 릴리스 검증은 미완료다. 자동 테스트 통과와 구분한다.

## 변경 내용 초안

- 마크다운 입력 시 서식 반영을 개선했습니다.
- 서식 기호를 삭제한 뒤 표시가 갱신되지 않는 문제를 수정했습니다.
- 저장 실패 상태 표시와 편집창 종료 동작을 개선했습니다.
- Mac 집중 모드에서 패널을 다시 여는 동작을 개선했습니다.
