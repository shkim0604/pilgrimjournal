# 개발 및 배포 구성

## 식별자

- 제품명: Pilgrim Journal
- bundle identifier: `com.dhouse.PilgrimJournal`
- CloudKit container: `iCloud.com.dhouse.PilgrimJournal`

## Xcode capability

iOS와 macOS target 모두에 다음 capability가 필요하다.

1. Sign in with Apple
   - Xcode의 Signing & Capabilities에서 두 플랫폼 target에 추가
   - iOS와 macOS App ID를 Apple Developer의 같은 primary App ID 그룹으로 구성
   - 실제 기기에서는 Two-Factor Authentication이 활성화된 Apple 계정 사용
2. iCloud
   - CloudKit 활성화
   - 동일한 private container 선택
3. Background Modes
   - Remote notifications 활성화

저장소의 `PilgrimJournal.entitlements`에는 Sign in with Apple, CloudKit private
container와 iCloud key-value store entitlement가 포함되어 있다. 실제 로그인과
CloudKit은 소유한 Apple Developer Team과 provisioning profile로 서명해야 하며
`CODE_SIGNING_ALLOWED=NO` 빌드는 UI·컴파일 검증만 가능하다.

CloudKit private database의 고정 account-binding record에는 Apple 로그인의 opaque
사용자 식별자를 앱 범위에서 SHA-256한 값만 저장한다. 같은 private database를 다른
Apple 로그인 사용자가 열면 journal UI를 차단한다. Apple은 로그인 계정과 시스템
iCloud 계정의 이메일을 앱에 제공하지 않으므로 최초 연결은 현재 iCloud private
database를 현재 Apple 로그인 사용자에게 귀속시키는 동작이다.

iOS target의 `Info.plist`에는 Face ID 앱 잠금 설명을 추가한다.

- `NSFaceIDUsageDescription`: `개인 일기 기록의 앱 잠금을 해제하기 위해 Face ID를 사용합니다.`

CloudKit production schema는 additive-only 정책으로 관리한다. 개발 container에서
생성·수정·동시 편집·삭제 tombstone·첨부·복원을 실제 Mac과 iPhone으로 검증한
뒤에만 production으로 승격한다.

앱은 `NSPersistentCloudKitContainer.eventChangedNotification`의 setup·import·export
이벤트를 관찰한다. 진행 중에는 동기화 대기로 표시하고, export/import 완료 시
완료 시각을 갱신한다. Remote import가 완료되면 canonical 목록과 로컬 검색 색인을
새로고침하며 실패 이벤트는 재시도 가능한 오류로 표시한다. 이 이벤트 처리는
자동화 테스트 대상이지만, 실제 두 기기의 네트워크 수렴은 아래 실제 기기 관문을
별도로 통과해야 한다.

## 저장 adapter 관문

초기 adapter는 SwiftData를 사용한다. 실제 기기 spike에서 다음 조건을 모두
통과해야 한다.

- 같은 계정의 두 기기에서 background 수렴
- 오프라인 동시 편집 revision 보존
- 삭제 tombstone과 명시적 복원
- 외부 저장 첨부 업로드와 지연 다운로드
- 대량 Day One import 후 앱 응답성 유지

하나라도 충족하지 못하면 도메인 protocol은 유지하고
`NSPersistentCloudKitContainer` adapter로 교체한다.

## CloudKit 운영 도구

Debug 빌드는 환경 변수 두 개로 앱 대신 관리 작업을 수행하고 종료한다. 둘 다
**Apple 로그인 앞에서** 돌기 때문에 Touch ID를 쓸 수 없는 원격 세션에서도 쓸 수
있다. 실행 파일을 직접 부른다 — `open`은 환경 변수를 전달하지 않는다.

```bash
DD=/tmp/pilgrim-dd   # iCloud 동기화 밖 경로여야 한다. 아래 "릴리스 아카이브" 참고
xcodebuild -project PilgrimJournal/PilgrimJournal.xcodeproj \
  -scheme PilgrimJournalApp -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" build
# macOS 제품명에 공백이 있으므로 이름을 박아 쓰지 말고 glob 으로 찾는다.
APP=$(ls -d "$DD/Build/Products/Debug/"*.app)
BIN="$APP/Contents/MacOS/$(/usr/libexec/PlistBuddy \
  -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
PILGRIM_DEPLOY_CLOUDKIT_SCHEMA=1 "$BIN"
```

| 변수 | 하는 일 |
| --- | --- |
| `PILGRIM_DEPLOY_CLOUDKIT_SCHEMA=1` | 모델에서 레코드 타입·필드·인덱스를 만든다. 자세한 배경은 `docs/known-issues.md` |
| `PILGRIM_WIPE_JOURNAL_DATA=1` | 미러링 존을 지워 기록을 전부 없앤다. **스키마는 남는다** |
| `PILGRIM_WIPE_LOCAL_DATA=1` | 위와 함께 쓰면 이 기기의 저장소·검색 인덱스도 지운다 |
| `PILGRIM_DEV_APPLE_USER=<id>` | 로그인 게이트를 건너뛰고 실제 저장소·CloudKit으로 앱을 연다 |

**CloudKit 환경은 서명이 정한다.** Debug 빌드는 Development만 건드린다.
Production 데이터를 지우려면 CloudKit Console → Data → Zones에서
`com.apple.coredata.cloudkit.zone`을 직접 삭제하거나, TestFlight 앱에서 빈 백업을
replace 모드로 복원한다.

존을 지워도 **로컬 사본을 가진 기기는 다음 실행에서 존을 다시 만들고 전부
재업로드한다.** 정말로 비우려면 모든 기기의 로컬 데이터도 같이 지워야 한다.

## 공유 카드 추출 평가 (온디바이스 모델)

`docs/roadmap.md`의 공유 카드(기도제목·간증·독후감) 추출을 Apple 온디바이스 모델로
돌려 보고 점수를 매기는 실행 파일이다. 프롬프트를 바꿀 때마다 같은 기록으로 다시 돌려
비교한다.

```sh
swift run ShareCardEval                      # 전체 23개 기록 (약 2~3분)
swift run ShareCardEval --skip-prose         # 카드 문장 생성 생략. 점수는 같고 더 빠르다
swift run ShareCardEval --only next-month-day,long-no-prayer --verbose
swift run ShareCardEval --list               # 기록 id 목록
swift run ShareCardEval --json /tmp/share-card-run.json
```

- **필요 조건:** macOS 26 이상, Apple Intelligence 지원 Mac에서 Apple Intelligence가
  켜져 있어야 한다. 모델을 쓸 수 없으면 이유를 출력하고 종료 코드 69로 끝난다.
  `swift build`는 어디서나 통과하도록 모델 코드를 `canImport(FoundationModels)`와
  macOS 26 확인 뒤에 두었다. 하드웨어가 필요하므로 `scripts/check.sh`와 CI에서는
  **돌리지 않는다.** (날짜 해석·채점 같은 순수 로직은 `ShareCardEvalTests`로 `swift
  test`에 들어 있다.)
- **기록은 전부 지어낸 것이다** (`Sources/ShareCardEval/EvalFixtures.swift`). 실제
  기록이나 Day One 내용을 넣지 않는다. 기록을 추가할 때 `expected` 라벨(기도제목
  여부, 간증 여부, 제3자 사정, 데드라인)을 함께 적는다. 데드라인은 `phrase`가 본문에
  그대로 있어야 하고, 테스트가 그 표현을 코드로 해석해 라벨 날짜와 맞는지 확인한다.
- **파이프라인**(`SharePipeline.swift`): ① 짧은 예시를 넣은 예/아니오 분류 3개(기도제목
  있음, 간증, 제3자 사정) ② 기도제목이 있으면 `@Generable`로 짧은 값(요약·날짜 표현·
  날짜)만 뽑고 ③ 카드 문장은 자유 텍스트로 따로 받는다 ④ 작성일 기준 달력 힌트(내일,
  이번/다음 주 요일별 날짜, 이번/다음 달 말)를 코드가 계산해 넣고, 모델이 뽑은 날짜
  표현은 `DatePhraseResolver`가 먼저 해석한다 — 해석 못 하면 모델 날짜를 쓴다 ⑤
  `SystemLanguageModel(guardrails: .permissiveContentTransformations)`, greedy
  샘플링, `guardrailViolation`은 "추천 건너뜀"으로 기록한다.
- **출력:** 기록별 PASS/FAIL과 검사 항목, 호출 수·지연 시간, 마지막에 요약 점수
  (검사 통과 수/전체), 항목별 정확도, 지연 중앙값·p90·첫 호출, guardrail 건너뜀 수.
  "데드라인(모델 날짜만)"과 "카드에 남은 제3자 이름"은 참고용으로 점수에서 뺀다.
- **프롬프트를 바꾸면 `SharePrompts.version`을 올린다.** 요약과 JSON에 찍혀서 어떤
  프롬프트의 점수인지 구분된다. 의미 있는 결과는 `docs/roadmap.md`의 성능 테스트 표에
  적는다. JSON 결과는 저장소 밖에 둔다.

## 릴리스 아카이브

### iCloud 동기화 폴더에서 archive 하지 않기

저장소가 `~/Documents` 아래에 있고 이 경로는 iCloud Drive file provider가
관리한다. 빌드 산출물에 `com.apple.FinderInfo`와
`com.apple.fileprovider.fpfs#P` 확장 속성이 계속 다시 붙고, codesign은
`resource fork, Finder information, or similar detritus not allowed`로
실패한다. 소스에 `xattr -cr`를 돌려도 빌드 중 다시 붙으므로 근본 해결이 아니다.

**archive와 derived data는 동기화되지 않는 경로에 만든다.** 서명이 끝난
아카이브를 `.release/`로 복사하는 것은 안전하다.

### 절차

0. **`docs/known-issues.md`의 릴리스 게이트를 먼저 통과한다.** 편집기 입력이
   씹히는 문제가 반복해서 되살아나고 있고, 자동화 테스트가 잡지 못한다.
   긴 기록에서 Release 빌드로 타이핑을 확인하지 않은 채 올리지 않는다.
1. 빌드 번호를 올린다. `PilgrimJournal.xcodeproj`의 `CURRENT_PROJECT_VERSION`
   두 곳(Debug·Release)을 함께 바꾸고 `build: bump TestFlight build to N`으로
   커밋한다.
2. `./scripts/check.sh`가 통과하는지 확인한다.
3. 동기화 밖 경로에 두 플랫폼 아카이브를 만든다.

   ```sh
   BUILD_ROOT=$(mktemp -d)
   for platform in iOS macOS; do
     xcodebuild \
       -project PilgrimJournal/PilgrimJournal.xcodeproj \
       -scheme PilgrimJournalApp \
       -configuration Release \
       -destination "generic/platform=$platform" \
       -archivePath "$BUILD_ROOT/PilgrimJournal-$platform.xcarchive" \
       -derivedDataPath "$BUILD_ROOT/DerivedData-$platform" \
       archive
   done
   ```

4. 아카이브의 `CFBundleVersion`이 의도한 빌드 번호인지 확인한 뒤
   `.release/build<N>/`으로 복사한다. `.release/`는 Git에서 무시된다.
5. `PilgrimJournal/AppStoreExportOptions.plist`로 export·upload 한다.

   ```sh
   xcodebuild -exportArchive \
     -archivePath "$BUILD_ROOT/PilgrimJournal-iOS.xcarchive" \
     -exportOptionsPlist PilgrimJournal/AppStoreExportOptions.plist \
     -exportPath "$BUILD_ROOT/export-iOS"
   ```

   **이 저장소에서는 API 키 인증이 실제로 통하는 경로다.** build 13을 이 방식으로
   두 플랫폼 모두 업로드했다. Xcode에 Apple 계정이 없어도 되고,
   `-allowProvisioningUpdates`가 Apple Distribution 인증서까지 처리한다.

   ```sh
   for platform in iOS macOS; do
     xcodebuild -exportArchive \
       -archivePath "$BUILD_ROOT/PilgrimJournal-$platform.xcarchive" \
       -exportOptionsPlist PilgrimJournal/AppStoreExportOptions.plist \
       -exportPath "$BUILD_ROOT/export-$platform" \
       -allowProvisioningUpdates \
       -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
       -authenticationKeyID <KEYID> \
       -authenticationKeyIssuerID "$ASC_ISSUER_ID"
   done
   ```

   Issuer ID는 App Store Connect → 사용자 및 액세스 → 통합 →
   App Store Connect API 상단의 UUID다. **저장소에 커밋하지 않는다.**
   `.p8` 키도 마찬가지로 `~/.appstoreconnect/private_keys/`에만 둔다.

   #### `Failed to Use Accounts`가 나오면

   이 오류는 원인이 두 가지이고 **로그를 봐야 구분된다.** 오류 메시지 자체는
   같지만 `.xcdistributionlogs/IDEDistribution.standard.log`에 실제 이유가 남는다.

   - `Failed to find an account with App Store Connect access for team ...`
     → **Xcode에 App Store Connect 권한이 있는 Apple 계정이 없다.** Mac 잠금과
     무관하다. `xcodebuild`는 계정을 추가할 수 없으므로 아래 둘 중 하나가 필요하다.
     - Xcode → Settings → Accounts에 Apple 계정을 추가한다, 또는
     - App Store Connect API 키로 인증한다. 키는
       `~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8`에 둔다.

       ```sh
       xcodebuild -exportArchive \
         -archivePath "$BUILD_ROOT/PilgrimJournal-iOS.xcarchive" \
         -exportOptionsPlist PilgrimJournal/AppStoreExportOptions.plist \
         -exportPath "$BUILD_ROOT/export-iOS" \
         -allowProvisioningUpdates \
         -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
         -authenticationKeyID <KEYID> \
         -authenticationKeyIssuerID <ISSUER_UUID>
       ```

       Issuer ID는 App Store Connect → 사용자 및 액세스 → 통합 →
       App Store Connect API 상단에 있는 UUID다. **저장소에 커밋하지 않는다.**
   - Keychain 접근 거부가 로그에 보이면 → 그때가 Mac 잠금 문제다. 잠금을 풀고
     다시 실행한다.

   서명에는 **Apple Distribution** 인증서가 필요하다. `security find-identity -v
   -p codesigning`에 Development만 있으면 `-allowProvisioningUpdates`와 계정
   접근으로 자동 생성하게 하거나 Xcode에서 만들어야 한다.

6. TestFlight에서 처리 완료를 확인하고 실기기 설치·업데이트·데이터 보존을
   smoke test 한다.
