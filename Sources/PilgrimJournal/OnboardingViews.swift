import JournalDomain
import SwiftUI

struct OnboardingView: View {
    let completion: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "book.pages.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(JournalTheme.brandPrimary)
                        Text("나만의 기록을 한곳에")
                            .font(.largeTitle.bold())
                            .foregroundStyle(JournalTheme.ink)
                        Text("기도노트, 성경공부, 독서노트와 일기를 Mac과 iPhone에서 이어서 작성하세요.")
                            .font(.title3)
                            .foregroundStyle(JournalTheme.inkSecondary)
                    }

                    informationRow(
                        icon: "person.crop.circle.badge.checkmark",
                        title: "Apple 로그인으로 접근합니다",
                        description:
                            "별도 비밀번호 없이 Apple로 로그인합니다. 앱은 고유 사용자 식별자와 Apple이 제공한 이메일을 계정 표시용으로 기기 Keychain에 저장합니다."
                    )
                    informationRow(
                        icon: "icloud",
                        title: "내 iCloud 개인 저장 공간",
                        description:
                            "현재 시스템 iCloud의 개인 데이터베이스를 로그인한 Apple 사용자에게 안전하게 연결합니다. 다른 Apple 사용자가 같은 저장 공간을 열면 차단하며, iCloud를 사용할 수 없을 때는 이 기기에서만 계속 쓸 수 있습니다."
                    )
                    informationRow(
                        icon: "server.rack",
                        title: "자체 일기 서버가 없습니다",
                        description:
                            "Pilgrim Journal은 일기 내용을 자체 서버, 광고 서버 또는 분석 서버로 보내지 않습니다. Day One 원본 snapshot과 검색 인덱스는 가져온 Mac에만 둡니다."
                    )
                    informationRow(
                        icon: "lock.app.dashed",
                        title: "앱 잠금의 보호 범위",
                        description:
                            "기기별 비밀번호와 Face ID·Touch ID는 앱 화면과 앱 전환기 미리보기를 가립니다. 데이터베이스나 CloudKit 기록을 별도 비밀번호로 종단 간 암호화하는 기능은 아닙니다."
                    )
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(32)
            }
            .safeAreaInset(edge: .bottom) {
                Button("시작하기") { completion() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.bar)
            }
            .navigationTitle("Pilgrim Journal")
            .background(JournalTheme.canvas)
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
        .interactiveDismissDisabled()
    }

    private func informationRow(
        icon: String,
        title: LocalizedStringKey,
        description: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(JournalTheme.brandPrimary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(JournalTheme.ink)
                Text(description)
                    .foregroundStyle(JournalTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct PrivacyInformationView: View {
    let syncState: SyncState

    var body: some View {
        List {
            Section("계정과 동기화") {
                Label("Apple 로그인 접근 인증", systemImage: "person.crop.circle.badge.checkmark")
                Text(
                    "앱은 Apple 로그인의 고유 사용자 식별자와 Apple이 제공한 이메일을 기기 Keychain에 저장합니다. Apple ID 비밀번호는 요청하거나 저장하지 않습니다."
                )
                Text("Apple 로그인은 일기 화면 접근용이며, 기록 동기화에는 별도로 기기의 시스템 iCloud 개인 데이터베이스를 사용합니다.")
                Text(
                    "최초 연결한 Apple 사용자와 현재 iCloud 저장 공간의 연결이 다르면 기록 화면을 열지 않습니다. 계정 비교에는 이메일이 아닌 Apple의 고유 사용자 식별자를 사용합니다."
                )
                LabeledContent("현재 저장 상태", value: syncDescription)
                Text(
                    "CloudKit 동기화 데이터는 사용자의 iCloud 용량을 사용합니다. 인증 후 local-only 상태의 기록은 다른 기기로 전송되지 않습니다."
                )
            }

            Section("데이터 전송") {
                Label("자체 일기 서버 없음", systemImage: "server.rack")
                Text("기록을 광고·분석 서버 또는 공개 CloudKit 데이터베이스로 보내지 않습니다.")
                Label("Mac에만 남는 데이터", systemImage: "desktopcomputer")
                Text("Day One 전체 원본 snapshot, 가져오기 감사 기록과 검색 인덱스는 가져온 Mac의 로컬 저장소에만 둡니다.")
            }

            Section("앱 잠금") {
                Label("화면 보호 기능", systemImage: "lock.app.dashed")
                Text(
                    "앱 잠금은 이 기기에서 제목·본문·검색 결과와 앱 전환기 snapshot을 가립니다. 비밀번호 verifier와 설정도 기기별 Keychain에만 저장됩니다."
                )
                Text("앱 잠금 비밀번호는 데이터베이스 또는 CloudKit 데이터 자체를 종단 간 암호화하는 별도 키가 아닙니다.")
                    .foregroundStyle(.secondary)
            }

            Section("계정 삭제") {
                Label("앱 안에서 삭제", systemImage: "person.crop.circle.badge.xmark")
                Text(
                    "설정 › Apple 로그인 › 계정 삭제에서 iCloud에 저장된 기록과 첨부, 이 기기의 데이터, 로그인 정보와 앱 잠금 설정을 삭제할 수 있습니다."
                )
                Text(
                    "자체 서버가 없으므로 Apple 로그인 연결은 삭제 후 기기 설정에서 끊습니다: \(AccountDeletionGuidance.unlinkPath)"
                )
                .foregroundStyle(.secondary)
            }

            Section("지원") {
                Link(destination: SupportLinks.supportPage) {
                    Label("지원 페이지", systemImage: "safari")
                }
                Link(destination: SupportLinks.contactMail) {
                    Label("이메일 문의 · \(SupportLinks.contactEmail)", systemImage: "envelope")
                }
            }
        }
        .navigationTitle("데이터 및 개인정보")
    }

    private var syncDescription: String {
        switch syncState {
        case .localOnly: String(localized: "이 기기에만 저장")
        case .savedLocally: String(localized: "이 기기에 저장됨")
        case .pending: String(localized: "CloudKit 동기화 대기")
        case .synced: String(localized: "CloudKit 동기화됨")
        case let .unavailable(reason): String(localized: "iCloud 사용 불가: \(reason)")
        case let .failed(message, _): String(localized: "동기화 오류: \(message)")
        }
    }
}
