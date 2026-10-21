## Why

`docs/roadmap.md`의 공유 카드(기록 → 기도제목·독후감·간증 카드 → "올릴까요?" → 비공개
그룹)는 자체 백엔드, 그룹 회원가입, StoreKit 구독, App Review 1.2(UGC 신고·차단),
서버 측 계정 삭제와 Sign in with Apple 토큰 폐기까지 한꺼번에 끌고 온다. 그 전에 두 가지를
값싸게 확인할 수 있다:

1. **온디바이스 추출이 실제 사용자의 기록에서 쓸 만한 초안을 만드는가.** `ShareCardEval`과
   프롬프트 실험실(shkim0604/pilgrimjournal#21)은 지어낸 기록으로만 쟀다. 실제 사용자가 초안을
   얼마나 고치는지, 끝까지 공유하는지는 앱 안에서만 알 수 있다.
2. **카드 편집 UX("올릴까요?" 시트)가 자연스러운가.** 제목·본문·데드라인 편집과 제3자 정보
   경고가 시안(화면 4·10)대로 동작하는지.

이 둘은 서버 없이도 확인할 수 있다. 카드를 이미지나 글로 만들어 시스템 공유 시트(카카오톡,
메시지 등)에 넘기면, 사용자는 지금 쓰는 단체방에서 바로 나눈다. 앱은 아무것도 올리지 않으므로
`docs/privacy.md`의 "자체 기록 서버를 사용하지 않는다" 경계가 그대로 유지된다.

## What Changes

- 기록 상세(iOS)와 기록 보기(macOS)에 **`나눔 카드` 동작**을 추가한다. 누르면 카드 편집
  시트가 열린다.
- **온디바이스 초안**: iOS 26 / macOS 26 이상, Apple Intelligence가 켜진 기기에서는 Apple
  Foundation Models로 초안을 만든다. 로드맵 "1차 성능 테스트" 결론 1~5를 그대로 따른다 —
  예/아니오 분류 먼저, 짧은 값만 구조화(`@Generable`), 문장은 자유 텍스트, 날짜는 코드가
  해석(`DatePhraseResolver`), 제3자 정보는 UI 경고, `permissiveContentTransformations` +
  `guardrailViolation`이면 조용히 건너뜀.
- **모델이 없는 기기**(iOS 17~25, macOS 14~25, Apple Intelligence 미지원·꺼짐·모델 준비
  중)에서는 같은 편집기에서 **사용자가 직접** 카드를 쓴다. 기능이 사라지지 않는다.
- **카드 편집기**: 카드 종류(기도제목·간증·독후감), 제목, 본문, 데드라인(기도제목), 책 정보
  (독후감)를 고친다. 기도제목이 여럿이면 고른 것만 카드로 만든다. 다른 사람의 사정이 담긴
  카드에는 경고를 띄우고 기본으로 선택을 끈다. 데드라인 선택은 시안 화면 10을 따른다.
- **출력**: 카드를 **이미지(PNG)** 또는 **글**로 만들어 시스템 공유 시트에 넘긴다. 복사도 된다.
  앱은 네트워크로 아무것도 보내지 않는다.
- **저장하지 않는다**: 카드, 공유 이력, "이미 공유함" 표시를 저장하지 않는다. 새 SwiftData
  모델이나 canonical 속성이 없으므로 **CloudKit 스키마 변경이 없다.**
- 공유 시트의 "이미지 저장"을 위해 `NSPhotoLibraryAddUsageDescription`을 추가한다(현재 없음 —
  없으면 그 동작에서 앱이 종료된다).
- 앱 사용법과 `docs/user-guide.md`에 나눔 카드 안내를 추가한다.

넣지 않는 것: 그룹, 업로드, 공개 기간·자동 소멸, 스크랩, 댓글·반응, 알림, 구독 결제, 추천
배너(열린 질문 1), 사용자 수정 내역으로 프롬프트 개인화.

## Capabilities

### New Capabilities
- `share-card`: 기록에서 나눔 카드(기도제목·간증·독후감)를 만들고 고쳐 시스템 공유 시트로
  보내는 흐름, 온디바이스 초안과 그 가용성 분기, 날짜 해석, 제3자 정보 경고, 기기 밖으로 아무것도
  보내지 않는 경계를 정의한다.

### Modified Capabilities
- `in-app-usage-guide`: `핵심 기능의 행동 중심 안내`에 나눔 카드 사용법과 "앱은 아무것도 올리지
  않는다"는 경계 안내가 추가된다.

## Impact

- **새 라이브러리 타깃 `JournalShare`** (`Sources/JournalShare/`, `Package.swift`): 카드 도메인
  타입, 날짜 해석(`ShareCardEval`에서 옮김), 글 형식 변환, 추출 프로토콜과 Foundation Models
  구현, 프롬프트. `Resources/Localizable.xcstrings` 포함. 새 테스트 타깃 `JournalShareTests`.
- `Sources/ShareCardEval/`: 날짜 해석과 파이프라인·프롬프트를 `JournalShare`에서 가져다 쓴다
  (평가하는 코드 = 출시하는 코드). 채점·픽스처·리포트는 그대로 남는다.
  `Tests/ShareCardEvalTests/`의 `DatePhraseResolverTests`는 `JournalShareTests`로 옮긴다.
- `PilgrimJournal/PilgrimJournal.xcodeproj`: 앱 타깃의 패키지 product 의존성에 `JournalShare`
  추가. Info.plist에 `NSPhotoLibraryAddUsageDescription`,
  `PilgrimJournal/PilgrimJournal/InfoPlist.xcstrings`에 한·영 문구.
- `Sources/PilgrimJournal/`: 새 `ShareCardViews.swift`(편집 시트, 데드라인 선택, 카드 이미지
  뷰, 공유), `EntryViews.swift`(`EntryDetailView.detailActions`, macOS 기록 보기와 목록 컨텍스트
  메뉴), `AppModel.swift`(시트 표시 상태와 추출기 주입), `AppUsageGuideView.swift`,
  `Localizable.xcstrings`.
- 문서: `docs/user-guide.md`, `docs/roadmap.md`(1단계 링크), `docs/development.md`
  (`ShareCardEval`이 `JournalShare`를 쓰게 된 점), `docs/pre-release-checklist.md`와
  `docs/device-verification.md`(실기기 확인 — design.md "실기기 확인").
- `docs/privacy.md`: 경계는 바뀌지 않는다. "온디바이스 모델에 기록을 넣지만 기기 밖으로 보내지
  않는다"는 한 줄을 추가한다. App Store 개인정보 라벨 변경 없음.
- CloudKit 스키마, 백업 형식, 검색 인덱스 변경 없음.
