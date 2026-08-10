# 실기기 검증 체크리스트

시뮬레이터로 대체할 수 없는 항목만 모았다. 자동화 테스트(`./scripts/check.sh`)와
시뮬레이터 매트릭스(`scripts/capture_ios_screens.sh`)가 덮는 범위는 제외했다.

## 준비물

- Apple Developer Team `7JZU3246YR`으로 서명한 build 12 (`.release/build12/`)
- 같은 iCloud 계정에 로그인한 Mac 1대와 iPhone 1대
- 두 번째 iCloud 계정 (세션 D 전용)
- CloudKit container: `iCloud.com.dhouse.PilgrimJournal` — **개발 schema 상태**
- 익명 합성 Day One export ZIP (개인 기록 금지, `scripts/check.sh`가 커밋을 차단한다)

## 세션 순서

세션 A가 나머지를 막는다. **A를 먼저 끝내고 2.6 결론을 적기 전에는 B 이후를
진행해도 결과가 무의미해질 수 있다** — adapter를 갈아엎으면 다시 해야 한다.

| 세션 | 내용 | 태스크 | 소요 |
| --- | --- | --- | --- |
| A | CloudKit 동기화 spike (**최우선 관문**) | 2.2~2.6, 4.8 | 반나절 |
| B | 인증과 계정 격리 | 14.8, 12.2 | 1~2시간 |
| C | 데이터 E2E | 8.8, 11.10, 12.4 | 2~3시간 |
| D | 성능 | 2.5, 10.8, 6.4 | 1~2시간 |
| E | 접근성과 시각 | 12.3, 6.2, 1.1, 2.4, 6.3 | 2~3시간 |
| F | schema 승격과 TestFlight | 2.7, 12.7, 12.8, 6.6 | 1~2시간 |

---

## 세션 A — CloudKit 동기화 spike (최우선)

이 세션의 결과로 **SwiftData를 계속 쓸지(go) `NSPersistentCloudKitContainer`로
갈아탈지(no-go)** 를 결정한다. `docs/development.md`의 "저장 adapter 관문"이
합격 기준이다. 지금 미결이라 저장 adapter가 확정되지 않은 상태다.

### A-1. 왕복 동기화 — task 2.2

1. Mac에서 기록을 만들고 저장한다.
2. iPhone을 **앱이 백그라운드인 상태로** 두고 30초~2분 기다린다.
3. iPhone 앱을 열어 기록이 이미 들어와 있는지 본다.
4. 반대 방향으로 반복한다 (iPhone 생성 → Mac 수신).
5. 같은 기록을 양쪽에서 번갈아 수정한다.

- ✅ 합격: 앱을 포그라운드로 올리기 전에 수신돼 있고, 수정이 양방향으로 반영된다
- ❌ 불합격: 앱을 열어야만 동기화되거나, 수 분이 지나도 안 온다
  → **background silent push가 동작하지 않는 것이므로 no-go 근거**

### A-2. 오프라인 동시 편집과 수렴 — tasks 2.3, 4.8

1. 두 기기 모두 **비행기 모드**로 전환한다.
2. 같은 기록의 본문을 서로 다르게 고친다.
3. 한쪽만 온라인으로 돌린 뒤 수렴을 기다린다.
4. 나머지 한쪽도 온라인으로 돌린다.
5. 한쪽에서 기록을 휴지통으로 보내고 다른 쪽에서 복원한다.

- ✅ 합격: 양쪽이 같은 최종 상태로 수렴하고, 진 쪽 내용이 revision 이력에 남는다
- ✅ 합격: tombstone 삭제와 명시적 복원이 결정적으로 수렴한다
- ❌ 불합격: 한쪽 편집이 흔적 없이 사라진다 → **데이터 손실이므로 즉시 no-go**

### A-3. 첨부 asset — task 2.4

1. Mac에서 큰 이미지(수 MB)를 첨부한 기록을 만든다.
2. iPhone에서 그 기록을 연다.
3. metadata(파일명·크기)가 먼저 보이는지, 본문이 첨부와 무관하게 읽히는지 본다.
4. 첨부를 눌러 다운로드를 시작한다.
5. iCloud 저장공간이 거의 찬 계정이 있으면 용량 초과 오류도 확인한다.

- ✅ 합격: metadata 우선 표시 → 요청 시 지연 다운로드 → 진행률·재시도 노출
- ✅ 합격: 첨부 실패가 본문 편집을 막지 않는다

### A-4. 결론 기록 — task 2.6

`docs/development.md`의 "저장 adapter 관문" 5개 조건 대비 결과를 적는다.
하나라도 불합격이면 도메인 protocol은 그대로 두고
`NSPersistentCloudKitContainer` adapter로 교체한다.

> A-1~A-3이 모두 합격해야 B 이후가 의미 있다.

---

## 세션 B — 인증과 계정 격리

### B-1. Sign in with Apple — task 14.8

1. 두 기기에서 첫 로그인 (이메일 scope 요청 확인, 이름은 요청하지 않음)
2. 앱을 완전히 종료했다 재실행 → 재로그인 없이 들어가지는지
3. 비행기 모드에서 재실행 → 오프라인 세션으로 들어가지는지
4. **설정 앱 → Apple 계정 → 로그인 사용법 → Pilgrim Journal → Apple ID 사용 중단**
5. 앱으로 돌아와 로그인 화면으로 되돌아가는지
6. 앱을 재설치(업데이트 시뮬레이션)한 뒤 기록이 보존되는지

- ✅ 합격: 철회 후 journal UI가 가려지고, 재설치 후 기존 기록이 남는다

### B-2. iCloud 계정 전환 — task 12.2

이번에 새로 넣은 계정별 저장소 격리(`JournalAccountScope`)를 확인하는 항목이다.
자동화 테스트는 있지만 실제 시스템 계정 전환은 검증되지 않았다.

1. 계정 A로 기록 몇 개를 만든다.
2. **시스템 설정에서 iCloud 로그아웃**한다.
3. 앱을 열어 local-only 상태와 이전 기록 노출 여부를 본다.
4. 계정 B로 로그인한다.
5. 계정 A의 기록이 보이는지, 검색 결과에 섞이는지 확인한다.
6. 다시 계정 A로 돌아온다.

- ✅ 합격: 계정별 기록과 검색 인덱스가 섞이지 않는다
- ✅ 합격: local-only 기록이 있으면 설정에 `iCloud로 데이터 이전`이 뜨고,
  이전을 누르기 전에는 자동 병합되지 않는다
- ❌ 불합격: 계정 B에서 계정 A 기록이 보인다 → **개인정보 사고**

---

## 세션 C — 데이터 E2E

### C-1. Day One 가져오기 수렴 — task 8.8

1. Mac 설정 → `데이터 관리`에서 합성 Day One ZIP을 가져온다.
2. 미리보기에서 항목 수·중복·경고를 확인하고 실행한다.
3. iPhone에서 수렴을 기다린다.

- ✅ 합격: 태그·첨부·날짜·원본 시간대가 iPhone에 그대로 도착한다

### C-2. 백업·복원 수렴 — task 11.10

1. Mac 설정 → `백업 및 복원`에서 전체 백업을 내보낸다.
2. **iPhone을 비행기 모드로 오래 둔다** (최소 30분, 가능하면 하루).
3. 그동안 Mac에서 기록 몇 개를 바꾼다.
4. Mac에서 백업을 **replace 모드로 복원**한다.
5. iPhone을 온라인으로 돌린다.

- ✅ 합격: 오래 오프라인이던 iPhone이 연결돼도 replace 복원 결과가 유지된다
- ❌ 불합격: iPhone의 낡은 상태가 되살아나 복원을 덮어쓴다

### C-3. 전체 흐름 — task 12.4

오프라인 기록 → 동기화 → 가져오기 → 첨부 → 검색 → 백업·복원을 한 번에 훑는다.
마지막에 Mac 설정 → `데이터 무결성 검사`를 돌린다.

- ✅ 합격: 무결성 리포트에 canonical 참조·revision·첨부·검색 토큰 문제가 없다

---

## 세션 D — 성능

### D-1. 대량 배치 — tasks 2.5, 10.8

수천 건 합성 기록을 넣고 측정한다. 자동화 테스트에
`testFiveThousandEntryRebuildAndKoreanSearchPerformance`가 있지만 이건 Mac의
in-memory 기준이고, 실기기 CloudKit queue와 iPhone 응답성은 별개다.

- CloudKit queue가 밀리는 정도와 수렴까지 걸린 시간
- 업로드 중 메모리 사용량
- iPhone에서 한국어 검색·pagination 응답성
- 검색 인덱스 rebuild 소요

### D-2. 입력 반응성 — task 6.4

긴 기록(수천 자)에서 typing, scroll, live Markdown, autosave에 hitch가 없는지
Instruments로 확인한다.

> 이전 시도가 실패한 이력이 있다. **화면 잠금 상태에서 trace를 시작하면 종료되지
> 않는다.** 화면을 켜 둔 채로 실행한다.

---

## 세션 E — 접근성과 시각

시뮬레이터로 Dynamic Type·Increase Contrast·Light/Dark는 이미 매트릭스로
찍었다(`docs/visual-regression/ios/home-*.png`). 여기서는 시뮬레이터가 못 하는
것만 한다.

### E-1. VoiceOver — tasks 12.3, 6.2

실기기 VoiceOver로 sidebar → timeline → editor → 설정 → 앱 사용법 순서를 훑는다.

- ✅ 합격: 읽기 순서가 시각 순서와 맞고, 색상만으로 의미를 전달하는 요소가 없다
- ✅ 합격: 기록 유형·고정·즐겨찾기 표시에 label이 있다

### E-2. 나머지 접근성

- Mac: keyboard-only 내비게이션 (Tab/화살표만으로 전체 이동), 작은 창
- iPhone: Reduce Motion, landscape
- 긴 한국어·영어 혼합 본문

### E-3. 아이콘 — task 2.4

- macOS Dock, Finder 16px·32px·128px
- iPhone 홈 화면, 설정 앱 목록, Spotlight

**같이 확인할 것:** 이번에 `CFBundleDisplayName`을 `Pilgrim Journal`(공백 포함)로
바꿨다. 시뮬레이터에서는 SpringBoard 레이블 캐시 때문에 확인하지 못했으니
**실기기 홈 화면과 Dock에서 공백이 들어간 이름이 보이는지 확인한다.**

### E-4. 기준선 screenshot — tasks 1.1, 6.3

Mac은 시뮬레이터가 없으므로 실기기에서 Light·Dark × 넓은 창·작은 창·집중 모드를
남긴다. iPhone은 시뮬레이터 매트릭스로 대체 가능하지만 landscape는 실기기에서
찍는다.

---

## 세션 F — schema 승격과 배포

### F-1. CloudKit production schema — tasks 2.7, 12.7

CloudKit Dashboard 웹 콘솔 작업이라 기기가 필요 없다. **세션 A가 go로 끝난
뒤에만** 진행한다.

1. 개발 container의 schema snapshot을 남긴다.
2. additive-only 정책 위반(필드 삭제·타입 변경)이 없는지 검토한다.
3. migration rehearsal을 수행한다.
4. production으로 승격한다.

> 승격 전에는 production 빌드가 `CloudKit 프로덕션 스키마가 아직 배포되지
> 않았습니다.` 오류를 낸다 (`cloudSyncErrorPresentation`이 이 케이스를 감지한다).

### F-2. TestFlight — tasks 12.8, 6.6

1. `.release/build12/`의 아카이브를 export·upload 한다.
   절차는 `docs/development.md`의 "릴리스 아카이브" 참고.
   **Mac 잠금을 해제한 상태에서 실행한다** — 잠겨 있으면 `Failed to Use Accounts`.
2. TestFlight에서 두 플랫폼 설치
3. 이전 빌드에서 **업데이트** 설치 (신규 설치가 아니라)
4. 기존 기록 보존 확인
5. Mac·iPhone 편집과 appearance 전환 smoke test

---

## 보류

- **task 8.9** — 태그·첨부가 포함된 추가 익명 실제 샘플이 확보되면 adapter
  compatibility regression을 보강한다. 샘플이 없으면 진행할 수 없다.
