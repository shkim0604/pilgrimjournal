import AuthenticationServices
import CryptoKit
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The nonce of one group sign-in (design.md 3절): 32 random bytes as lowercase hex, and
/// the Apple request carries `SHA256(rawNonce)` in lowercase hex. The server checks the token's
/// `nonce` against the hash of the `rawNonce` the app sends.
struct GroupAppleNonce: Equatable, Sendable {
    let raw: String

    init(raw: String) {
        self.raw = raw
    }

    var hashed: String { Self.sha256Hex(raw) }

    static func make() -> GroupAppleNonce {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return GroupAppleNonce(raw: bytes.map { String(format: "%02x", $0) }.joined())
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What an Apple authorization returned, reduced to the values the group sign-in needs.
struct GroupAppleCredential: Equatable, Sendable {
    var user: String
    var identityToken: Data?
    var authorizationCode: Data?
}

/// What `POST /auth/apple` needs from the Apple side.
struct GroupAppleSignInProof: Equatable, Sendable {
    var identityToken: String
    var authorizationCode: String
    var rawNonce: String
}

enum GroupAppleAuthorizationError: Error, Equatable {
    /// The journal has no signed-in Apple user to compare with.
    case noJournalUser
    /// Apple authenticated a different Apple ID than the journal session's.
    case differentUser
    /// Apple returned no identity token or authorization code.
    case missingToken
    case cancelled
    case inProgress
    case failed

    /// nil for a cancel, which needs no message.
    var message: String? {
        switch self {
        case .noJournalUser:
            String(localized: "기록장 로그인 정보를 확인할 수 없어요. 앱을 다시 열어 주세요.")
        case .differentUser:
            String(localized: "기록장에 로그인한 Apple 계정으로 인증해 주세요.")
        case .missingToken, .failed:
            String(localized: "Apple 인증을 마치지 못했어요. 다시 시도해 주세요.")
        case .inProgress:
            String(localized: "Apple 인증이 이미 진행 중이에요.")
        case .cancelled:
            nil
        }
    }
}

/// The checks between Apple's answer and the group server, as a pure function: nothing
/// reaches the server unless the Apple user is the journal session's user and Apple returned
/// both tokens.
enum GroupAppleAuthorization {
    static func verify(
        _ credential: GroupAppleCredential, journalUserIdentifier: String?, nonce: GroupAppleNonce
    ) throws -> GroupAppleSignInProof {
        let journalUser = journalUserIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let journalUser, !journalUser.isEmpty else {
            throw GroupAppleAuthorizationError.noJournalUser
        }
        guard credential.user == journalUser else {
            throw GroupAppleAuthorizationError.differentUser
        }
        guard let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
            !token.isEmpty,
            let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }),
            !code.isEmpty
        else { throw GroupAppleAuthorizationError.missingToken }
        return GroupAppleSignInProof(
            identityToken: token, authorizationCode: code, rawNonce: nonce.raw)
    }
}

/// Asks Apple to authenticate again for the group server.
@MainActor
protocol GroupAppleAuthorizing: AnyObject {
    func requestCredential(hashedNonce: String) async throws -> GroupAppleCredential
}

/// The live re-authentication: an `ASAuthorizationAppleIDProvider` request with the hashed
/// nonce and no scopes (the group server gets no name or email from Apple).
@MainActor
final class GroupAppleAuthorizer: NSObject, GroupAppleAuthorizing {
    private var continuation: CheckedContinuation<GroupAppleCredential, any Error>?
    private var controller: ASAuthorizationController?

    func requestCredential(hashedNonce: String) async throws -> GroupAppleCredential {
        guard continuation == nil else { throw GroupAppleAuthorizationError.inProgress }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        Self.configure(request, hashedNonce: hashedNonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    /// Sets up a request (also a `SignInWithAppleButton`'s) for the group sign-in.
    static func configure(_ request: ASAuthorizationAppleIDRequest, hashedNonce: String) {
        request.requestedScopes = []
        request.nonce = hashedNonce
    }

    /// The credential in a finished authorization, or the reason there is none.
    nonisolated static func credential(from result: Result<ASAuthorization, any Error>) throws
        -> GroupAppleCredential
    {
        switch result {
        case .success(let authorization):
            guard
                let credential = authorization.credential as? ASAuthorizationAppleIDCredential
            else { throw GroupAppleAuthorizationError.failed }
            return GroupAppleCredential(
                user: credential.user, identityToken: credential.identityToken,
                authorizationCode: credential.authorizationCode)
        case .failure(let error):
            if let error = error as? ASAuthorizationError, error.code == .canceled {
                throw GroupAppleAuthorizationError.cancelled
            }
            throw GroupAppleAuthorizationError.failed
        }
    }

    private func finish(_ result: Result<GroupAppleCredential, any Error>) {
        controller = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

extension GroupAppleAuthorizer: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let result = Result { try Self.credential(from: .success(authorization)) }
        MainActor.assumeIsolated { finish(result) }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController, didCompleteWithError error: any Error
    ) {
        let result = Result { try Self.credential(from: .failure(error)) }
        MainActor.assumeIsolated { finish(result) }
    }
}

extension GroupAppleAuthorizer: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController)
        -> ASPresentationAnchor
    {
        MainActor.assumeIsolated {
            #if os(iOS)
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            return windows.first(where: \.isKeyWindow) ?? windows.first ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first
                ?? ASPresentationAnchor()
            #endif
        }
    }
}
