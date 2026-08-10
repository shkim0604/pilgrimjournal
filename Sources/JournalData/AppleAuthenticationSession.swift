import Foundation

public struct AppleAuthenticationSession: Codable, Equatable, Sendable {
    public var currentUserIdentifier: String?
    public var boundUserIdentifier: String?
    public var accountEmail: String?
    public var lastAuthorizedAt: Date?

    public init(
        currentUserIdentifier: String? = nil,
        boundUserIdentifier: String? = nil,
        accountEmail: String? = nil,
        lastAuthorizedAt: Date? = nil
    ) {
        self.currentUserIdentifier = currentUserIdentifier
        self.boundUserIdentifier = boundUserIdentifier
        self.accountEmail = accountEmail
        self.lastAuthorizedAt = lastAuthorizedAt
    }

    public var hasOfflineSession: Bool {
        currentUserIdentifier != nil && lastAuthorizedAt != nil
    }
}

public enum AppleAuthenticationSessionError: LocalizedError, Equatable, Sendable {
    case invalidUserIdentifier
    case differentUser
    case malformedState

    public var errorDescription: String? {
        switch self {
        case .invalidUserIdentifier:
            "Apple 로그인 사용자 정보를 확인할 수 없습니다."
        case .differentUser:
            "이 기기의 기존 기록은 다른 Apple 사용자에게 연결되어 있습니다."
        case .malformedState:
            "저장된 Apple 로그인 상태를 읽을 수 없습니다."
        }
    }
}

public actor AppleAuthenticationSessionService {
    private struct StoredState: Codable {
        var version = 1
        var currentUserIdentifier: String?
        var boundUserIdentifier: String?
        var accountEmail: String?
        var lastAuthorizedAt: Date?
    }

    private let store: any SecureValueStore

    public init(
        store: any SecureValueStore = KeychainSecureValueStore(
            service: "com.dhouse.PilgrimJournal.apple-authentication",
            account: "device-session"
        )
    ) {
        self.store = store
    }

    public func session() throws -> AppleAuthenticationSession {
        guard let state = try loadState() else {
            return AppleAuthenticationSession()
        }
        return AppleAuthenticationSession(
            currentUserIdentifier: state.currentUserIdentifier,
            boundUserIdentifier: state.boundUserIdentifier,
            accountEmail: state.accountEmail,
            lastAuthorizedAt: state.lastAuthorizedAt
        )
    }

    @discardableResult
    public func acceptAuthorizedUser(
        identifier: String,
        email: String? = nil,
        at date: Date = .now
    ) throws -> AppleAuthenticationSession {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw AppleAuthenticationSessionError.invalidUserIdentifier
        }

        var state = try loadState() ?? StoredState()
        if let bound = state.boundUserIdentifier, bound != identifier {
            throw AppleAuthenticationSessionError.differentUser
        }
        state.boundUserIdentifier = state.boundUserIdentifier ?? identifier
        state.currentUserIdentifier = identifier
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            state.accountEmail = email
        }
        state.lastAuthorizedAt = date
        try save(state)
        return try session()
    }

    public func clearCurrentSession() throws {
        guard var state = try loadState() else { return }
        state.currentUserIdentifier = nil
        state.lastAuthorizedAt = nil
        try save(state)
    }

    private func loadState() throws -> StoredState? {
        guard let data = try store.load() else { return nil }
        guard let state = try? JSONDecoder().decode(StoredState.self, from: data),
              state.version == 1 else {
            throw AppleAuthenticationSessionError.malformedState
        }
        return state
    }

    private func save(_ state: StoredState) throws {
        try store.save(JSONEncoder().encode(state))
    }
}
