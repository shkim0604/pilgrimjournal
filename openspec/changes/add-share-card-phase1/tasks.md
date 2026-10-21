## 0. 착수 전

- [ ] 0.1 design.md "Open Questions" 1~6을 주인이 정한다(특히 2 무료/유료, 5 출시 기준).
- [ ] 0.2 shkim0604/pilgrimjournal#21(일기 → 기도제목, 프롬프트 실험실)을 합친다.
- [ ] 0.3 Foundation Models 최신 문서에서 `availability` 사유, 언어 지원 확인 API, 오류 종류,
      `prewarm`을 다시 확인한다(로드맵: "착수 시점에 최신 문서를 다시 확인").

## 1. `JournalShare` 타깃

- [ ] 1.1 `Package.swift`에 `JournalShare` 라이브러리(의존: `JournalDomain`, `Resources` 처리)와
      `JournalShareTests`를 추가한다. product도 추가한다.
- [ ] 1.2 `ShareCardEval`의 `DayDate`·`EvalCalendar`·`CalendarHints`·`DatePhraseResolver`를
      `Sources/JournalShare/ShareCalendar.swift`로 옮기고, 고정 `Asia/Seoul` 대신 `Calendar`를
      주입받게 한다. `DeadlineRule`(작성일 이후만, 오늘 이전은 힌트만)을 추가한다.
- [ ] 1.3 `ShareCard.swift`: `ShareCardKind`, `ShareCardDraft`, `ShareCardBook`, `ShareCardSource`,
      필드 길이 상한, 원천 종류 → 기본 카드 종류.
- [ ] 1.4 `ShareCardPostProcessing.swift`: 예/아니오 파싱(`EvalScorer.parseYesNo`를 옮김), "없음"
      판정, 반복 줄 제거, 3개 상한, 따옴표·마크다운 제거, 길이 상한 자르기.
- [ ] 1.5 `ShareCardTextFormatter.swift`와 `Resources/Localizable.xcstrings`.
- [ ] 1.6 `ShareCardDrafting.swift`: 프로토콜, `ShareCardModelAvailability`, `ShareCardDraftEvent`
      (단계별 결과·호출 기록), `ShareCardFeature.onDeviceDraftsEnabled`.
- [ ] 1.7 `SharePrompts.swift`를 옮기고, "기록과 같은 언어로", 카드 글 단위 제3자 질문을 추가한다.
      버전을 올린다.
- [ ] 1.8 `FoundationModelsShareCardDrafter.swift`(`#if canImport(FoundationModels)`,
      `@available(iOS 26, macOS 26, *)`): design.md 3절 표의 단계, 새 세션·greedy·토큰 상한,
      `permissiveContentTransformations`, guardrail 건너뜀, 취소, 3,000자 상한, 다시 만들기 샘플링.
- [ ] 1.9 `JournalShareTests`: design.md "테스트"의 `JournalShareTests` 항목 전부.
      `Tests/ShareCardEvalTests/DatePhraseResolverTests.swift`를 옮긴다.

## 2. `ShareCardEval`을 `JournalShare` 위로

- [ ] 2.1 `ShareCardEval`이 `JournalShare`에 의존하고 `SharePipeline`이 drafter를 호출하게 한다.
      채점·리포트는 `ShareCardDraftEvent`에서 호출 기록과 모델 날짜를 받는다.
- [ ] 2.2 같은 프롬프트로 전체 평가를 다시 돌려 옮기기 전 점수와 같은지 확인한다(옮기기만으로 점수가
      바뀌면 안 된다).
- [ ] 2.3 픽스처 추가: 영어 기록, 3,000자 근처 긴 기록, 기도할 내용 없는 기록에서 기도제목을 고른
      경우, 카드 글 단위 제3자 검사 라벨.
- [ ] 2.4 `docs/development.md` "공유 카드 추출 평가"에 `JournalShare`를 쓴다는 점을 적고,
      결과를 `docs/roadmap.md` 표에 추가한다.

## 3. 앱

- [ ] 3.1 Xcode 프로젝트 앱 타깃의 패키지 product 의존성에 `JournalShare`를 추가한다. 서명 없는
      iOS·macOS 빌드(멤버 import 가시성)를 통과시킨다.
- [ ] 3.2 Info.plist에 `NSPhotoLibraryAddUsageDescription`, `InfoPlist.xcstrings`에 한·영 문구.
- [ ] 3.3 `ShareCardViews.swift`: 편집 시트(카드 종류 선택, 항목 체크박스, 제목·본문, 경고, 형식
      선택, `카드 N장 공유`, `복사`, `다시 만들기`, `직접 쓰기`, 닫기 확인), 데드라인 시트(화면 10을
      1단계에 맞게), `ShareCardImageView`, PNG `Transferable`.
- [ ] 3.4 편집기 상태 모델: drafter 이벤트를 받아 채우기, `editedFields` 보존, 취소, 가용성별 모드,
      제3자 재확인(편집 멈춘 뒤 약 1초).
- [ ] 3.5 진입점: `EntryDetailView.detailActions`에 `나눔 카드`, macOS 기록 보기 툴바와 목록 컨텍스트
      메뉴. 휴지통 기록에는 없음.
- [ ] 3.6 `AppModel`(또는 `JournalSessionController`)에서 drafter를 만들어 주입한다. 테스트는 가짜
      drafter.
- [ ] 3.7 (열린 질문 2가 유료로 나면) `FeatureAccess.canCreateShareCards`와 잠금 안내.
- [ ] 3.8 앱 문구를 `Localizable.xcstrings`에 넣고 `xcodebuild -exportLocalizations`(앱·패키지)로
      키를 갱신한 뒤 `en` 값을 채운다.
- [ ] 3.9 `PilgrimJournalTests`: design.md "테스트"의 앱 항목.
- [ ] 3.10 약한 링크 확인: 빌드 결과에서 FoundationModels가 `LC_LOAD_WEAK_DYLIB`인지 `otool -l`로
      보고, iOS 17 시뮬레이터에서 실행한다. 아니면 `-weak_framework FoundationModels`.

## 4. 문서

- [ ] 4.1 `AppUsageGuideView.swift`에 나눔 카드 항목, `AppUsageGuideContentTests` 단언.
- [ ] 4.2 `docs/user-guide.md` 나눔 카드 절.
- [ ] 4.3 `docs/privacy.md`에 온디바이스 초안·저장/업로드 없음 한 줄.
- [ ] 4.4 `docs/device-verification.md`에 design.md "실기기 확인" 1~9를 세션으로 추가하고,
      `docs/pre-release-checklist.md`에 그 게이트를 넣는다.
- [ ] 4.5 `docs/roadmap.md` 공유 카드 절의 1단계 상태를 갱신한다.

## 5. 검증

- [ ] 5.1 `./scripts/check.sh`, 서명 없는 iOS·macOS 빌드, iOS 시뮬레이터 테스트(`-testLanguage ko`).
- [ ] 5.2 Apple Intelligence Mac에서 `swift run ShareCardEval` 전체와 `--prayer-requests`.
- [ ] 5.3 실기기 확인(4.4) — 출시 전 게이트.
