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

> **상태 (2026-08-12):** iPhone 실기기 소프트 키보드로 한글·영어 섞어 빠르게
> 입력하는 릴리스 게이트를 통과했다 — 씹힘이 재현되지 않았다. 다음 빌드에서도
> 이 게이트는 다시 통과해야 한다 (아래 체크리스트는 매 빌드 반복 항목).

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

**이후 에디터에 프로그래밍적으로 텍스트를 써넣는 기능(2026-08-12 이미지
붙여넣기 포함)은 반드시 이 경로(`Coordinator.replaceExternalText` → SwiftUI
binding 쓰기 → `publish(_:)`가 `publishedHistory`에 기록)를 통과해야 한다.**
`textView.insertText`나 `NSTextStorage`를 직접 건드리는 우회 경로를 새로
추가하면 이 섹션이 고친 바로 그 버그가 다른 진입점으로 재발한다. macOS
`MarkdownNSTextView`/iOS `MarkdownUITextView`의 `paste(_:)` 오버라이드가
이 규칙을 따르는 예시다 — 클립보드 이미지를 발견하면 `replaceExternalText`로
삽입하고, 없으면 `super.paste(sender)`로 기본 동작에 그대로 넘긴다.

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

### 2026-08-12 — 불릿 목록 버그 수정, macOS GUI로 실측 검증함

사용자가 보고한 5가지 불릿 목록 버그를 고쳤다. macOS Coordinator
(`textDidChange`/`textViewDidChangeSelection`)를 iOS와 같은 디바운스
스타일링 구조로 맞췄고, Backspace·Tab 키 가로채기를 새로 추가했다.

처음엔 샌드박스에 macOS Accessibility 권한이 없어 자동화가 막혔지만,
사용자가 시스템 설정에서 Terminal에 손쉬운 사용 권한을 준 뒤 재시도해
**격리된 디버그 인스턴스(`PILGRIM_VISUAL_TESTING=1`, 실제 앱과 분리된 임시
저장소)를 실제로 띄우고 System Events로 키 입력을 보내 육안으로 확인했다.**
스크린샷으로 하나씩 재현·검증한 결과:

- [x] 빈 불릿(`- `)에서 Backspace 한 번에 마커가 지워짐 — 문자 코드 덤프로
      확인(전/후 길이 비교)
- [x] Tab으로 들여쓰기, Shift+Tab으로 내어쓰기가 **Mac에서도** 동작함 — 이전엔
      iOS keyCommand로만 있었음. 문자 코드 덤프로 `"- sub"` → `"  - sub"` →
      `"- sub"` 왕복 확인
- [x] 불릿 점이 텍스트 세로 중앙에 옴 (확대 스크린샷으로 확인)
- [x] 불릿 점과 본문 사이 여백 확인
- [x] 문단 사이 Enter 4연타 + 마지막 줄 가시성 — **첫 시도는 재현 실패로
      보였으나, 원인은 버그가 아니라 테스트 방법이었다**: 이 앱의 macOS
      편집기 창은 콘텐츠에 맞춰 자동으로 커지는데(`isVerticallyResizable`
      + 편집기를 감싸는 별도 `ScrollView`가 없음), 고정된 좌표로 스크린샷을
      찍다 보니 창이 이미 더 커진 뒤에도 예전의 작은 영역만 캡처하고 있었다.
      창을 화면 높이 근처로 고정해 실제로 스크롤이 필요한 상태를 만들어
      재시도하니, `scrollRangeToVisible(preservedSelection)`을
      list-continuation 분기 밖에서 매 변경마다 무조건 호출하는 수정만으로
      마지막 줄과 태그·첨부 영역까지 정상적으로 보였다(`ensureLayout`이나
      `sizeToFit`을 추가로 걸어보기도 했는데 오히려 창이 무한정 커지는 등
      부작용만 생겨서 뺐다). 빠른 스크롤 튐 자체는 정적 스크린샷으로는
      실시간 애니메이션을 볼 수 없어 완전히 배제할 순 없지만, 근본 원인으로
      지목했던 "매 키 입력마다 전체 문서 동기 재스타일링"은 디바운스로
      없앴고 최종 상태는 항상 깨끗했다.

**남은 것:** iOS 쪽은 이번에도 실기기/시뮬레이터 GUI로 확인하지 못했다
(macOS만 Accessibility 자동화 대상이었음) — iPhone에서 별도 확인 필요.

### 2026-08-12 — 체크리스트가 실제로는 한 번도 렌더링된 적이 없었음 (별도 발견, macOS 실측 후 수정)

위 불릿 버그를 라이브로 검증하던 중 사용자가 직접 체크리스트를 만들어보고
"checklist가 표시되는 게 아니라 '-' 불릿이네"라고 지적해서 발견했다.
`- [ ] 할 일`을 입력하면 실제 체크박스 대신 보통 색의 `-` 글자만 그대로
보였다.

**원인:** `LiveMarkdownStyler`가 체크박스를 `NSAttributedString.Key.attachment`
attribute를 기존 `-` 문자 위에 그냥 얹는 방식으로 붙이고 있었다. 하지만
`NSTextAttachment`는 문자열이 실제로 object-replacement 문자(U+FFFC)로
치환된 자리에서만 렌더링된다 — AppKit/UIKit의 glyph 생성기는 평범한 문자
런에 대해서는 `.attachment` attribute를 아예 보지 않는다. 이 에디터는
저장되는 원본 마크다운 문자를 절대 바꾸지 않는 구조라서(마커는 색만
지워서 숨김) `-`를 실제로 U+FFFC로 바꿀 수도 없었다 — 그래서 애초에
`.attachment`로는 절대 렌더링될 수 없는 조합이었다. 자동화 테스트가 전혀
없던 영역이라(`testBlockMarkdownUsesDistinctLiveEditorTreatments`도 체크박스는
검증하지 않음) 이번에 처음 실사용 중 발견됐다.

**수정:** 불릿 점을 그리는 것과 똑같은 방식(`MarkdownBulletDecoration` +
`draw()` 오버라이드의 커스텀 드로잉)으로 체크박스도 직접 그리도록 바꿨다.
`MarkdownChecklistDecoration`이 마커 위치와 체크 여부를 찾아주면,
`draw()`가 그 자리에 둥근 사각형(체크 시 채움+체크마크, 아님 시 외곽선만)을
그린다. 완료 항목 본문에는 취소선도 추가함(사용자가 참고 스크린샷으로
보여준 모양과 맞춤). `checkboxAttachment` 함수는 삭제했다.

macOS 디버그 인스턴스에서 체크됨/안 됨 둘 다 실제로 그려지는 것을 스크린샷으로
확인함. iOS는 미검증(같은 코드 경로를 UIKit 버전으로 동일하게 고쳤지만
직접 확인은 못 했다).
