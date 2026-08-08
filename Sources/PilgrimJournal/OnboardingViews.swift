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
                            .foregroundStyle(.tint)
                        Text("나만의 기록을 한곳에")
                            .font(.largeTitle.bold())
                        Text("기도노트, 성경공부, 독서노트와 일기를 Mac과 iPhone에서 이어서 작성하세요.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    informationRow(
                        icon: "person.crop.circle.badge.checkmark",
                        title: "별도 앱 계정이 없습니다",
                        description: "Apple로 로그인하거나 새 회원가입을 하지 않습니다. 동기화할 때는 기기에 로그인된 시스템 iCloud 계정을 사용하며, 앱이 Apple ID 비밀번호·이름·이메일을 요청하거나 저장하지 않습니다."
                    )
                    informationRow(
                        icon: "icloud",
                        title: "내 iCloud 개인 저장 공간",
                        description: "동기화를 켜면 기록과 첨부가 CloudKit 개인 데이터베이스에 저장되고 사용자의 iCloud 용량을 사용합니다. iCloud를 사용할 수 없으면 이 기기에만 저장되는 local-only 상태로 계속 쓸 수 있습니다."
                    )
                    informationRow(
                        icon: "server.rack",
                        title: "자체 일기 서버가 없습니다",
                        description: "Pilgrim Journal은 일기 내용을 자체 서버, 광고 서버 또는 분석 서버로 보내지 않습니다. Day One 원본 snapshot과 검색 인덱스는 가져온 Mac에만 둡니다."
                    )
                    informationRow(
                        icon: "lock.app.dashed",
                        title: "앱 잠금의 보호 범위",
                        description: "기기별 비밀번호와 Face ID·Touch ID는 앱 화면과 앱 전환기 미리보기를 가립니다. 데이터베이스나 CloudKit 기록을 별도 비밀번호로 종단 간 암호화하는 기능은 아닙니다."
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
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 640)
        #endif
        .interactiveDismissDisabled()
    }

    private func informationRow(
        icon: String,
        title: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .foregroundStyle(.secondary)
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
                Label("별도 회원가입·Apple 로그인이 없습니다", systemImage: "person.crop.circle")
                Text("기기에 로그인된 시스템 iCloud 계정만 사용합니다. 앱은 Apple ID 자격 증명, 이름 또는 이메일을 요청하거나 저장하지 않습니다.")
                LabeledContent("현재 저장 상태", value: syncDescription)
                Text("CloudKit 동기화 데이터는 사용자의 iCloud 용량을 사용합니다. local-only 상태의 기록은 다른 기기로 전송되지 않습니다.")
            }

            Section("데이터 전송") {
                Label("자체 일기 서버 없음", systemImage: "server.rack")
                Text("기록을 광고·분석 서버 또는 공개 CloudKit 데이터베이스로 보내지 않습니다.")
                Label("Mac에만 남는 데이터", systemImage: "desktopcomputer")
                Text("Day One 전체 원본 snapshot, 가져오기 감사 기록과 검색 인덱스는 가져온 Mac의 로컬 저장소에만 둡니다.")
            }

            Section("앱 잠금") {
                Label("화면 보호 기능", systemImage: "lock.app.dashed")
                Text("앱 잠금은 이 기기에서 제목·본문·검색 결과와 앱 전환기 snapshot을 가립니다. 비밀번호 verifier와 설정도 기기별 Keychain에만 저장됩니다.")
                Text("앱 잠금 비밀번호는 데이터베이스 또는 CloudKit 데이터 자체를 종단 간 암호화하는 별도 키가 아닙니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("데이터 및 개인정보")
    }

    private var syncDescription: String {
        switch syncState {
        case .localOnly: "이 기기에만 저장"
        case .savedLocally: "이 기기에 저장됨"
        case .pending: "CloudKit 동기화 대기"
        case .synced: "CloudKit 동기화됨"
        case let .unavailable(reason): "iCloud 사용 불가: \(reason)"
        case let .failed(message, _): "동기화 오류: \(message)"
        }
    }
}
