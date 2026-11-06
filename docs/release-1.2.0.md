# 1.2.0 (30) 출시 준비

1.1.0 (29) 이후 main(`d3d85d0`)에 들어간 것을 그룹 기능 없이 내보낸다. 가족 공유
(`feat/family-sharing`)와 공유 카드 1단계(#22)는 들어가지 않는다. 앱의 모든 기능은
무료다(2026-11-05 결정, 유료 잠금 없음).

- iOS 1.1.0 (29): Ready for Sale. macOS 1.1.0 (29): 2026-10-21에 Waiting for Review로
  재제출했다. 지금 상태는 App Store Connect에서 확인한다.
- CloudKit 스키마 변경 없음(1.1.0 (29) 이후 `JournalData` 변경 없음) — 스키마 배포 불필요.
- 출시 전 게이트와 진행 상태는 `docs/pre-release-checklist.md`의 "1.2.0 (30)" 항목.

## 새로운 기능 (App Store "이 버전의 새로운 기능")

### 한국어

- 설정에서 앱 언어를 고를 수 있습니다(시스템 설정, 한국어, English).
- 설정 › 동기화에 '지금 동기화' 버튼을 추가했습니다.
- 앱 아이콘을 등잔으로 바꿨습니다. "주의 말씀은 내 발에 등이요"(시편 119:105)
- Mac 집중 모드에서는 제목과 본문만 보입니다. 오른쪽 위 버튼이나 ⌘⇧F로 돌아옵니다.
- 불릿 목록의 점이 글자 높이 가운데에 오도록 고쳤습니다.
- iPhone 기록 목록의 '선택'으로 여러 기록을 고를 수 있게 고쳤습니다.
- 유형을 옮기거나 지울 때 열려 있던 편집기 내용이 어긋나던 문제를 고쳤습니다.
- Mac 편집기에서 기록을 연 직후 입력한 내용이 드물게 사라지던 문제를 고쳤습니다.

### English

- Choose the app language in Settings (System, 한국어, English).
- New Sync Now button in Settings › Sync.
- A new oil-lamp app icon: "Your word is a lamp to my feet" (Psalm 119:105).
- Focus mode on Mac now shows only the title and body. Leave it with the button at the
  top right or ⌘⇧F.
- Bullet dots now sit centered on the text.
- Select in the iPhone entry list now selects multiple entries.
- Fixed an open editor going out of sync when its type was moved or deleted.
- Fixed rare lost typing right after opening an entry in the Mac editor.
