import AuthenticationServices
import SwiftUI

struct AppleSignInView: View {
    @EnvironmentObject private var authentication: AppleAuthenticationCoordinator

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

            if authentication.state == .blockedDifferentUser {
                Label(
                    "이 기기의 기존 기록은 다른 Apple 사용자에게 연결되어 있습니다.",
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            } else if authentication.state == .blockedCloudAccountMismatch {
                Label(
                    "현재 iCloud는 다른 Apple 로그인 사용자에게 연결되어 있습니다.",
                    systemImage: "icloud.slash"
                )
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            } else {
                Text(
                    "Apple 로그인은 일기 화면 접근에만 사용합니다. Apple이 제공한 이메일은 현재 계정 표시를 위해 기기 Keychain에 저장합니다."
                )
                .font(.callout)
                .foregroundStyle(JournalTheme.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            }

            if authentication.state == .blockedCloudAccountMismatch {
                Button("iCloud 연결 다시 확인") {
                    Task { await authentication.refreshCloudIdentityBinding() }
                }
                .buttonStyle(.borderedProminent)

                Button("Apple 로그인 로그아웃") {
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

            if let errorMessage = authentication.errorMessage {
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
