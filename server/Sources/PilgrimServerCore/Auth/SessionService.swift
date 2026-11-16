import Crypto
import Fluent
import Foundation
import PilgrimAPI
import SQLKit

/// The tokens of a new or rotated group session.
public struct IssuedSession: Sendable, Equatable {
    public var userID: UUID
    public var familyID: UUID
    public var accessToken: String
    public var accessTokenExpiresAt: Date
    public var refreshToken: String
    public var refreshTokenExpiresAt: Date
}

/// Refresh tokens (design.md 3절): 32 random bytes as base64url; only the SHA-256 is stored;
/// 90 days; every use rotates within the same family; reuse revokes the family, except a retry
/// from the same installation within 30 seconds whose replacement was never used.
public enum SessionService {
    public static func generateRefreshToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncodedString()
    }

    public static func hash(refreshToken token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    /// A new family for a sign-in.
    public static func startSession(
        userID: UUID, installationID: UUID, accessTokens: AccessTokenService,
        on db: any Database, now: Date = Date()
    ) async throws -> IssuedSession {
        try await mint(
            userID: userID, familyID: UUID(), installationID: installationID,
            accessTokens: accessTokens, on: db, now: now
        ).session
    }

    enum RotationResult: Sendable {
        case rotated(IssuedSession)
        case reused
        case invalid
    }

    /// `POST /auth/refresh`. Throws 401 `REFRESH_TOKEN_INVALID` or `REFRESH_TOKEN_REUSED`.
    public static func rotate(
        refreshToken token: String, installationID: UUID, accessTokens: AccessTokenService,
        on db: any Database, now: Date = Date()
    ) async throws -> IssuedSession {
        let tokenHash = hash(refreshToken: token)
        // The family revocation must commit before the 401, so the transaction returns the
        // outcome and the error is thrown afterwards.
        let result = try await db.transaction { tx -> RotationResult in
            guard
                let found = try await RefreshToken.query(on: tx)
                    .filter(\.$tokenHash == tokenHash).first(),
                let current = try await lock(try found.requireID(), on: tx)
            else { return .invalid }
            guard current.revokedAt == nil, current.expiresAt > now else { return .invalid }

            guard let usedAt = current.usedAt else {
                let minted = try await mint(
                    userID: current.$user.id, familyID: current.familyID,
                    installationID: current.installationID, accessTokens: accessTokens, on: tx,
                    now: now)
                current.usedAt = now
                current.replacedByID = minted.rowID
                try await current.save(on: tx)
                return .rotated(minted.session)
            }

            if current.installationID == installationID,
                now.timeIntervalSince(usedAt) <= SessionLifetime.refreshRetryGrace,
                let replacementID = current.replacedByID,
                let replacement = try await lock(replacementID, on: tx),
                replacement.usedAt == nil, replacement.revokedAt == nil
            {
                replacement.revokedAt = now
                try await replacement.save(on: tx)
                let minted = try await mint(
                    userID: current.$user.id, familyID: current.familyID,
                    installationID: current.installationID, accessTokens: accessTokens, on: tx,
                    now: now)
                current.replacedByID = minted.rowID
                try await current.save(on: tx)
                return .rotated(minted.session)
            }

            try await revokeFamily(current.familyID, on: tx, now: now)
            return .reused
        }
        switch result {
        case .rotated(let session):
            return session
        case .reused:
            throw APIError(
                code: .refreshTokenReused, message: "refresh token reused; session revoked")
        case .invalid:
            throw APIError(code: .refreshTokenInvalid, message: "refresh token is not valid")
        }
    }

    /// `POST /auth/logout`: revokes the token's family when it belongs to `userID`.
    public static func revokeFamily(
        ofRefreshToken token: String, userID: UUID, on db: any Database, now: Date = Date()
    ) async throws {
        let tokenHash = hash(refreshToken: token)
        guard
            let row = try await RefreshToken.query(on: db)
                .filter(\.$tokenHash == tokenHash).first(),
            row.$user.id == userID
        else { return }
        try await revokeFamily(row.familyID, on: db, now: now)
    }

    static func revokeFamily(_ familyID: UUID, on db: any Database, now: Date) async throws {
        try await RefreshToken.query(on: db)
            .filter(\.$familyID == familyID)
            .filter(\.$revokedAt == nil)
            .set(\.$revokedAt, to: now)
            .update()
    }

    /// Locks the row (`SELECT … FOR UPDATE`) and reads it again.
    private static func lock(_ id: UUID, on db: any Database) async throws -> RefreshToken? {
        let sql = try PushOutbox.sqlDatabase(db)
        guard
            try await sql.raw("SELECT id FROM refresh_tokens WHERE id = \(bind: id) FOR UPDATE")
                .first() != nil
        else { return nil }
        return try await RefreshToken.find(id, on: db)
    }

    private static func mint(
        userID: UUID, familyID: UUID, installationID: UUID, accessTokens: AccessTokenService,
        on db: any Database, now: Date
    ) async throws -> (session: IssuedSession, rowID: UUID) {
        let refreshToken = generateRefreshToken()
        let expiresAt = now.addingTimeInterval(SessionLifetime.refreshToken)
        let row = RefreshToken(
            userID: userID, familyID: familyID, tokenHash: hash(refreshToken: refreshToken),
            installationID: installationID, issuedAt: now, expiresAt: expiresAt)
        try await row.create(on: db)
        let access = try accessTokens.issue(userID: userID, sessionID: familyID, now: now)
        let session = IssuedSession(
            userID: userID, familyID: familyID, accessToken: access.token,
            accessTokenExpiresAt: access.expiresAt, refreshToken: refreshToken,
            refreshTokenExpiresAt: expiresAt)
        return (session, try row.requireID())
    }
}
