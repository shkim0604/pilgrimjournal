## Context

`docs/roadmap.md`의 공유 카드 기능 중 **서버가 필요 없는 부분**만 먼저 낸다. 지금까지 정해진 것:

- 카드 종류와 추출 원천: 기도제목 ← 일기·기도노트, 독후감 ← 독서노트, 간증 ← 일기·기도노트.
- 자동 게시 없음. 주인이 고친 뒤 승인해야만 나간다("올릴까요?").
- 추출은 Apple Foundation Models(iOS 26 / macOS 26, Apple Intelligence). 1차 성능 테스트
  결론 1~5와 `ShareCardEval` 결과(프롬프트 `2026-10-15.2`: 76/85, 데드라인 13/15, guardrail
  건너뜀 0회, 호출당 지연 중앙값 0.7초·p90 4.3초, M4 Mac 기준)가 구현 규칙이다.
- 일기 → 기도제목(shkim0604/pilgrimjournal#21, 프롬프트 `2026-10-16.2`)은 사람 검토 중이다.
  "기도한다"는 말이 없는 일기에서 1~3줄을 만들 수 있지만, 기도할 내용이 없는 일기에서도 억지
  기도제목을 만들고, 줄을 반복하고, 이름을 관계로 바꾸지 못한다.
- 디자인 시안 https://claude.ai/artifact/JV9krXXa9ZXz7D46JExdNq 화면 4("이 기도제목을
  올릴까요?")와 화면 10(데드라인 변경).

현재 코드에서 관련된 것:

- 앱 최소 지원은 iOS 17 / macOS 14. 기록은 `JournalEntryRecord`(`kind`, `title`, `body`,
  `occurredAt`, `details.bookTitle`/`bookAuthor`/`prayerStatus` 등). 기록에 시간대 필드는 없다.
- 기록 상세 동작은 `EntryDetailView.detailActions`(`편집`, `이력`)
  (`Sources/PilgrimJournal/EntryViews.swift`).
- 유료 기능 게이트는 `FeatureAccess`(`Sources/PilgrimJournal/FeatureAccess.swift`). 지금은
  유형 관리만 프리미엄 코드로 잠겨 있다.
- `ShareCardEval`(실행 타깃)에 `DayDate`, `EvalCalendar`, `CalendarHints`,
  `DatePhraseResolver`, `SharePipeline`, `SharePrompts`가 있다. 실행 타깃이라 앱이 가져다 쓸 수
  없고, `EvalCalendar`는 `Asia/Seoul` 시간대를 고정해 쓴다.
- Info.plist 권한 문구는 카메라와 Face ID뿐이다. `NSPhotoLibraryAddUsageDescription`이 없다.

## Goals / Non-Goals

**Goals:**
- 기록 하나 → 나눔 카드 → 시스템 공유 시트, 전부 기기 안에서.
- 모델이 있는 기기에서는 고치기 쉬운 초안을, 없는 기기에서는 같은 편집기로 직접 쓰기.
- 평가 세트에서 재는 파이프라인과 앱이 쓰는 파이프라인이 **같은 코드**가 되게 하기.
- 2단계(그룹·백엔드)에서 카드 모델·추출기·편집기를 버리지 않고 이어 쓰기.
- CloudKit 스키마·백업 형식·개인정보 경계를 건드리지 않기.

**Non-Goals:**
- 그룹, 업로드, 공개 기간과 자동 소멸, 스크랩, 댓글·반응, 알림, 구독 결제 — 전부 2단계.
- 카드나 공유 이력 저장. "이 기록은 공유했음" 표시.
- 기록을 저장할 때 백그라운드로 분석해 추천하는 배너(열린 질문 1에서 1.1로 미루자고 제안).
- 사용자가 고친 초안을 모아 프롬프트를 개인화하기(#21 실험실의 "내 말투 예시").
- 서버 LLM 대체. 모델이 없으면 직접 쓴다(로드맵의 선택지 (a)).

## 사용자 흐름

### 흐름 A — 모델이 있는 기기

1. 기록 상세에서 `나눔 카드`를 누른다(macOS는 기록 보기 툴바와 목록 컨텍스트 메뉴에도 있다).
2. 카드 편집 시트가 열리고 바로 초안 만들기가 시작된다. 상단 문구는 "이 기록에서 나눌 내용을
   찾고 있어요"와 `직접 쓰기` 버튼. 기다리지 않고 직접 써도 된다(그러면 추출을 취소한다).
3. 분류가 끝나면 카드 종류가 정해진다(아래 "카드 종류 기본값"). 시안 화면 4처럼 "10월 12일
   일기에서 찾았어요 / 이 기도제목을 나눌까요?" 헤더와 "고친 다음 공유할 수 있어요. 기록 원문은
   나가지 않고, 이 카드만 보내져요." 안내가 나온다.
4. 기도제목은 항목마다 카드가 하나씩, 체크박스와 함께 나온다. 제목과 데드라인이 먼저 채워지고,
   본문("함께 기도해 줄 내용")은 생성되는 대로 채워진다. **사용자가 이미 손댄 칸은 늦게 도착한
   생성 결과로 덮지 않는다.**
5. 다른 사람의 사정이 담긴 카드는 노란 경고("다른 사람의 사정이 담겨 있어요. 그 사람도 괜찮을지
   확인한 뒤 나눠 주세요.")가 붙고 **기본으로 선택이 꺼진다.**
6. 데드라인 줄의 `변경`을 누르면 데드라인 시트(화면 10)가 열린다: `날짜 있음`/`날짜 없음`,
   "기록의 '다음 주 화요일' → 10월 20일 (화)" 힌트, 빠른 선택 칩(내일, 다음 주 월요일, 모델이
   찾은 날짜), 달력.
7. 아래 `이미지`/`글` 형식을 고르고 `카드 N장 공유`를 누르면 시스템 공유 시트가 뜬다.
   `복사`도 있다. 시트를 닫으면 카드는 버려진다(고친 내용이 있으면 버릴지 묻는다).

### 흐름 B — 모델이 없는 기기

1~2는 같다. 시트가 바로 **빈 편집기**로 열린다. 카드 종류는 기록 종류에서 기본값을 고르고
(독서노트 → 독후감, 그 밖 → 기도제목), 독서노트는 기록의 `bookTitle`/`bookAuthor`를 채운다.
제목·본문은 비어 있다. 모델 이야기는 하지 않는다. 예외로 기기는 되는데 Apple Intelligence가
꺼져 있으면 작은 안내("Apple Intelligence를 켜면 초안을 만들어 드려요")를 한 줄 보인다.
제3자 경고는 모델이 없으므로 자동으로 뜨지 않고, 공유 버튼 위에 항상 보이는 짧은 안내
("다른 사람 이야기가 있다면 먼저 물어봐 주세요")로 대신한다.

### 흐름 C — 초안을 만들지 못한 경우

`guardrailViolation`, 컨텍스트 초과, 지원하지 않는 언어, 응답 토큰 상한 초과, 분류 결과가
모두 "아니오", 기도제목 프롬프트가 "없음"을 낸 경우 → 흐름 B의 빈 편집기로 바뀐다.
`guardrailViolation`과 "없음"은 **아무 오류도 보이지 않는다**(로드맵 결론 5). 그 밖의 오류는
"초안을 만들지 못했어요. 직접 써 주세요." 한 줄만 보인다. 오류 내용·기록 내용은 로그에 남기지
않는다.

## Decisions

### 1. 모듈 배치: 새 라이브러리 타깃 `JournalShare`

```
JournalDomain ◀── JournalShare ◀── PilgrimJournal (SwiftUI: 편집 시트, 이미지 뷰, 공유)
                       ▲
                       └──────── ShareCardEval (채점·픽스처·리포트만 남김)
```

`JournalShare`에 들어가는 것:

| 파일 | 내용 | 플랫폼 의존 |
| --- | --- | --- |
| `ShareCard.swift` | `ShareCardKind`(prayer/testimony/bookReport), `ShareCardDraft`, `ShareCardSource`, 필드 길이 상한 | 없음 |
| `ShareCalendar.swift` | `DayDate`, `CalendarHints`, `DatePhraseResolver`, `DeadlineRule` — `ShareCardEval`에서 옮기고 `Calendar`(시간대)를 주입받게 바꿈 | 없음 |
| `ShareCardTextFormatter.swift` | 카드 → 공유용 글 | 없음(`.module` 현지화) |
| `ShareCardPostProcessing.swift` | 예/아니오 파싱, "없음" 판정, 중복 줄 제거, 항목 수 상한, 앞뒤 따옴표·마크다운 제거 | 없음 |
| `ShareCardDrafting.swift` | `ShareCardDrafting` 프로토콜, `ShareCardModelAvailability`(아래), `ShareCardDraftEvent` | 없음 |
| `SharePrompts.swift` | 지시문·예시·프롬프트 버전 — `ShareCardEval`에서 옮김 | 없음 |
| `FoundationModelsShareCardDrafter.swift` | `#if canImport(FoundationModels)` + `@available(iOS 26, macOS 26, *)` 구현 | FoundationModels |

이유:
- **`JournalDomain`이 아닌 이유**: Foundation Models 구현이 같이 있어야 평가 세트가 그대로
  가져다 쓸 수 있는데, `JournalDomain`은 플랫폼 의존이 없어야 한다. 순수 타입만 `JournalDomain`에
  두고 구현을 또 나누면 타깃이 하나 더 생길 뿐 얻는 게 없다. `JournalShare` 안에서도 순수 코드와
  모델 코드는 파일과 `#if`로 나뉘어 있어, 나중에 필요하면 쪼갤 수 있다.
- **`PilgrimJournal`이 아닌 이유**: 실행 타깃이라 `ShareCardEval`이 의존할 수 없다. 평가하는
  프롬프트와 출시하는 프롬프트가 갈라지면 평가 점수가 의미를 잃는다.
- `JournalShare`는 `JournalDomain`의 `JournalKind`/`BuiltInKind`만 쓴다(원천 종류 → 카드 종류
  기본값). SwiftUI는 쓰지 않는다 — 이미지 뷰와 공유는 앱에 둔다.
- `ShareCardEval`은 채점(`EvalScorer`), 픽스처, 리포트, 실험실 서버만 남기고, 파이프라인은
  `JournalShare`의 drafter를 호출한다. 평가에만 필요한 기록(호출별 지연, 모델 날짜 vs 코드 날짜
  비교)은 drafter가 내는 이벤트(`ShareCardDraftEvent`)에서 받는다.
- 순서: shkim0604/pilgrimjournal#21을 먼저 합친 뒤 옮긴다(#21이 `DatePhraseResolverTests`와
  `SharePrompts`를 고친다).

### 2. 가용성 분기

세 겹으로 확인한다.

1. 컴파일: `#if canImport(FoundationModels)`. CI의 Xcode 26.2 SDK와 macOS 26 Command Line
   Tools에는 있다. 없는 SDK에서는 drafter가 빠지고 앱은 흐름 B만 쓴다.
2. 런타임 OS: `if #available(iOS 26, macOS 26, *)`.
3. 모델 상태: `SystemLanguageModel(guardrails: .permissiveContentTransformations).availability`와
   기록 언어 지원 여부(`supportsLocale`/`supportedLanguages` — 착수 때 최신 API 확인).

결과는 OS와 무관한 순수 enum으로 바꿔 UI와 테스트가 FoundationModels 없이 다룬다:

| `ShareCardModelAvailability` | 원인 | 편집기 |
| --- | --- | --- |
| `.available` | 사용 가능 | 흐름 A |
| `.unsupportedOS` | iOS 17~25 / macOS 14~25, 또는 SDK에 없음 | 흐름 B, 안내 없음 |
| `.deviceNotEligible` | Apple Intelligence 미지원 기기 | 흐름 B, 안내 없음 |
| `.appleIntelligenceOff` | 꺼져 있음 | 흐름 B + "켜면 초안을 만들어 드려요" |
| `.modelNotReady` | 모델 내려받는 중 등 | 흐름 B + "초안 기능을 준비하고 있어요" + `다시 시도` |
| `.unsupportedLanguage` | 기록 언어를 지원하지 않음 | 흐름 B, 안내 없음 |

시트를 열 때마다 다시 확인한다(설정에서 켜고 돌아온 경우). 앱 시작 때 미리 확인하거나 모델을
미리 올리지(prewarm) 않는다 — 시트를 연 뒤 `prewarm()`을 부르는 것은 iPhone 실측 뒤 결정한다.

**약한 링크 확인**: 배포 대상(iOS 17)보다 새로운 프레임워크를 쓰므로 iOS 17/18에서 실행 시
dyld가 FoundationModels를 찾지 못해 종료되면 안 된다. `@available` 심볼만 쓰면 링커가 약한
로드(`LC_LOAD_WEAK_DYLIB`)로 넣지만, 빌드 결과를 `otool -l`로 확인하고 iOS 17 시뮬레이터에서
실행해 본다. 아니면 `-weak_framework FoundationModels`를 명시한다.

### 3. 추출 파이프라인 (로드맵 결론 1~5)

모든 호출은 새 `LanguageModelSession`(앞 호출이 컨텍스트에 남지 않게), 모델은
`SystemLanguageModel(guardrails: .permissiveContentTransformations)`.

| 단계 | 입력 | 출력 | 옵션 |
| --- | --- | --- | --- |
| 1. 분류 | 기록 + 짧은 예시 | "기도제목이 있나?", "간증인가?" 예/아니오 | greedy, 응답 8토큰 |
| 2a. 기도 항목 | 기록 + `CalendarHints` | `@Generable` 항목 목록: `summary`, `datePhrase?`, `date?` | greedy, 600토큰 |
| 2b. 기도 본문 | 항목 요약 + 기록 | 항목당 자유 텍스트 1~3문장 | greedy, 600토큰 |
| 2c. 간증 본문 | 기록 | 자유 텍스트 | greedy, 600토큰 |
| 2d. 책 정보 | 독서노트 | `@Generable` `title`, `author`, `quote` — 기록에 `bookTitle`/`bookAuthor`가 있으면 그 값을 쓰고 모델 값은 버림 | greedy, 600토큰 |
| 2e. 독후감 본문 | 독서노트 | 깨달음 자유 텍스트, 토론 질문 자유 텍스트(따로) | greedy, 600토큰 |
| 3. 제3자 확인 | **만들어진 카드 글** | 예/아니오 | greedy, 8토큰 |

규칙:
- **분류는 추천 여부와 기본 카드 종류만 정한다.** 사용자가 편집기에서 직접 `기도제목`을 고르면
  분류가 "아니오"여도 2a·2b(일기 → 기도제목 프롬프트, #21)를 돌린다. 그 프롬프트가 "없음"을
  내면 빈 편집기로 바뀐다. 사용자가 명시적으로 요청했을 때까지 분류로 막으면, 걱정만 적은 평범한
  일기(#21이 겨냥한 경우)에서 아무것도 못 만든다.
- **날짜는 코드가 정한다.** `DatePhraseResolver.resolve(datePhrase, from: entryDay)`가 먼저,
  해석하지 못하면 모델의 `date`. 둘 다 없으면 데드라인 없음. `DeadlineRule`: 작성일 **이후**
  날짜만 데드라인으로 인정(모델이 작성일·"오늘"을 채워 넣던 문제). 해석한 날짜가 **오늘보다
  이전**이면(오래된 기록) 데드라인을 비워 두고 "기록의 '…'은 이미 지난 날짜예요" 힌트만 보인다.
- `entryDay`는 `occurredAt`을 **기기의 현재 시간대**로 자른 날짜다(기록에 시간대 필드가 없다).
  주의 시작은 월요일(한국식 "다음 주 화요일" 해석, `EvalCalendar`의 기존 규칙). 영어 "next
  Friday"도 같은 규칙으로 해석한다 — 평가 세트의 기존 정답과 같다.
- **후처리는 코드에서**: 항목 최대 3개, 같은 줄 반복 제거(#21의 반복 문제), 앞뒤 따옴표·마크다운
  기호 제거, 필드 길이 상한에서 자름. 이름을 관계로 바꾸는 일은 코드가 하지 않는다(오탐이 더
  위험하다). 경고로 대신한다.
- **제3자 확인은 카드 글에 대해 한다.** 공유되는 것은 기록이 아니라 카드라서, 기록 전체가 아니라
  카드 글을 본다. 카드 글은 짧아 호출이 빠르다. 평가 세트의 기록 단위 정확도(16/21, 과잉 표시
  5건)와 다를 수 있으므로 `ShareCardEval`에 카드 글 단위 검사를 추가해 잰 뒤 출시한다. 사용자가
  카드를 고치면 편집이 멈춘 뒤(약 1초) 다시 확인한다. 경고가 사라지는 것은 다시 확인한 결과가
  "아니오"일 때뿐이다.
- **오류**: `guardrailViolation` → 그 단계 결과를 버리고 조용히 진행(분류 단계면 흐름 C).
  `exceededContextWindowSize` → 흐름 C. 시트를 닫거나 `직접 쓰기`를 누르면 `Task`를 취소한다.
- **긴 기록**: 2,400자 기록까지는 평가에서 문제가 없었다. 처음 상한은 **3,000자**로 두고, 넘으면
  초안을 만들지 않고 흐름 B로 연다("기록이 길어 초안을 만들지 않았어요"). 나눠서 처리하는 것은
  실사용 데이터를 본 뒤 정한다. 상한은 평가 세트로 조정한다.
- **다시 만들기**: 편집기에 `다시 만들기`가 있다. 첫 초안은 greedy(평가와 같은 결과), 다시
  만들기는 낮은 temperature의 샘플링으로 다른 초안을 준다. 손댄 칸은 다시 만들기 전에 덮을지
  묻는다.
- **진행 표시**: 모델 호출은 순서대로 한다(한 기기에서 동시 세션 이득이 확인되지 않았다). 기도
  항목 3개면 분류 2 + 항목 1 + 본문 3 + 제3자 3 = 9회. M4 Mac에서 호출당 약 1~3초라 iPhone에서는
  10초를 넘길 수 있다. 그래서 단계별로 채워지는 대로 보여 주고, 기다리는 동안에도 편집할 수 있게
  한다. 첫 항목을 고르면 그 항목의 본문을 먼저 만든다.
- **출시 스위치**: `JournalShare`에 `ShareCardFeature.onDeviceDraftsEnabled` 상수를 둔다. 모델
  품질이 출시 기준(열린 질문 5)에 못 미치면 `false`로 수동 카드만 낸다. 원격 설정은 쓰지 않는다
  (서버 없음).

### 4. 카드 모델과 종류 기본값

```swift
public struct ShareCardDraft: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ShareCardKind          // .prayer, .testimony, .bookReport
    public var title: String               // 최대 40자
    public var body: String                // 기도 300자, 간증 600자, 독후감 깨달음 500자
    public var deadline: DayDate?          // 기도제목만
    public var deadlinePhrase: String?     // "다음 주 화요일" — 힌트 표시용, 공유되지 않음
    public var book: ShareCardBook?        // 독후감: title, author, quote(200자), question(200자)
    public var mentionsOtherPeople: Bool   // 경고 표시
    public var origin: Origin              // .model, .manual — 2단계 통계용, 공유되지 않음
    public var editedFields: Set<Field>    // 늦게 도착한 생성 결과가 덮지 않게
}
```

길이 상한은 시작값이다(이미지 한 장에 들어가는 양, 실기기 확인 후 조정). 카드에 **기록의 제목,
작성일, 원천 기록 종류는 들어가지 않는다** — 원문이 어디서 왔는지는 공유되지 않는다.

기본 카드 종류: 독서노트 → 독후감. 그 밖 → 분류 결과가 기도제목이면 기도제목, 간증이면 간증, 둘
다면 기도제목(간증 탭에 "찾음" 표시), 둘 다 아니면 기도제목(빈 카드). 사용자는 편집기 상단에서
종류를 바꿀 수 있다. 로드맵의 원천 표(일기·기도노트·독서노트)는 추천 배너가 생길 때 어느 기록에서
추천할지를 정하는 데 쓰고, 사용자가 직접 누른 경우에는 성경공부·메모·미분류·사용자 유형도 허용한다.

### 5. 카드 편집기 (시안 화면 4·10을 1단계에 맞게)

시안과 다른 점:
- `올릴 그룹` 칩 줄을 뺀다(그룹 없음).
- `나중에` / `1개 올리기` → `닫기` / `카드 1장 공유`. 형식 선택(`이미지`·`글`)과 `복사`를 둔다.
- "이 카드만 그룹에 보여요" → "기록 원문은 나가지 않고, 이 카드만 보내져요."
- 화면 10의 "10월 23일 (금)까지 그룹에 보이고, 그다음 사라져요"와 "함께 이야기하는 3일" 범례는
  뺀다(공개 기간 없음). 대신 "카드에 '10월 20일 (화)까지'로 적혀요."를 보인다.
- 화면 11(데드라인 없을 때 공개 기간)과 12(토론 연장)는 1단계에 없다.

편집기는 iOS에서 `.sheet`(medium/large detent), macOS에서 시트 창. 시스템 글꼴과 Dynamic Type,
VoiceOver 레이블(체크박스는 "최종 면접 공유하기"처럼 항목 이름 포함), 경고는 색만이 아니라
아이콘과 글로 전달. 편집기 내용은 메모리에만 있다. 앱 잠금이 걸리면 다른 기록 화면과 똑같이 잠금
화면이 덮는다.

### 6. 출력: 이미지와 글, 시스템 공유 시트

- **이미지**: SwiftUI `ShareCardImageView`를 `ImageRenderer`로 그린다(iOS 16 / macOS 13부터라
  최소 지원 버전에서 된다). 폭 360pt × scale 3 = **1080px**, 높이는 내용에 맞추되 최대 1920px(9:16).
  넘치면 편집기에서 "카드에 다 들어가지 않아요"를 보이고 이미지 공유를 막는다(글 공유는 된다).
  밝은 모드 고정, 고정 글자 크기(`.dynamicTypeSize(.large)`)로 그려 기기 설정과 무관하게 같은
  결과를 낸다. 카드 종류별 색은 `JournalTheme`의 종류 색을 따른다. PNG라 EXIF·위치 정보가 없다.
- **글**: `ShareCardTextFormatter`가 만든다. 예:

  ```
  [기도제목] 최종 면접
  다음 주 화요일에 최종 면접이 있어요. 떨지 않고 준비한 만큼 말할 수 있도록 기도해 주세요.
  10월 20일 (화)까지
  ```

  라벨("기도제목", "까지")과 날짜 형식은 UI 언어를 따르고, 제목·본문은 사용자가 쓴 그대로다.
  빈 필드 줄은 빠진다. 여러 장이면 빈 줄로 잇는다.
- **공유**: SwiftUI `ShareLink`. 이미지는 PNG를 내보내는 `Transferable`(파일 이름 예:
  `기도제목-최종 면접.png`), 글은 `String`. **이미지와 글을 한 번에 넘기지 않는다** — 앱마다 하나를
  버리는 동작이 달라 결과를 예측할 수 없다. 여러 장이면 이미지 여러 개를 한 번에 넘긴다. `복사`는
  `UIPasteboard`/`NSPasteboard`.
- 공유 시트의 "이미지 저장"은 사진 보관함 추가 권한을 요구하므로 `NSPhotoLibraryAddUsageDescription`
  ("나눔 카드 이미지를 사진에 저장하기 위해 사용합니다.")을 Info.plist와 `InfoPlist.xcstrings`에
  추가한다. 앱이 사진을 읽지는 않는다.
- 임시 파일이 생기면(`FileRepresentation`) 시트를 닫을 때 지운다.

### 7. 개인정보 경계

- 기록 본문은 온디바이스 모델에만 들어가고 네트워크로 나가지 않는다. 앱은 업로드하지 않는다. 사용자가
  공유 시트에서 고른 앱으로 보내는 것은 사용자 동작이다.
- 카드·초안·모델 응답·오류 내용을 저장하거나 로그에 남기지 않는다(`os_log`에도 본문 금지).
- `docs/privacy.md`에 "나눔 카드 초안은 기기 안의 Apple 모델이 만들고, 앱은 카드를 저장하거나
  업로드하지 않는다"를 추가한다. App Store 개인정보 라벨은 바뀌지 않는다(수집 없음).
- 평가 세트는 계속 지어낸 기록만 쓴다(`CLAUDE.md` 개인정보 규칙).

### 8. 현지화

- 앱 UI 문구는 한국어 키 + 영어 번역을 `Sources/PilgrimJournal/Localizable.xcstrings`에,
  `JournalShare` 문구(글 형식 라벨, 카드 종류 이름)는 `Sources/JournalShare/Resources/Localizable.xcstrings`
  (`String(localized:bundle: .module)`)에, 권한 문구는 `InfoPlist.xcstrings`에 둔다. 추가 후
  `xcodebuild -exportLocalizations`(앱, 패키지 각각)로 키를 갱신하고 `en` 값을 채운다.
- **프롬프트는 현지화하지 않는다.** 모델 입력이라 저장 데이터처럼 다룬다(`SharePrompts`는 한국어).
  "기록과 같은 언어로 쓰라"는 지시를 넣고, `ShareCardEval`에 영어 기록 픽스처를 추가해 영어 기록의
  초안 품질을 따로 잰다.
- 카드 내용(제목·본문)은 사용자 데이터라 번역하지 않는다. 카드 이미지의 라벨은 UI 언어를 따른다.
- `swift test`는 컴파일되지 않은 카탈로그를 읽어 한국어로 보이므로 형식 테스트는 한국어 기대값과
  고정 `Locale(identifier: "ko_KR")`로 쓰고, 영어는 iOS 시뮬레이터 테스트(`-testLanguage`)에서 본다.

### 9. 무료/유료

열린 질문 2. 제안은 **1단계는 무료**다. 결정이 유료로 나면 `FeatureAccess`에
`canCreateShareCards`를 추가하고 `PremiumCodeFeatureAccess`가 `isPremium`으로 답하게 한다 —
지금 구조 그대로 들어간다.

## 테스트

**`JournalShareTests` (새 타깃, `swift test`로 돈다)**
- `DatePhraseResolverTests`: `ShareCardEvalTests`에서 옮기고, 시간대 주입(서울/뉴욕에서 같은
  `occurredAt`의 `entryDay`가 달라지는 경우), 해 넘김, 윤년 2월 말, "이미 지난 날짜" 판정을 추가.
- `CalendarHintsTests`: 주·월 경계(일요일 작성, 12월 작성).
- `DeadlineRuleTests`: 작성일과 같은 날짜는 데드라인 아님, 오늘 이전은 힌트만, 해석 실패 시 모델
  날짜, 둘 다 없으면 nil.
- `ShareCardTextFormatterTests`: 종류별 형식, 빈 필드 생략, 데드라인 표기, 여러 장 잇기,
  `Locale(identifier: "ko_KR")` 고정.
- `ShareCardPostProcessingTests`: 예/아니오 파싱 변형("예.", "Yes", "아니요"), "없음" 판정, 반복
  줄 제거, 3개 상한, 마크다운·따옴표 제거, 길이 상한에서 자르기(한글 조합 문자 경계).
- `ShareCardDefaultsTests`: 원천 종류 × 분류 결과 → 기본 카드 종류, 독서노트의 책 정보 우선,
  제3자 표시 카드는 기본 선택 꺼짐.
- `ShareCardModelAvailabilityTests`: 원인 → 편집기 모드·안내 문구 매핑(순수 enum이라 FoundationModels
  없이 테스트).

**`PilgrimJournalTests`**
- 가짜 `ShareCardDrafting`으로 편집기 상태: 모델 없음 → 빈 편집기, 단계별 이벤트가 도착하는 대로
  채워짐, 사용자가 고친 칸을 늦은 결과가 덮지 않음, 시트 닫으면 drafter 취소, guardrail → 오류 없이
  빈 편집기, 이미지 높이 초과 시 이미지 공유 비활성.
- `ImageRenderer` 결과 크기(폭 1080px, 최대 1920px) 확인.
- `AppUsageGuideContentTests`: 나눔 카드 항목 존재와 "올리지 않는다" 경계 문구.

**`ShareCardEval` (모델 품질, CI 밖)** — 계속 모델 품질의 기준이다. 추가할 것: `JournalShare`
drafter를 그대로 호출, 카드 글 단위 제3자 검사, 영어 기록 픽스처, 3,000자 근처 긴 기록, "사용자가
기도제목을 골랐지만 기도할 내용이 없는" 기록에서 "없음" 비율. 프롬프트를 바꾸면 버전을 올리고
`docs/roadmap.md` 표에 적는 규칙은 그대로다.

CI(`scripts/check.sh`, Xcode 빌드, iOS 시뮬레이터 테스트)는 모델을 부르지 않는다. 가짜 drafter만
쓴다.

## 실기기 확인 (`docs/pre-release-checklist.md`·`docs/device-verification.md`에 추가)

1. **Apple Intelligence iPhone**(iPhone 15 Pro 이상, iOS 26): 첫 초안까지 시간(앱 첫 호출 포함),
   기도 항목 3개 기록의 전체 시간, 10장 연속 만들기 중 발열과 버벅임, 생성 중 편집 입력이
   끊기지 않는지, 생성 중 시트 닫기·`직접 쓰기`로 즉시 멈추는지.
2. **Apple Intelligence 끔 / 미지원 기기 / iOS 17·18 기기**: 앱이 실행되는지(약한 링크), 빈 편집기로
   열리는지, 안내 문구가 원인별로 맞는지, 모델 이야기가 엉뚱하게 나오지 않는지.
3. **모델 준비 중**: Apple Intelligence를 막 켠 직후 `다시 시도`.
4. **공유 대상**: 카카오톡(이미지·글, 여러 장), 메시지, 메일, AirDrop, "이미지 저장"(권한 문구가
   뜨고 앱이 종료되지 않는지), `복사` 후 붙여넣기. macOS: 메시지, AirDrop, 메모, 복사.
5. **이미지 품질**: 카카오톡에서 받은 쪽 화면의 글자 선명도, 긴 본문, 다크 모드 기기에서도 밝은
   카드, 큰 글자 설정에서도 같은 카드.
6. **영어**: 영어 UI 기기에서 라벨·날짜 형식, 영어 기록의 초안.
7. **앱 잠금**: 공유 시트로 다른 앱에 갔다가 돌아와 잠금 화면이 덮는지, 잠금 해제 후 편집기 상태.
8. **접근성**: VoiceOver로 항목 선택·경고 읽기·데드라인 변경, 큰 글자에서 편집기 레이아웃.
9. **생성 중 한글 입력**(Release 빌드, 실제 소프트 키보드): 카드 편집기는 마크다운이 필요 없어
   `LiveMarkdownTextEditor`가 아닌 일반 `TextField`/`TextEditor`를 쓴다. 그래도 초안이 생성되는
   동안 다른 칸이나 같은 칸에 빠르게 한·영을 섞어 입력할 때, 늦게 도착한 생성 결과가 조합 중인
   글자를 덮거나 커서를 옮기지 않는지 확인한다(`docs/known-issues.md`의 편집기 입력 문제와 같은
   종류의 위험).

## 2단계에서 더해지는 것과 이어지는 것

| 1단계 부품 | 2단계에서 |
| --- | --- |
| `ShareCardDraft`, 길이 상한 | 그대로 업로드 페이로드가 된다. `origin`으로 "모델 초안을 얼마나 고쳤나" 통계(동의 시) |
| `FoundationModelsShareCardDrafter`, `SharePrompts`, 후처리 | 그대로. 추천 배너·저장 후 추천에 재사용 |
| `DatePhraseResolver`, `DeadlineRule` | 데드라인이 공개 기간을 정한다(데드라인 + 3일). `ShareCardRetention` 계산을 추가 |
| 카드 편집기 | `올릴 그룹` 칩 줄, `카드 올리기` 버튼, 공개 기간 표시(화면 10의 "…까지 그룹에 보이고"), 화면 11·12가 더해진다. 공유 시트는 "그룹 밖으로 보내기"로 남는다 |
| `ShareCardImageView` | 그룹 피드 카드와 스크랩 미리보기에 같은 모양을 쓴다 |
| 제3자 경고 | 그대로. 업로드 전에는 한 번 더 확인 |

2단계가 새로 만드는 것: 자체 백엔드(그룹·글·댓글·반응·초대·기한 삭제·투표), 그룹 회원가입(표시
이름·프로필), StoreKit 월 구독과 서버 검증, App Review 1.2 대응(신고·차단·관리자 삭제·이용약관
동의), 서버 계정 삭제와 Sign in with Apple 토큰 폐기(서버가 생기므로 `docs/privacy.md`의 "revoke를
하지 않는 이유"가 바뀐다), APNs·Daily Report, 스크랩 종류(canonical 모델 추가 → CloudKit 스키마
드리프트 절차), 하단 탭 바, `docs/privacy.md`와 개인정보 라벨 개정.

1단계에서 얻어 2단계 결정에 쓸 것: 초안을 얼마나 고치는지, 초안 없이 직접 쓰는 비율, 공유까지
가는 비율. 분석 SDK가 없으므로 앱이 세지 않는다(`docs/privacy.md`) — 주인과 지인 사용자에게 직접
묻는다. 숫자가 꼭 필요해지면 기기 안에서만 세고 사용자가 직접 보내는 방식을 그때 따로 설계한다.

## Risks / Trade-offs

- **[Risk] 모델이 없는 기기가 대부분이다.** iOS 26 + Apple Intelligence 기기 비율이 낮으면 대부분은
  직접 쓰기다. → 그래서 편집기를 하나로 두고, 직접 쓰기만으로도 쓸모 있게(카드 이미지·글 형식,
  데드라인 선택) 만든다.
- **[Risk] 억지 기도제목.** 기도할 내용이 없는 일기에서 지어낸 기도제목이 초안으로 나온다(#21).
  → 사용자 승인 없이는 아무것도 나가지 않고, "없음"·분류 "아니오"를 우선하며, 출시 기준에 "없음"
  정확도를 넣는다(열린 질문 5).
- **[Risk] 제3자 이름이 카드에 남는다.** 모델이 지우지 못한다. → 경고 + 기본 선택 꺼짐. 과잉
  표시가 잦으면 경고가 무시된다 — 카드 글 단위 검사로 줄어드는지 평가 세트로 잰다.
- **[Risk] iPhone 지연.** M4 Mac 수치만 있다. → 단계별 표시, 편집 가능한 대기, 3,000자 상한,
  출시 스위치.
- **[Risk] 평가와 앱의 차이.** greedy 첫 초안은 평가와 같지만, 실제 기록은 픽스처와 다르다. →
  평가 세트를 계속 늘리고, 실사용 피드백은 사람에게 직접 받는다(로그 없음).
- **[Trade-off] 카드를 저장하지 않는다.** 같은 카드를 다시 보내려면 다시 만들어야 한다. 저장하면
  canonical 모델과 CloudKit 스키마 작업이 생기고, 2단계 스크랩과 겹친다. 2단계에서 정한다.

## Migration Plan

데이터 마이그레이션 없음. 새 SwiftData 모델·canonical 속성·CloudKit 스키마 변경이 없어
`docs/known-issues.md`의 스키마 드리프트 절차는 해당하지 않는다. 일반 앱 업데이트로 나간다.

## Open Questions (주인 결정 필요)

1. **어디에 둘까?**
   - (a) 기록 상세의 `나눔 카드` 버튼 + macOS 기록 보기 툴바 + 목록 컨텍스트 메뉴.
   - (b) 위에 더해, 기록을 저장하고 나면 "이 기록에서 기도제목을 찾았어요" 추천 배너.
   - **제안: (a)만.** (b)는 저장할 때마다 모델을 돌려 배터리를 쓰고, "앱이 내 일기를 읽고 있다"는
     느낌을 줄 수 있으며, 닫은 추천을 기억하려면 기기 로컬 저장(`LocalAuxiliary`)이 필요하다. iPhone
     실측과 (a) 사용 반응을 본 뒤 1.1에서 설정으로 켜는(기본 꺼짐) 배너를 검토한다.
2. **무료일까, 유료일까?**
   - (a) 전부 무료. (b) 전부 유료(프리미엄 코드 → 나중에 StoreKit). (c) 직접 쓰기 무료, 온디바이스
     초안만 유료.
   - **제안: (a) 무료.** 서버 비용이 없고, 1단계의 목적이 "쓰는 사람이 있나"를 확인하는 것인데 잠그면
     확인할 사람이 없다. 로드맵의 유료 범위는 그룹 기능이고, 2단계에서도 "그룹에 올리기"만 구독으로
     두고 공유 시트로 보내기는 무료로 남기면 무료 사용자가 유료 그룹을 알게 되는 입구가 된다. (c)는
     모델이 없는 기기 사용자에게는 차이가 없고, 있는 기기 사용자에게는 핵심 경험을 잠근다.
3. **카드 이미지 아래 "Pilgrim" 표시?**
   - **제안: 작은 글씨로 기본 표시, 편집기에서 끌 수 있고 그 선택은 기기에 기억.** 받는 사람이 앱을
     알게 되지만, 일기 앱을 쓴다는 사실을 드러내고 싶지 않은 사람도 있다.
4. **기도제목이 여러 개일 때 한 장? 여러 장?**
   - **제안: 항목마다 한 장(시안의 항목별 카드와 같음), 글 공유는 한 메시지로 이음.** "한 장에 모으기"는
     요청이 있으면 추가.
5. **온디바이스 초안을 언제 켜고 낼까?**
   - **제안: 다음을 만족할 때 `onDeviceDraftsEnabled = true`로 출시, 아니면 직접 쓰기만 먼저 출시.**
     `ShareCardEval` 전체 점수가 `2026-10-15.2` 이상(76/85), 기도할 내용 없는 기록에서 "없음"/분류
     "아니오"가 대부분(픽스처 기준 목표 5/6 이상), #21 사람 검토 완료, iPhone에서 첫 카드 초안이 10초
     안쪽. 기준 숫자는 주인이 정한다.
6. **기본 공유 형식?**
   - **제안: 이미지 기본, 글로 바꿀 수 있고 마지막 선택을 기기에 기억.** 단체방에서는 이미지가 눈에
     띄고, 글은 복사·편집이 쉽다.
