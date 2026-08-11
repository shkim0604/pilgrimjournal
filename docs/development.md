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
       -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_3238RJ28P3.p8 \
       -authenticationKeyID 3238RJ28P3 \
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
