# 1.2.0 (31) 출시 준비

1.1.0 (29) 이후 main(`a05e694`, #39까지)을 모두 내보낸다. 기도 제목 체크리스트(#32),
가족 공유(#33), 계정 삭제 시 공유 데이터 삭제(#38)가 들어간다. 공유 카드 1단계(#22)는
스펙뿐이라 빠진다. 앱의 모든 기능은 무료다(2026-11-05 결정, 유료 잠금 없음).

- 빌드 번호는 31이다. 30은 `release/1.2.0-30`(#31, 가족 공유 제외 범위)에서 아카이브만
  해 두었고, 번호가 겹치지 않게 건너뛴다. #31은 이 릴리스로 대체된다.
- iOS 1.1.0 (29): Ready for Sale. macOS 1.1.0 (29) 상태는 App Store Connect에서 확인한다.
- **CloudKit 스키마:** SwiftData 모델(`canonicalModels`)은 바뀌지 않았다. 대신 가족 공유가
  `CKSyncEngine`으로 쓰는 레코드 타입 `SharedEntry`·`SharedRevision`이 새로 생겼다.
  **심사 제출 전에 CloudKit Console에서 Production에 배포해야 한다** — 없으면 Production은
  공유 레코드 저장을 조용히 거부한다(`docs/known-issues.md` "CloudKit 스키마 드리프트").
  Development에 두 타입이 있는지 먼저 확인한다(공유를 Development에서 한 번 저장해야
  생긴다, `docs/development.md` "공유 노트북 실기기 확인").
- 실기기 타이핑 게이트: 이 빌드 범위(main `a05e694`)의 Release 빌드로 사용자가 확인했다
  (2026-11-09).
- 출시 전 게이트와 진행 상태는 `docs/pre-release-checklist.md`의 "1.2.0 (31)" 항목.

## 새로운 기능 (App Store "이 버전의 새로운 기능")

### 한국어

- 기도노트가 기도제목 체크리스트가 됐습니다. 제목을 섹션으로 묶고, 응답된 제목은 체크해
  응답일·결과·메모를 남깁니다. 섹션 구성은 템플릿으로 저장해 다시 쓸 수 있습니다.
- 기도노트 목록에서 '기도중'과 '응답'으로 모든 노트의 기도제목을 모아 봅니다.
- 노트북이나 기록 하나를 iCloud로 가족과 공유할 수 있습니다. 공유한 것과 받은 것은
  사이드바 '공유됨'에 나옵니다. (사진이 든 기록은 아직 공유할 수 없습니다.)
- 계정을 삭제하면 iCloud에 있던 공유 데이터도 함께 지웁니다.
- 설정에서 앱 언어를 고를 수 있습니다(시스템 설정, 한국어, English).
- 설정 › 동기화에 '지금 동기화' 버튼을 추가했습니다.
- 앱 아이콘을 등잔으로 바꿨습니다. "주의 말씀은 내 발에 등이요"(시편 119:105)
- Mac 집중 모드에서는 제목과 본문만 보입니다. 오른쪽 위 버튼이나 ⌘⇧F로 돌아옵니다.
- 불릿 목록의 점이 글자 높이 가운데에 오도록 고쳤습니다.
- iPhone 기록 목록의 '선택'으로 여러 기록을 고를 수 있게 고쳤습니다.
- 유형을 옮기거나 지울 때 열려 있던 편집기 내용이 어긋나던 문제를 고쳤습니다.
- Mac 편집기에서 기록을 연 직후 입력한 내용이 드물게 사라지던 문제를 고쳤습니다.

### English

- Prayer notes are now a checklist of prayer topics. Group topics into sections, and
  check off answered ones with the date, the answer and a note. Save a section layout as
  a template to reuse it.
- Praying and Answered in the prayer note list gather topics from every note.
- Share a notebook or a single entry with family over iCloud. Everything shared with or
  by you appears under Shared in the sidebar. (Entries with photos can't be shared yet.)
- Deleting your account now also erases shared data from iCloud.
- Choose the app language in Settings (System, 한국어, English).
- New Sync Now button in Settings › Sync.
- A new oil-lamp app icon: "Your word is a lamp to my feet" (Psalm 119:105).
- Focus mode on Mac now shows only the title and body. Leave it with the button at the
  top right or ⌘⇧F.
- Bullet dots now sit centered on the text.
- Select in the iPhone entry list now selects multiple entries.
- Fixed an open editor going out of sync when its type was moved or deleted.
- Fixed rare lost typing right after opening an entry in the Mac editor.
