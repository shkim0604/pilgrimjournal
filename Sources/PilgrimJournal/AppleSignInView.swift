import AuthenticationServices
import JournalData
import SwiftUI

struct AppleSignInView: View {
    @EnvironmentObject private var authentication: AppleAuthenticationCoordinator

    private var guidance: BlockedSignInGuidance? {
        BlockedSignInGuidance(state: authentication.state)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "book.pages.fill")
                .font(.system(size: 58))
                .foregroundStyle(JournalTheme.brandPrimary)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Pilgrim Journal")
                    .font(.largeTitle.bold())
                    .foregroundStyle(JournalTheme.ink)
                Text("나만의 기록을 안전하게 이어가세요")
                    .font(.title3)
                    .foregroundStyle(JournalTheme.inkSecondary)
            }

            if let guidance {
                VStack(spacing: 12) {
                    Label(guidance.title, systemImage: guidance.systemImage)
                        .font(.headline)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(guidance.steps, id: \.self) { step in
                            Label(step, systemImage: "arrow.forward.circle")
                                .font(.callout)
                                .foregroundStyle(JournalTheme.inkSecondary)
                        }
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 440)
            } else {
                Text(
                    "Apple 로그인은 일기 화면 접근에만 사용합니다. Apple이 제공한 이메일은 현재 계정 표시를 위해 기기 Keychain에 저장합니다."
                )
                .font(.callout)
                .foregroundStyle(JournalTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            }

            if guidance?.offersCloudRecheck == true {
                Button("iCloud 연결 다시 확인") {
                    Task { await authentication.refreshCloudIdentityBinding() }
                }
                .buttonStyle(.borderedProminent)

                Button("다른 Apple 계정으로 로그인") {
                    Task { await authentication.signOut() }
                }
                .buttonStyle(.borderless)
            } else {
                SignInWithAppleButton(.signIn) { request in
                    request.requestedScopes = [.email]
                } onCompletion: { result in
                    switch result {
                    case let .success(authorization):
                        guard
                            let credential = authorization.credential
                                as? ASAuthorizationAppleIDCredential
                        else {
                            authentication.errorMessage = "Apple 로그인 정보를 확인할 수 없습니다."
                            return
                        }
                        Task {
                            await authentication.acceptAuthorizedUser(
                                identifier: credential.user,
                                email: credential.email
                            )
                        }
                    case let .failure(error):
                        authentication.handleSignInFailure(error)
                    }
                }
                .signInWithAppleButtonStyle(.black)
                .frame(width: 280, height: 48)
                .accessibilityHint("Apple 계정으로 Pilgrim Journal에 로그인합니다.")
            }

            if let errorMessage = authentication.errorMessage,
                guidance?.shouldShow(errorMessage: errorMessage) ?? true
            {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Label(
                "일기 내용은 자체 서버로 전송하지 않습니다.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.tertiary)

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JournalTheme.canvas)
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 540)
        #endif
    }
}

struct AppleAuthenticationCheckingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Apple 로그인 상태 확인 중")
                .foregroundStyle(JournalTheme.inkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(JournalTheme.canvas)
    }
}

/// What the sign-in screen tells the user when the journal is blocked, and
/// the way out. Neither block deletes anything; it only refuses to show one
/// Apple account's records to another.
struct BlockedSignInGuidance: Equatable {
    var title: String
    var systemImage: String
    var steps: [String]
    /// Whether "check iCloud again" can help, i.e. the fix happens outside
    /// the app (switching the device's iCloud account).
    var offersCloudRecheck: Bool
    /// The coordinator's error text for this state, which `title` already says.
    private var restatedError: String

    init?(state: AppleAuthenticationCoordinator.State) {
        switch state {
        case .blockedDifferentUser:
            title = "이 기기의 기록은 다른 Apple 계정에 연결되어 있습니다."
            systemImage = "person.crop.circle.badge.exclamationmark"
            steps = [
                "기록을 처음 만든 Apple 계정으로 다시 로그인하세요.",
                "다른 계정의 기록은 보호를 위해 열거나 합치지 않습니다. 기록은 삭제되지 않았습니다.",
            ]
            offersCloudRecheck = false
            restatedError = AppleAuthenticationSessionError.differentUser.localizedDescription
        case .blockedCloudAccountMismatch:
            title = "현재 iCloud는 다른 Apple 계정에 연결되어 있습니다."
            systemImage = "icloud.slash"
            steps = [
                "이 iCloud를 처음 연결한 Apple 계정으로 로그인하세요.",
                "또는 기기 설정에서 다른 iCloud 계정으로 바꾼 뒤 ‘iCloud 연결 다시 확인’을 누르세요.",
                "어느 쪽 기록도 삭제되지 않았습니다.",
            ]
            offersCloudRecheck = true
            restatedError = AppleAuthenticationCoordinator.cloudAccountMismatchMessage
        case .checking, .signedOut, .authenticated, .failed:
            return nil
        }
    }

    /// Hides only the error that repeats this guidance, so a different
    /// failure (say, the iCloud re-check failing) is still shown.
    func shouldShow(errorMessage: String) -> Bool {
        errorMessage != restatedError
    }
}
