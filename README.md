# Pilgrim Journal

Day One 기록을 가져와 기도노트, 성경공부, 독서노트, 일기로 관리하는
Apple 플랫폼용 로컬 우선 일기장입니다.

## 대상

- iPhone: iOS 17 이상
- Mac: macOS 14 이상
- 로그인: 이름·이메일을 수집하지 않는 Sign in with Apple
- 데이터 동기화: 로그인과 별도로 시스템 iCloud의 CloudKit 개인 DB 사용
- 보안: 기기별 선택적 앱 잠금과 Face ID·Touch ID

## 현재 개발 환경

공유 코드는 Swift Package로 분리되어 있어 macOS Command Line Tools만으로도
도메인, 가져오기, 검색, 백업 테스트를 실행할 수 있습니다.
앱 실행은 Sign in with Apple entitlement와 Developer Team 서명이 필요하므로
Xcode project에서 수행합니다. 전체 Xcode 구성에서는 같은 domain protocol의
SwiftData·CloudKit adapter를 사용합니다.

```sh
swift test
```

iPhone 앱 빌드, Simulator, Apple 로그인·CloudKit entitlement와 실제 기기 검증에는
전체 Xcode 설치와 Apple Developer Program team이 필요합니다.

## 개인정보

개인 Day One ZIP은 저장소나 테스트 로그에 넣지 않습니다. 테스트는 실제 샘플의
구조만 재현한 익명 fixture를 사용합니다.
