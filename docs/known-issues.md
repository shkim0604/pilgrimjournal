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
- [ ] 입력 도중 키보드 도구막대로 **집중 모드를 켜고 끈 뒤** 이어서 타이핑해
      본다. 전환은 본문 주변 뷰만 넣고 빼며 텍스트 뷰를 다시 만들지 않아야
      한다(`EntryEditorFocusLayout`). 본문 `MarkdownBodyEditor`/
      `LiveMarkdownTextEditor`를 `if`·`Group` 분기나 `.id()`로 감싸면 전환마다
      새 `UITextView`가 생겨 입력 중인 글자와 캐럿을 잃는다.
- [ ] **편집기를 막 연 직후 첫 입력이 남는지** 따로 본다 — 기존 기록과 새 기록
      각각, 본문 끝을 탭하고 **영어 한 글자**를 친 뒤 1초 기다린다. 글자가 그대로
      있고 캐럿이 그 뒤에 있어야 한다. 30초 연속 입력으로는 이 경우가 가려진다
      (아래 2026-10-15 항목).

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

### 2026-08-12 — 인라인 리사이즈 가능한 이미지, 실기기 검증 대기 (신규 릴리스 게이트)

붙여넣은 이미지가 라이브 편집기 안에서 바로 실제 이미지로 보이고, 커서가
그 줄에 있을 때 우측 하단 핸들을 드래그해 가로세로 비율 고정으로 크기
조절할 수 있게 했다(`![](attachment:<id> =WxH)` 문법, 크기는 텍스트에
그대로 인코딩). `LiveMarkdownStyler.apply`가 이미지 마커 줄에
`minimumLineHeight`/`maximumLineHeight`로 높이를 예약하고, `draw(_:)`가
`dirtyRect` 교차 검사로 화면 밖 이미지는 그리지 않은 채 디코드된 이미지를
합성한다. 순수 함수(`attachmentImageDisplaySize`, 마커 정규식 파싱, 삽입
시 크기 접미사 부착)는 `MarkdownSupportTests`로 커버했고 `swift build`/
`swift test`/iOS 시뮬레이터 `xcodebuild`/`scripts/check.sh`는 모두 통과했다.

**이 항목은 자동화 테스트로 검증되지 않은 상태다 — 위 릴리스 게이트를
이미지가 포함된 문서에서 반드시 다시 통과시켜야 출시 가능:**

- [ ] 위 "본문을 빠르게 30초 이상 입력" 게이트를 **이미지가 1장 이상 포함된
      본문**에서 다시 통과시킨다. `draw(_:)`에 이미지 합성이 추가되어 매
      키 입력마다(선택 변경 시에도) 호출되는 이 경로의 비용이 늘었다 —
      씹힘 회귀와 같은 코드 경로이므로 선택 사항이 아니다.
- [ ] 이미지가 여러 장(3장 이상) 있는 긴 문서에서 스크롤하며 입력했을 때
      체감 랙이 없는지 확인한다.
- [ ] macOS에서 핸들을 드래그해 리사이즈 — 비율이 고정되는지, 드래그 중
      다른 줄 입력이 막히지 않는지, 놓았을 때 `=WxH`가 저장되는지.
- [ ] iOS에서 동일 리사이즈 — 팬 제스처가 텍스트 선택/커서 이동과
      충돌하지 않는지(핸들 밖 터치는 정상적으로 텍스트 뷰가 받아야 함).
- [ ] 창 크기 변경(macOS)·회전(iOS) 후 이미지 주변 여백이 즉시 재계산되는지.
- [ ] 첨부를 휴지통에서 삭제한 뒤에도 이미지 마커가 placeholder로 깨지지
      않고 표시되는지(캐시 미스 시 무한 재시도하지 않는지).

관련: `docs/device-verification.md`/`docs/pre-release-checklist.md`에 같은
게이트 추가.

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

### 2026-08-14 — 첨부 있는 기록이 계속 느렸던 진짜 원인: `allAttachments()`가 렌더 경로에서 DB 전체를 읽고 있었음

build 19까지 `draw(_:)` 쪽만 두 번 손봤는데도(화면 밖 이미지 컬링, 이미지
상하반전/재조회 버그 수정) 사용자가 "여전히 엄청 느리다"고 재보고. 이번엔
draw()가 아니라 데이터 접근 계층과 SwiftUI 렌더 경로 전체를 조사했다.

**근본 원인:** `AttachmentEntity.binary`는 `@Attribute(.externalStorage)`라
blob마다 디스크의 별도 파일인데, `AttachmentRepository.allAttachments()`가
predicate도 fetchLimit도 없이 전 행을 가져오면서 `.binary`를 건드려
**저널의 모든 첨부 blob을 폴트**시켰다. 이게 SwiftUI view body 안에서
호출되고 있었다 — 특히 `EntryViews.swift`의 `attachmentAction(_:)`가
`ForEach(attachments)` **행마다** `hasLocalBinary`를 통해 이를 호출해서,
기록에 첨부 A개·앱 전체 첨부 T개면 렌더 한 번에 A×T개 blob이 폴트됐다.
본문 편집기는 키 입력 한 번에 최소 두 번 렌더되므로(`saveState = .saving`
재대입, 아래 참고) 첨부가 많을수록 정확히 체감 그대로 느려졌다.
`allAttachments()`의 프로토콜 문서 주석에는 이미 "`attachment(id:)`가 hot
path에서 안전한 대안"이라고 적혀 있었는데, 정작 5개 메서드가 그 관례를
따르지 않고 있었다.

같은 뿌리의 문제 두 가지도 같이 발견:
- CloudKit 동기화 이벤트마다 `updateAttachmentTransferStates`/
  `reconcileDownloadedAttachments`가 전체를 읽고 상태 enum 하나 바꾸자고
  blob을 통째로 다시 썼다(같은 CKAsset을 이중으로 재업로드하는 부작용까지).
- Day One 가져오기의 첨부 중복 검사가 **첨부 루프 안에서** `allAttachments()`를
  불러, K장 가져오기가 이미 가져온 blob 수만큼 반복 재스캔하는 O(K²)였다.

그리고 저장소 전체에 **다운샘플링이 한 줄도 없었다.** 12MP 사진을 원본
해상도로 디코드해 매 draw() 호출마다 ~600px로 리샘플링하고 있었다.

**조치 (`AttachmentRepository`에 범위를 좁힌 조회 3개 추가 —
`attachments(forEntry:)`/`attachments(inStates:)`/`attachmentChecksum(id:)`,
전부 `.binary`를 건드리지 않음):**
- `AppModel`의 첨부 관련 메서드 8개를 전부 이 좁은 조회로 교체.
  `hasLocalBinary`는 이제 `AttachmentFileStore`의 CAS 파일 존재 여부만
  확인(`FileManager.fileExists`, 내용 I/O 0)하고, 다른 기기에서 동기화돼
  CAS 파일이 아직 없는 경우에만 DB blob으로 폴백하면서 그 자리에 CAS를
  채워 넣어(`hydrate`) 다음부터는 다시 빠른 경로를 타게 함(self-healing).
- `updateAttachmentTransferStates`/`reconcileDownloadedAttachments`는 상태
  전이 전용 `updateAttachmentState(id:state:updatedAt:)`로 바꿔 blob 재기록
  자체를 없앰.
- Day One 가져오기는 루프 진입 전에 `attachmentChecksums()`(blob 안 건드림)로
  한 번만 집합을 만들도록 고쳐 O(K²)를 O(K)로.
- 새 `AttachmentImageCache`(앱 생명주기 동안 유지되는 공유 캐시)가
  `CGImageSourceCreateThumbnailAtIndex`로 **원본 해상도가 아니라 목표
  크기로 직접** 디코드하고 첨부 id로 캐싱 — 이 앱은 첨부가 생성된 뒤
  바이너리가 절대 바뀌지 않으므로(전송 상태만 바뀜) id 키가 안전함.
  편집기 Coordinator의 기존 동기 프런트 캐시는 그대로 두고(그 캐시가
  `draw()`의 필수 동기·무비용 히트 경로라는 문서화된 이유 때문), 그
  뒤쪽 비동기 로드 경로에서만 이 공유 캐시를 거치도록 배선(교체가 아니라
  뒤에 붙임).
- `MarkdownPreviewView.attachmentImageView`는 body 안에서 디스크 I/O를
  하고 있었는데, `AttachmentDownloadStatusView`가 이미 쓰던
  `.task(id:)` + `@State` 패턴으로 분리(`AttachmentImageView`).

**같이 고친, 첨부와 무관한 렌더 낭비:**
- `saveState = .saving`을 매 키 입력마다 무조건 재대입해 편집기 전체가
  두 번째로 다시 렌더되던 것 — 이미 `.saving`이면 재대입 안 하도록 가드.
  이건 이 문서가 예전부터 "증상이 남으면 다음으로 볼 곳"이라고 적어뒀던
  바로 그 지점이다.
- `draft.body.count`(글자 수 표시)가 매 렌더 전체 문서를 grapheme 단위로
  훑던 것 — `@State`로 캐싱해 실제 본문이 바뀔 때만 재계산.
  `trailingSlashQuery`가 문서 전체를 줄 단위로 split하던 것 — 뒤에서부터
  마지막 줄만 찾도록 변경. `scheduleAutosave`의 `trimmingCharacters` 전체
  본문 복사 2회 — `contains(where:)`로 단락.
- `draw(_:)`의 구분선·불릿·체크리스트 3개 루프에 dirty-rect 컬링이 아예
  없어 화면 밖 매치까지 매번 layoutManager를 호출하던 것(이미지 루프만
  build 19에서 컬링이 있었음) — 세 루프 모두에 동일하게 적용.
- `LiveMarkdownStyler.applyRegex`가 호출마다 `NSRegularExpression`을 새로
  컴파일하던 것(`apply()` 1회에 ~15번) — 패턴별로 컴파일된 정규식을
  캐싱(락으로 보호된 딕셔너리).

**미룬 것 — 별도 승인 전엔 하지 않음:** `performAutosave`가 650ms마다
`refresh()` 전체(500행 재조회 + JSON 디코드 1000회 + 노트북 카탈로그
O(n²) 재계산 + iCloud KVS 쓰기 + 앱 전체 재렌더)를 도는 것도 확인했지만,
이건 계획서 자체가 "가장 조심할 부분"으로 명시한 항목이라(수정 이력·목록
정렬 등 다른 기능이 의존) 실측 없이 진행하지 않았다. 다음에 이 항목을
다시 볼 때는 반드시 실기기 프로파일링으로 여전히 병목인지 먼저 확인할 것.

**검증:** `swift build`/`swift test`(새 회귀 테스트 포함 — 범위 좁힌 조회가
다른 기록 첨부를 안 섞는지, 상태 전이가 binary를 보존하는지, 다운샘플
캐시가 id별로 독립적인지)/iOS 시뮬레이터 컴파일/`scripts/check.sh` 전부
통과. **실기기 성능 실측과 아래 릴리스 게이트 재통과는 아직 안 함** —
이번 변경이 `draw(_:)` 렌더 경로와 편집기 재렌더 빈도를 직접 건드리므로
다음 TestFlight 전에 필수.

### 2026-08-14 — 태그 입력창에서 한글 조합이 깨짐 (근본 원인 미확정, 유력 후보만 수정)

사용자가 태그 입력 필드에 한글을 입력하니 완성된 음절이 아니라 낱개 자모가
그대로 찍히는 스크린샷을 제보(`#ㅜㅏㅏ`, `ㅓㅣㅣ` 등) — IME 조합이 매
키 입력마다 끊기는 전형적인 증상.

**유력 후보(확정 아님):** `tagsEditor`/`mobileTagsEditor`
(`EntryViews.swift`)의 태그 입력 `TextField`가 `ScrollView(.horizontal)`
안, 칩 `ForEach` 바로 뒤에 있고 `.frame(minWidth:)`만 걸려 있었다.
`TextField`의 고유 너비는 보통 내용 길이를 따라 자라므로, 글자를 입력할
때마다 이 HStack의 전체 너비가 바뀌고 — 가로 스크롤뷰 안에서는 이게 매
키 입력마다 콘텐츠 크기 재계산(relayout)을 유발한다. 이런 relayout이
진행 중이던 IME 조합 세션을 끊는 건 SwiftUI에서 알려진 패턴이다.

**조치:** `minWidth` → 고정 `width`(macOS 190, iOS 140)로 바꿔, 타이핑
중 필드 자체의 렌더 폭이 바뀌지 않게 함(텍스트는 필드 안에서 스크롤).

**왜 미확정인가:** 이 클래스의 버그는 IME 조합 상태 머신에 좌우되는데,
`swift test`는 실제 IME 조합을 재현하지 못한다. 이 수정은 가장 유력한
후보에 대한 것이지, 실기기에서 재현·확인을 거치지 않았다 — 태그 필드에
빠르게 한글을 입력해 자모가 정상적으로 조합되는지 실기기 검증 필요.
같은 파일의 배치 태그 편집 시트(`TextField("쉼표로 여러 태그 입력", ...)`,
`Form`/`Section` 안, ScrollView 아님)는 같은 구조가 아니라 손대지 않았다
— 거기서도 증상이 재현되면 원인이 다른 곳에 있다는 뜻이니 참고할 것.

### 2026-08-15 — 이미지 붙여넣기가 "비활성"이던 진짜 원인: AppKit이 `paste(_:)`를 부르기도 전에 메뉴를 잠근다

사용자가 클립보드에 이미지를 담은 채로 편집기에서 **붙여넣기 메뉴가 회색**이고
⌘V도 무반응이라고 제보. 메모·Day One에는 같은 클립보드가 잘 붙었다.

**원인:** `MarkdownNSTextView`는 `importsGraphics = false`로 만든다 — 첨부를
`NSTextAttachment`가 아니라 마크다운 참조로 관리하므로 의도된 설정이다. 그런데
`NSTextView`는 붙여넣기 메뉴의 활성 여부를 자기 `readablePasteboardTypes`와
클립보드 타입의 교집합으로 판정하고, `importsGraphics = false`면 그 목록에
**이미지 타입이 하나도 없다**(RTF/RTFD/HTML/URL/문자열/파일명/색상/폰트/룰러뿐).
이미지만 든 클립보드는 교집합이 0 → 메뉴 비활성 → `paste(_:)` 오버라이드가
**애초에 호출되지 않는다.** iOS의 `MarkdownUITextView`도 같은 구조로, 평문
`UITextView`는 `hasStrings` 기준이라 이미지 전용 클립보드에서 메뉴가 안 뜬다.

**이 함정이 위험한 이유:** 증상이 "붙여넣기 코드가 이미지를 못 알아본다"처럼
보인다. 실제로 이 세션에서 `pasteboardImageData`(빈 새 기록 저장 문제, 파일 URL
미처리)를 두 번 고쳤지만 **둘 다 호출되지 않는 코드라 아무 효과가 없었다.**
붙여넣기가 "안 먹는다"는 제보를 받으면 **핸들러 내부보다 검증 단계를 먼저
의심할 것** — 메뉴가 회색인지 아닌지가 그 둘을 가르는 결정적 단서다.

**조치:** 핸들러가 아니라 검증을 고쳤다.
- macOS: `validateUserInterfaceItem(_:)`을 오버라이드해 클립보드에 이미지가
  있으면 `paste:`만 활성화. `readablePasteboardTypes`는 **일부러 그대로 뒀다** —
  거기에 이미지 타입을 넣으면 `super.paste(_:)`가 텍스트 저장소에 실제
  `NSTextAttachment`를 꽂아 넣어 평문 모델이 깨질 수 있다.
- iOS: `canPerformAction(_:withSender:)`에서 `UIPasteboard.general.hasImages`로
  동일 처리(`hasImages`는 감지 전용이라 `.image`와 달리 붙여넣기 알림이 뜨지 않음).

**검증 방법(추정 금지 — 실측 가능하다):** GUI를 띄우지 않고 확인할 수 있다.
`swiftc`로 작은 AppKit 스크립트를 만들어 (a) `readablePasteboardTypes`를
`importsGraphics` 양쪽 값으로 출력해 이미지 타입 유무를 보고, (b) `paste:`
셀렉터를 가진 `NSMenuItem`으로 수정 전/후 서브클래스의
`validateUserInterfaceItem`을 호출해 `false → true`가 되는지 본다. 클립보드는
읽기만 하므로 사용자 클립보드를 건드리지 않는다(`osascript -e 'clipboard info'`
도 읽기 전용이라 실제 타입 확인에 쓸 수 있다).

**남은 확인:** 실기기/실빌드에서 이미지 복사 후 메뉴가 활성화되고 실제로
첨부가 삽입되는지. 자동화 테스트는 이 경로(AppKit 메뉴 검증)를 덮지 못한다.

### 2026-08-15 — 숨긴 마커 뒤에서 입력한 글자가 안 보임 (이미지 줄, `/h1` 등 제목)

사진을 붙여넣은 직후 Enter를 치고 타이핑하면 **글자가 화면에 나타나지 않는다.**
글자는 실제로 저장돼 있고, 화면에만 안 보인다.

**원인:** 이미지 마커 줄(`![](attachment:<id>)`)은 `LiveMarkdownStyler.apply`가
**줄 전체**를 투명(`PlatformColor.clear`) + `hiddenMarkerFont`(0.1pt)로 숨기고,
그 자리에 `draw(_:)`가 디코드한 이미지를 그린다. AppKit/UIKit은 캐럿 앞 문자의
속성을 `typingAttributes`로 삼으므로, 마커 줄 끝에서 Enter를 치면 새로 입력하는
글자가 **투명 0.1pt로 찍힌다.**

재스타일링(`apply`)이 전체를 base 속성으로 되돌려 복구해주지만,
`MarkdownInputReconciliation.shouldScheduleStyling`은 캐럿 앞이 **공백·줄바꿈일
때만** 재스타일링을 예약하고 그 외에는 `stylingTask?.cancel()`로 **취소한다**
(성능 최적화). 즉 Enter로 예약된 재스타일링이 첫 글자를 입력하는 순간 취소돼서,
포커스를 뺄 때까지(`textDidEndEditing`) 영영 복구되지 않는다.

불릿·체크리스트·인용은 줄 **앞부분 마커만** 숨기므로 줄 끝 문자가 정상 속성이라
이 문제가 없다. **줄 전체가 숨겨지는 유일한 케이스가 이미지 줄**이라 이미지에서만
증상이 나타난다.

**관련 — 제목 글자가 본문 크기로 찍히던 것 (build 21에서 남아 있던 부분):**
build 21에서 `# `/`/h1 `를 치면 마커는 즉시 숨겨지는데(아래 항목), **입력한 제목
글자는 여전히 본문 13pt로 찍히고** Enter를 쳐야 30pt가 됐다. 입력 속성이 항상
base였고, 크기를 입혀주는 재스타일링은 글자를 칠 때마다 취소되기 때문이다.
이제 `LiveMarkdownStyler.typingAttributes(forLinePrefix:)`가 캐럿이 있는 줄의
블록 스타일(제목 레벨)을 보고 입력 속성을 정한다. 테스트는 `apply`가 실제로
적용하는 크기와 대조해서 둘이 어긋나지 못하게 한다.

**주의 — 폰트는 같은지 비교하면 안 된다.** 한글이 섞이면 AppKit이 실제 face를
대체하므로(system UI font → Apple SD Gothic Neo) 폰트 객체 비교는 한글 입력마다
"다르다"고 나온다. 그러면 조합 중에 입력 속성을 매 키 입력마다 다시 쓰게 된다.
**`pointSize`로 비교할 것.** 이 함정은 테스트에서 먼저 걸렸다.

**관련 — 마커 서식이 늦게 반영되던 것:** 같은 디바운스 때문에 `# `를 쳐도
제목 서식이 700ms 뒤에나 적용됐고, 그 사이 글자를 치면 예약이 취소돼 Enter를
칠 때까지 그대로였다. 이제 `MarkdownInputReconciliation.completesBlockMarker`가
블록 마커(`# `~`###### `, `- `, `* `, `- [ ] `, `> `, `---`)를 완성하는 키
입력을 알아보고 그 자리에서 즉시 재스타일링한다. 마커 완성은 드물게 일어나므로
평상시 타이핑 비용은 늘지 않는다.

**같은 원인의 두 번째 증상 — 슬래시 명령(`/h1`, `/h2`…):** 제목 마커는
`"# "`(내용 앞까지 전부)를 같은 방식으로 숨긴다. 그래서 `/h1` 확장 직후 캐럿이
숨겨진 문자 바로 뒤에 놓이고, **Enter를 치지 않아도** 곧바로 입력한 글자가 안
보인다. 사용자는 "enter 칠 때까지 글씨가 안 보인다"고 제보했는데, Enter(공백류)가
재스타일링을 예약해 복구시키기 때문이다.

**조치 — 캐럿 경로를 쫓지 말고 삽입 시점에 막는다.** 처음에는 캐럿 이동마다
(`textViewDidChangeSelection`) 되돌리는 방식을 시도했지만, 캐럿이 그 자리에 오는
경로가 여러 개고(`replaceExternalText`는 `isUpdating` 중이라 델리게이트가 아예
건너뛰어진다) 실측 결과 경로마다 결과가 달랐다. **`typingAttributes` 설정과
`setSelectedRange` 순서를 바꾸는 것으로는 재현이 해소되지 않는다는 것도 실측으로
확인했다** — 그 가설로 시간을 쓰지 말 것.

최종 조치는 텍스트 뷰 자신이 입력 직전에 판단하는 것이다:
`MarkdownNSTextView`/`MarkdownUITextView`의 `insertText`와 `setMarkedText`가
`MarkdownInputReconciliation.shouldRestoreTypingAttributes`로 현재 입력 속성이
"안 보이는 속성"(0.1pt 미만 또는 알파 0)인지 보고, 그럴 때만 base로 되돌린다.
`setMarkedText`까지 덮는 이유는 한글 IME 조합 글자가 그 경로로 먼저 화면에
나타나기 때문이다. **평범한 입력에서는 속성을 건드리지 않으므로** IME 조합에
개입하지 않는다(이 파일 위쪽의 입력 씹힘 항목 참고).

**검증 방법(추정 금지 — GUI 없이 실측 가능):** `swiftc`로 AppKit 스크립트를 만들어
마커 범위를 clear+0.1pt로 칠한 `NSTextStorage`를 `NSTextView`에 넣고, 캐럿을 줄
끝에 두고 `insertText`(Enter 경유/직접 입력 양쪽) 한 뒤 삽입된 글자의 폰트
크기·알파를 읽는다. 이미지 줄과 `"# "` 각각에 대해 가드 OFF는
`font=0.1pt alpha=0.0`, 가드 ON은 `font=13.0pt alpha=0.8`로 확인했다.

**자동화 테스트가 덮는 범위:** 판정 로직은 순수 함수로 분리해
`MarkdownSupportTests`에서 검증하고, 스타일러가 실제로 만들어내는 제목·이미지
마커 속성이 "숨김"으로 판정되는지도 함께 확인한다 — 마커를 숨기는 방식이 바뀌면
그 테스트가 먼저 깨진다. 다만 AppKit의 `typingAttributes` 상속 자체는 순수 함수
테스트로 재현되지 않으므로, 숨김 마커를 **줄 전체**에 적용하는 스타일을 새로
추가할 때는 위 스크립트로 다시 실측할 것.

### 2026-08-15 — 이미지 줄은 원자적이어야 한다 (글자 하나에 이미지가 사라짐)

이미지가 있는 줄에서 타이핑하면 이미지가 사라지고 `![](attachment:…)` 원본이
드러났다. 마커 정규식이 `^!\[\]\(attachment:…\)$`로 **줄 전체가 정확히 마커일
때만** 매칭되기 때문이다. 게다가 `insertingAttachmentImage`는 문서 끝에 이미지를
넣을 때 커서를 **마커 줄 끝**에 두므로, 붙여넣고 바로 타이핑하면 100% 재현됐다.

**설계 판단:** Apple 메모·Day One은 이미지를 리치텍스트의 실제 문자(인라인
첨부)로 넣어 글이 함께 흐른다. 이 저장소는 "저장되는 문자는 정확히
`![](attachment:id …)`여야 한다"(`LiveMarkdownStyler` 주석)는 제약 때문에 그
길을 택할 수 없다 — `NSTextAttachment`를 쓰면 저장 문자열이 달라진다. 그래서
Notion·Bear처럼 **이미지를 독립 블록으로** 다룬다: 이미지 줄에는 타이핑이
들어가지 않고, 글자는 자기 줄을 새로 받는다(커서가 마커 맨 앞이면 위, 아니면
아래). 선택 영역이 있는 상태의 입력은 "이미지를 글자로 대체"라는 의도적 편집이
므로 건드리지 않는다.

판단 로직은 `MarkdownAttachmentImageDecoration.insertionRelocation`으로 분리해
테스트했고, 강제는 텍스트 뷰의 `insertText`/`setMarkedText`에서 한다 — 위쪽
입력 속성 항목과 같은 이유로 **삽입 시점**이 우회 불가능한 유일한 지점이다.

### 2026-08-15 — 이미지 리사이즈 중 그림이 옛 크기로 남아 있음

핸들을 끌면 자리(문단 높이)는 실시간으로 변하는데 그려지는 그림은 그대로였다.
`draw(_:)`가 크기를 **마커 텍스트의 `=WxH`** 에서 읽는데, 그 값은
`endAttachmentResize`에서 드래그가 끝나야 갱신되기 때문이다(드래그 중 전체
재스타일을 돌리지 않으려는 의도적 설계).

**조치:** 텍스트 뷰에 `attachmentResizePreview`(id + 크기)를 두고 드래그 중에는
`draw(_:)`가 그 값을 쓰게 했다. 드래그가 끝나면 `nil`로 되돌려 다시 마커
텍스트가 유일한 출처가 된다. 첨부 크기의 출처를 새로 추가할 때는 이 세 곳
(`draw`, `attachmentImageParagraphStyle`, 마커 텍스트)이 어긋나지 않는지 볼 것.

### 2026-10-15 — iPhone 본문에는 키보드 도구막대가 뜬 적이 없었다

`EntryEditorView`의 `.toolbar { ToolbarItemGroup(placement: .keyboard) }`는
제목·유형별 칸·태그 같은 **SwiftUI 입력칸에서만** 뜬다. 본문은
`UIViewRepresentable`의 `UITextView`라 SwiftUI가 그 도구막대를 붙이지 않는다.
그래서 서식 버튼이 정작 본문을 쓸 때는 보이지 않았다. 집중 모드 버튼을 그
도구막대에 넣으려다 시뮬레이터에서 발견했다.

**조치:** 버튼 목록을 `MarkdownKeyboardAccessory` 하나로 모으고, SwiftUI
도구막대와 본문 텍스트 뷰의 `inputAccessoryView`(`UIToolbar`)가 같은 목록을
그린다. 목록은 환경값(`markdownKeyboardAccessory`)으로 iOS
`LiveMarkdownTextEditor`에 전달된다. `updateUIView`에서 매 렌더 호출되지만
버튼 액션만 갈아 끼우고, 보이는 내용(`signature`)이 바뀔 때만 막대를 다시
만든다. 텍스트·선택 영역은 건드리지 않는다.

**주의:** 본문 키보드에 무언가 띄우려면 SwiftUI 도구막대가 아니라 이 목록에
추가할 것. 390pt 폭 iPhone에서는 아이콘 6개(키보드 닫기 포함)가 한계다 — 7개는
양쪽이 잘리는 것을 iPhone 16e 시뮬레이터에서 확인했다.

### 2026-10-15 — iPhone 편집기를 연 직후 첫 입력이 지워짐 (수정, 실기기 확인 대기)

**증상:** iPhone 시뮬레이터에서 기록을 편집으로 열고 본문 끝을 탭한 뒤 몇
글자 치고 쉬기를 반복하면, 첫 묶음 직후 캐럿이 처음 탭한 자리로 돌아가고
글자가 빠지거나 순서가 섞였다(`sizes.` 뒤에 `abc`, `def`를 치면
`sizes.defbc`). 리팩토링 전 커밋 `0e567c3`에서도 같았다.

**원인 (계측 로그로 확인):** iOS 엔트리 편집 화면에서는 키 입력마다 SwiftUI가
`updateUIView`를 두 번 이상 부르는데, **첫 번째 호출의 `text` binding은 그
키 입력 이전 값**이다(selection binding은 이미 최신). 두 번째 키 입력부터는 그
이전 값이 `publishedHistory`에 있으므로 메아리로 무시된다. 그런데 **편집기를 연
시점의 본문은 한 번도 `publish(_:)`된 적이 없어 이력에 없다.** 그래서 첫 키
입력 직후의 늦은 메아리가 "외부 변경"으로 판정되고 `replaceExternalText`가 문서를
여는 시점 값으로 되돌렸다. 시뮬레이터처럼 키가 몰려 들어오면 되돌리는 도중
(`isUpdating == true`) 대기 중이던 키가 삽입돼 순서가 섞이고, 선택 영역을
되돌린 텍스트 길이로 자른 탓에 캐럿이 앞쪽에 남았다. 그 사이 삽입된 키는
`textViewDidChange`가 `isUpdating`에서 걸러져 binding에 안 올라가므로 하단 글자
수도 여는 시점 값에 머문다. (`/h2 `가 줄 **중간**에서 안 펼쳐지는 것은 별개로
원래 동작이다 — 줄 전체가 `/h2 `일 때만 펼친다. 수정 후 새 줄에서는 펼쳐짐을
시뮬레이터에서 확인했다.)

**시뮬레이터 전용이 아니다.** 시뮬레이터의 하드웨어 키 주입 없이, 앱 안에서
`insertText`(소프트 키보드가 부르는 바로 그 API)를 1초 간격으로 한 글자씩
호출해도 첫 글자가 사라졌다. 같은 현상이 아래 XCTest에서도 재현된다. 새 기록은
여는 시점 본문이 `""`라 첫 묶음 전체가 지워진다. build 21 실기기 게이트를
통과한 이유는 확인하지 못했다 — 한글 첫 입력은 조합 중(`markedTextRange`)이라
`updateUIView`가 건너뛰므로 가려졌을 가능성이 있지만 **검증하지 않은 추정**이다.

**수정:** `makeUIView`에서 여는 시점 본문을 `publishedHistory`에 넣는다
(`Coordinator.adoptInitialText`). 판정 함수(`shouldApplyExternalText`), IME 가드,
입력 속성 리셋, 이미지 줄 원자성은 손대지 않았다. "외부 값이 과거에 본 값과
같으면 무시된다"는 위 **남은 위험**이 여는 시점 값까지 넓어지지만, iOS에는
편집기가 열린 채로 본문을 여는 시점 값으로 되돌리는 경로가 없다(키보드
도구모음 `appendCommand`는 항상 새 값, 이력 복원 `resyncDraftFromRepository`는
macOS 편집기에만 있음). **macOS에는 같은 시딩을 넣지 않았다** — 거기서는 이력
복원이 여는 시점 값으로 돌아갈 수 있어 오히려 복원을 삼킬 수 있고, macOS에서
이 증상이 관찰된 적도 없다.

**회귀 테스트:** `Tests/PilgrimJournalTests/LiveMarkdownTextEditorIOSTests.swift`
(`#if os(iOS)`). 실제 `EntryEditorView`를 창에 띄우고 `insertText`로 입력한다.
수정 없이 두 테스트 모두 실패, 수정 후 통과를 확인했다. `swift test`(macOS)는
이 파일을 건너뛰므로 시뮬레이터에서 따로 돌린다. CI(`.github/workflows/check.yml`의
`ios-tests` 잡)가 모든 PR에서 `PilgrimJournalTests` 전체를 iOS 시뮬레이터로 돌려
이 테스트를 포함한다:

```sh
xcodebuild test -scheme PilgrimJournal-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:PilgrimJournalTests/LiveMarkdownTextEditorIOSTests \
  CODE_SIGNING_ALLOWED=NO
```

참고: 단순한 호스트 뷰(부모 `@State` → `MarkdownBodyEditor`)로는 늦은 메아리가
재현되지 않았다. 실제 `EntryEditorView` 구성에서만 나오므로 테스트는 그것을 띄운다.

### 참고 — `BGSystemTaskSchedulerErrorDomain Code=3` 로그는 우리 문제가 아니다

앱은 `BGTaskScheduler`를 전혀 쓰지 않는다(코드·plist·entitlements 어디에도 등록
없음). 이 로그는 시스템 프레임워크가 자체 백그라운드 작업을 스케줄하다 남기는
잡음이며, 편집기·첨부·동기화 동작과 무관하다. 이걸 단서로 삼아 파지 말 것.
