# 알려진 문제와 재발 방지

반복해서 되살아나는 문제만 적는다. 한 번 고치고 끝난 버그는 여기 두지 않는다.

---

## 편집기 입력이 씹힌다 (미해결, 재발 중)

### 증상

타이핑 중 **특정 글자가 입력되지 않고 넘어간다.** 한글과 영어 모두에서
나타나며, 자모가 깨지는 IME 조합 문제와는 다르다. 사용자 표현으로는
"뭔가 씹히는 느낌".

### 이력

| 시점 | 내용 |
| --- | --- |
| build 11 이전 | 한글 조합 중 자모 유실 → `cdd106ec fix(editor): stabilize iOS typing`에서 `markedTextRange` 가드로 수정 |
| build 12 | **다시 발생.** 이번엔 한글·영어 공통이므로 위 IME 가드로는 설명되지 않는다 |

`.derived-data-ime-keychain-ios` 같은 작업 디렉터리가 남아 있는 것으로 보아
이 문제로 여러 번 씨름했다. **그런데 어디에도 기록이 없어서 매번 처음부터
원인을 다시 찾고 있다.** 이 문서가 그 재작업을 끊기 위한 것이다.

### 유력한 원인 — 700ms 전체 문서 재스타일링

`Sources/PilgrimJournal/MarkdownSupport.swift`

1. 공백 문자를 입력하면 `scheduleStyling`이 **700ms 뒤** 스타일링을 예약한다
   (`MarkdownSupport.swift:2250`, `shouldScheduleStyling`이 마지막 글자가
   공백일 때만 true).
2. 그 시점에 `applyStyling` → `LiveMarkdownStyler.apply`가 실행된다
   (`MarkdownSupport.swift:2269`).
3. `apply`는 **문서 전체**를 대상으로 동작한다 (`MarkdownSupport.swift:1219`):
   - `setAttributes(baseAttributes, range: fullRange)`로 전체 속성 초기화
   - 이어서 **정규식 패스 18회**를 문서 전체에 돌린다 (bold, italic ×2,
     strikethrough, highlight, code, link, heading, bullet, numbered, quote,
     divider, fenced code, Day One escape …)
4. 끝나면 `typingAttributes`와 `selectedRange`를 다시 설정한다.

이게 **메인 스레드에서** 돌고, 기록이 길수록 비용이 선형으로 커진다. 타이핑
도중 이 패스가 끼어들면 입력 이벤트가 밀리거나 유실될 수 있다. 증상이
한글·영어를 가리지 않는 것, 짧은 메모보다 긴 기록에서 두드러지는 것,
디버거로는 잘 안 잡히는 것이 모두 이 가설과 맞는다.

**아직 재현·프로파일링으로 확정하지 않았다.** 아래 확인 절차를 먼저 밟을 것.

### 배제된 가설 (다시 파지 말 것)

- ~~`applyStyling`이 `textViewDidChange`를 재진입시켜 `guard !isUpdating`에서
  입력이 버려진다~~ → `LiveMarkdownStyler.apply`는 `setAttributes`/`addAttribute`
  만 쓰고 **문자는 바꾸지 않는다.** 속성 변경은 `textViewDidChange`를
  발생시키지 않으므로 재진입은 일어나지 않는다.
- ~~autosave가 편집 중인 본문을 되돌려 쓴다~~ → `performAutosave`는
  `draft`의 복사본 `outgoing`을 저장할 뿐 `draft.body`에 되쓰지 않는다
  (`EntryViews.swift:431`).

### 확인 절차

1. **긴 기록으로 재현한다.** 수천 자짜리 기록을 열고 빠르게 타이핑한다.
   짧은 기록에서 재현되지 않으면 이 가설이 맞을 가능성이 높다.
2. 공백·엔터 직후 700ms 지점에서 집중적으로 씹히는지 본다.
   `shouldScheduleStyling`이 공백에서만 예약하므로 타이밍이 특징적이다.
3. Instruments Time Profiler로 `LiveMarkdownStyler.apply`의 메인 스레드 점유를
   측정한다. **화면을 켜 둔 채 실행할 것** — 잠금 상태에서 trace를 시작하면
   종료되지 않는다.
4. 임시로 `scheduleStyling`의 700ms를 크게 늘리거나 스타일링을 꺼 보고
   증상이 사라지는지 확인한다. 사라지면 원인 확정이다.

### 고칠 때의 방향

- 전체 문서가 아니라 **변경된 문단 범위만** 재스타일링한다.
- 정규식 18개를 매번 새로 도는 대신 컴파일된 정규식을 재사용하고,
  가능하면 한 번의 순회로 합친다.
- 스타일링 중 `selectedRange`를 다시 쓰지 않는다 (값이 같아도 입력 세션을
  건드릴 수 있다).

### 릴리스 게이트 (이게 재발을 막는 핵심)

**빌드를 올리기 전에 반드시 통과할 것.** 자동화 테스트는 이 문제를 잡지
못한다 — `MarkdownSupportTests`는 순수 함수만 검증하고, 실제 입력 타이밍은
검증 범위 밖이다.

- [ ] **긴 기록 타이핑** — 수천 자 기록에서 한글·영어를 30초 이상 빠르게
      입력한다. 한 글자도 씹히지 않아야 한다.
- [ ] 공백·엔터를 자주 섞어 입력한다 (스타일링 예약이 공백에서 걸린다).
- [ ] **Release 구성으로** 확인한다. DEBUG 최적화 차이로 증상이 가려질 수 있다.
- [ ] iPhone 실기기 소프트 키보드로 확인한다. Mac 하드웨어 키보드와
      시뮬레이터만으로는 부족하다.

관련: `docs/device-verification.md`의 세션 D-2.
