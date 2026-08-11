# 알려진 문제와 재발 방지

반복해서 되살아나는 문제만 적는다. 한 번 고치고 끝난 버그는 여기 두지 않는다.

---

## CloudKit 스키마가 모델보다 부족하다

### 증상

Mac과 iPhone의 기록이 서로 다르고 동기화되지 않는다. CloudKit 요청 자체는
오가지만 오류율이 20% 안팎으로 유지된다. 앱에는 아무 오류도 뜨지 않는다.

### 원인

**CloudKit의 자동 스키마 생성은 모델을 보지 않는다. 실제로 export 되는 레코드의
필드만 보고 만든다.** 그래서 구멍이 두 겹으로 생긴다.

1. **타입 자체가 없다.** `canonicalModels`가 선언한 다섯 모델 중 첨부·분류
   규칙·복원 epoch은 Development 환경 빌드에서 한 번도 만들어진 적이 없어
   레코드 타입이 생기지 않았다.
2. **있는 타입도 필드가 빠져 있다.** `CD_JournalEntryEntity`는 존재했지만
   **12개 필드가 없었다.** 한 번도 값이 채워진 적 없는 optional 속성은 export에
   실려 나가지 않으므로 스키마에도 나타나지 않는다. 나중에 그 필드를 쓰는 기록이
   처음 생기는 순간 Production에서 조용히 거부된다.

자동 생성은 Development에서만 일어난다. TestFlight 빌드는 Production을 쓰므로
빠진 타입·필드의 export는 그대로 거부되고, 실패는 앱 UI에 나타나지 않는다.

**손으로 레코드를 만들어 유도하지 말 것.** 그게 애초에 이 구멍을 만든 방식이다.
모든 optional 필드를 빠짐없이 채우는 기록을 사람이 만들어 낼 수는 없다.

### 조치 — `initializeCloudKitSchema`

SwiftData에는 스키마 배포 API가 없지만 그 밑의
`NSPersistentCloudKitContainer`에는 있다. `initializeCloudKitSchema()`는 **모델에서
직접** 레코드 타입·필드·인덱스를 만들므로 두 구멍을 한 번에 메운다.
`Sources/JournalData/CloudKitSchemaInitializer.swift`가
`NSManagedObjectModel.makeManagedObjectModel(for:)`으로 SwiftData 모델을 다리
놓아 이 API를 부른다. 임시 저장소를 쓰므로 사용자 기록은 건드리지 않는다.

명령은 `docs/development.md`의 "CloudKit 운영 도구"에 있다.

그 뒤 CloudKit Console → **Development** → `Deploy Schema Changes...` → Deploy.

**Apple 로그인이 필요 없다.** 스키마는 CloudKit 컨테이너에 속하지 사용자 계정에
속하지 않으므로 이 경로는 로그인 게이트 앞에서 돈다. 화면공유로 Touch ID를 쓸 수
없는 원격 작업에서 특히 중요하다.

주의할 점:

- **Debug 빌드여야 한다.** Production 환경은 이 API를 거부한다.
- 로그에 `SQLite disk I/O error`가 몇 줄 찍히는 것은 **정상이다.**
  `initializeCloudKitSchema`가 끝나면서 임시 저장소를 스스로 지우고, 그 뒤 Core
  Data가 남은 컨텍스트를 정리하며 사라진 파일에 접근해 내는 소리다. 호출이
  throw 하지 않았다면 성공한 것이고, 판단 기준은 Deploy 창에 뜨는 변경 목록이다.
- 모든 필드가 queryable·sortable로 표시되므로 인덱스가 많이 생긴다(첨부 31개).
  **Production 스키마 변경은 되돌릴 수 없다**(additive-only). 개인 저널 규모에서는
  부담이 없지만, 되돌릴 수 없다는 것은 알고 누를 것.

### 재발 방지

`canonicalModels`에 모델을 추가하거나 기존 모델에 속성을 추가하면 **위 명령을 한
번 돌리고 Deploy 한다.** 새 속성이 optional이면 특히 그렇다 — 값이 채워지기 전에는
자동 생성이 잡아 주지 않으므로, 기능이 나간 한참 뒤에 처음 쓰는 사용자에게서만
터진다. 릴리스 전에 Deploy 창이 **변경 0건**으로 뜨는지 확인할 것.
openspec task 12.7이 이 검토를 요구한다.

---

## 편집기 입력이 씹힌다 (수정 적용, 실기기 확인 대기)

> **상태 (2026-08-11):** 수정과 회귀 테스트를 넣었고 **macOS 앱에서 씹힘이
> 재현되지 않았다.** 다만 화면공유로 타이핑한 결과라 증거력이 약하다 —
> 화면공유는 키 이벤트를 묶어 보내므로 경합이 가려질 수 있다.
> **iPhone 소프트 키보드 확인이 남았다.** 아래 릴리스 게이트를 볼 것.

### 증상

타이핑 중 **특정 글자가 입력되지 않고 넘어간다.** 한글과 영어 모두에서
나타나며, 자모가 깨지는 IME 조합 문제와는 다르다. 사용자 표현으로는
"뭔가 씹히는 느낌".

**범위를 좁히는 결정적 단서:**

- **제목 입력은 멀쩡하고 본문만 문제다.**
- **공백과 무관하다.** 아무 글자에서나 발생한다.

제목은 SwiftUI 기본 `TextField`(`EntryViews.swift:56`), 본문은
`UIViewRepresentable`인 `LiveMarkdownTextEditor`다. **둘은 같은 `draft`에 쓰고
같은 `.onChange(of: draft)` autosave를 트리거한다.** 조건이 같은데 본문만
깨지므로, 원인은 autosave나 SwiftUI 상태 압력이 아니라 **UIKit 왕복 자체**에
있다.

### 이력

| 시점 | 내용 |
| --- | --- |
| build 11 이전 | 한글 조합 중 자모 유실 → `cdd106ec fix(editor): stabilize iOS typing`에서 `markedTextRange` 가드로 수정 |
| build 12 | **다시 발생.** 이번엔 한글·영어 공통이므로 위 IME 가드로는 설명되지 않는다 |

`.derived-data-ime-keychain-ios` 같은 작업 디렉터리가 남아 있는 것으로 보아
이 문제로 여러 번 씨름했다. **그런데 어디에도 기록이 없어서 매번 처음부터
원인을 다시 찾고 있다.** 이 문서가 그 재작업을 끊기 위한 것이다.

### 유력한 원인 — 오래된 binding 값이 최신 입력을 덮어쓴다

`Sources/PilgrimJournal/MarkdownSupport.swift`의 `updateUIView`:

```swift
func updateUIView(_ textView: UITextView, context: Context) {
    context.coordinator.parent = self
    guard !context.coordinator.isUpdating else { return }
    guard MarkdownInputReconciliation.canMutateTextStorage(
        isComposing: textView.markedTextRange != nil
    ) else { return }
    if textView.text != text {                       // ← 여기
        context.coordinator.replaceExternalText(text, ...)
        return
    }
```

`text`는 **렌더 시점에 확정된** SwiftUI binding 값이다. 타이핑이 그보다 앞서
나가면 `textView.text`가 최신이고 `text`가 한 글자 뒤처지는데, 위 비교는 그
차이를 **외부 변경으로 오인해** `replaceExternalText(text)`로 **문서 전체를
낡은 값으로 되돌린다.** 그 사이 입력된 글자가 사라진다.

경합이 벌어지는 경로:

1. 키 입력 → `textViewDidChange` → `parent.text = continued.text`
   (`MarkdownSupport.swift:2194`) — 매 타에 SwiftUI 상태 쓰기
2. 그 쓰기가 `.onChange(of: draft)` → `scheduleAutosave()` →
   `saveState = .saving` (`EntryViews.swift:419`)를 또 유발 —
   **한 번의 키 입력이 최소 두 번의 렌더를 만든다**
3. 렌더마다 `updateUIView`가 불린다. 그 사이 사용자가 한 글자 더 치면 위
   비교가 걸린다

증거와 전부 들어맞는다.

| 관찰 | 설명 |
| --- | --- |
| 본문만 문제 | `UIViewRepresentable` 왕복이 있는 쪽만 해당 |
| 제목은 정상 | 기본 `TextField`는 SwiftUI가 내부에서 상태를 합쳐 처리 |
| 공백 무관 | 매 키 입력마다 상태 쓰기가 일어난다 |
| 한글·영어 공통 | 조합이 끝난 글자는 `markedTextRange`가 없어 IME 가드가 안 걸린다 |
| 빨리 칠수록 심함 | 경합 구간이 넓어진다 |
| Release·실기기에서 두드러짐 | 렌더·입력 타이밍 차이 |

**아직 재현으로 확정하지 않았다.** 아래 확인 절차를 먼저 밟을 것.

### 배제된 가설 (다시 파지 말 것)

- ~~700ms 전체 문서 재스타일링(`LiveMarkdownStyler.apply`)이 입력을 밀어낸다~~
  → `scheduleStyling`은 `shouldScheduleStyling`이 true일 때, 즉 **마지막 글자가
  공백일 때만** 예약된다(`MarkdownSupport.swift:2307`). 증상은 공백과 무관하므로
  이 경로가 아니다. 다만 문서 전체에 정규식 18패스를 메인 스레드에서 도는 것은
  **별개의 성능 문제**로 남아 있다(task 6.4).
- ~~`applyStyling`이 `textViewDidChange`를 재진입시켜 `guard !isUpdating`에서
  입력이 버려진다~~ → `LiveMarkdownStyler.apply`는 `setAttributes`/`addAttribute`
  만 쓰고 **문자는 바꾸지 않는다.** 속성 변경은 `textViewDidChange`를
  발생시키지 않으므로 재진입은 일어나지 않는다.
- ~~autosave가 편집 중인 본문을 되돌려 쓴다~~ → `performAutosave`는
  `draft`의 복사본 `outgoing`을 저장할 뿐 `draft.body`에 되쓰지 않는다
  (`EntryViews.swift:431`). 제목도 같은 autosave를 타는데 멀쩡한 것이 방증이다.

### 적용한 수정

`textView.text != text` 하나로 "binding이 뒤처진 것"과 "진짜 외부 변경"을
뭉뚱그려 판단하던 것을 분리했다.

- coordinator가 **자기가 binding에 쓴 값의 최근 이력**을 들고 있는다
  (`publishedHistory`, 최대 32개). 모든 binding 쓰기는 `publish(_:)`를 지난다.
- `MarkdownInputReconciliation.shouldApplyExternalText(incoming:current:publishedHistory:)`
  가 판단한다. 들어온 값이 이력에 있으면 **자기 메아리**이므로 무시하고,
  한 번도 발행한 적 없는 값만 외부 변경으로 보고 적용한다.
- iOS `updateUIView`와 macOS `updateNSView` 양쪽에 같은 규칙을 적용했다.
  **두 플랫폼 모두 같은 결함이 있었다.**

회귀 테스트는 `MarkdownSupportTests`에 4건 추가했다. 순수 함수라 기기 없이
`swift test`로 검증된다 — 이 문제로 TestFlight를 왕복하지 않기 위한 장치다.

### 우리 문제가 아닌 것 — 한영 전환 지연

수정 후 검증에서 "한영 전환이 조금 느리다"는 관찰이 나왔다. **제목 칸에서도
지연이 동일했다.** 제목은 순수 SwiftUI `TextField`라 `LiveMarkdownTextEditor`,
스타일링, 발행 이력 어느 것도 관여하지 않는다. 따라서 시스템 입력기 전환
지연이며(화면공유 입력 지연도 더해진다) 앱 코드로 고칠 대상이 아니다.

**같은 관찰이 다시 나오면 먼저 제목 칸과 비교할 것.** 제목도 같으면 우리
문제가 아니다.

### 남은 위험

- 외부 변경 값이 **우연히 과거에 발행한 값과 같으면** 메아리로 오인해 무시한다.
  실제로는 binding을 통한 undo 정도가 해당하는데, undo·redo는 text view 자체의
  `undoManager`가 처리하므로(`replaceExternalText`가 등록) 경로가 다르다.
- `parent.text` 쓰기가 매 키 입력마다 두 번의 렌더를 유발하는 구조
  (`.onChange(of: draft)` → `saveState = .saving`)는 그대로다. 경합 자체를
  줄이려면 이쪽도 손봐야 한다. 증상이 남으면 다음으로 볼 곳이다.

### 릴리스 게이트 (이게 재발을 막는 핵심)

**빌드를 올리기 전에 반드시 통과할 것.** 자동화 테스트는 이 문제를 잡지
못한다 — `MarkdownSupportTests`는 순수 함수만 검증하고, 실제 입력 타이밍은
검증 범위 밖이다.

- [ ] **본문을 빠르게 30초 이상 입력한다.** 한글과 영어를 섞고, 한 글자도
      씹히지 않아야 한다. 제목이 아니라 **본문**이어야 한다.
- [ ] **Release 구성으로** 확인한다. DEBUG 최적화 차이로 증상이 가려질 수 있다.
- [ ] iPhone 실기기 소프트 키보드로 확인한다. Mac 하드웨어 키보드와
      시뮬레이터만으로는 부족하다.
- [ ] 도구모음 서식·slash command를 쓴 뒤에도 이어서 타이핑해 본다
      (외부 변경 경로와 입력 경로가 함께 걸리는 구간).

관련: `docs/device-verification.md`의 세션 D-2.
