import Crypto
import Foundation
import JWT
import PilgrimAPI
import Vapor

/// Where Apple's Sign in with Apple public keys come from (a JWKS document).
public protocol AppleJWKSSource: Sendable {
    func fetchJWKS() async throws -> Data
}

/// `GET https://appleid.apple.com/auth/keys`.
public struct LiveAppleJWKSSource: AppleJWKSSource {
    public static let url: URI = "https://appleid.apple.com/auth/keys"
    let client: any Client

    public init(client: any Client) {
        self.client = client
    }

    public func fetchJWKS() async throws -> Data {
        let response = try await client.get(Self.url)
        guard response.status == .ok, let body = response.body else {
            throw APIError(
                code: .serviceUnavailable,
                message: "Apple keys unavailable (HTTP \(response.status.code))")
        }
        return Data(buffer: body)
    }
}

/// Caches Apple's JWKS for an hour and refetches at once when a token names a key the cache
/// does not have (Apple rotates keys), at most once per `minimumRefetchInterval`.
public actor AppleJWKSCache {
    let source: any AppleJWKSSource
    let maxAge: TimeInterval
    let minimumRefetchInterval: TimeInterval
    private var cached: (jwks: Data, kids: Set<String>, fetchedAt: Date)?
    /// The last refetch caused by an unknown `kid` (throttled; a forged `kid` must not make
    /// every request call Apple).
    private var lastUnknownKidFetchAt: Date?

    public init(
        source: any AppleJWKSSource, maxAge: TimeInterval = 3_600,
        minimumRefetchInterval: TimeInterval = 10
    ) {
        self.source = source
        self.maxAge = maxAge
        self.minimumRefetchInterval = minimumRefetchInterval
    }

    /// The JWKS document, refreshed when stale or when it lacks `kid`.
    public func jwks(containing kid: String, now: Date = Date()) async throws -> Data {
        if let cached, now.timeIntervalSince(cached.fetchedAt) < maxAge {
            if cached.kids.contains(kid) { return cached.jwks }
            if let lastUnknownKidFetchAt,
                now.timeIntervalSince(lastUnknownKidFetchAt) < minimumRefetchInterval
            {
                return cached.jwks
            }
            lastUnknownKidFetchAt = now
        }
        let data = try await source.fetchJWKS()
        let kids = try Self.keyIDs(in: data)
        cached = (data, kids, now)
        return data
    }

    static func keyIDs(in jwks: Data) throws -> Set<String> {
        struct KeySet: Decodable {
            struct Key: Decodable { var kid: String? }
            var keys: [Key]
        }
        return Set(try JSONDecoder().decode(KeySet.self, from: jwks).keys.compactMap(\.kid))
    }
}

/// The verified parts of an Apple identity token.
public struct AppleIdentity: Sendable, Equatable {
    /// Apple's stable user ID (`sub`).
    public var subject: String
    public var bundleID: String
}

/// Checks a Sign in with Apple `identityToken` (design.md 3절 step 4): RS256 signature by a key in
/// Apple's JWKS, `iss`, `aud` = the request's bundle ID (one of the two allowed), `exp`, and
/// `nonce == SHA256(rawNonce)` in lowercase hex.
public struct AppleIdentityTokenVerifier: Sendable {
    public static let issuer = "https://appleid.apple.com"

    let cache: AppleJWKSCache
    let allowedBundleIDs: Set<String>

    public init(cache: AppleJWKSCache, allowedBundleIDs: Set<String> = BundleIDs.all) {
        self.cache = cache
        self.allowedBundleIDs = allowedBundleIDs
    }

    public func verify(
        identityToken: String, bundleID: String, rawNonce: String, now: Date = Date()
    ) async throws -> AppleIdentity {
        guard allowedBundleIDs.contains(bundleID) else {
            throw APIError.invalidRequest("unknown bundleId")
        }
        // `JWTSigners` falls back to its default key for an unknown `kid`, so read the header
        // here and pick the key ourselves.
        guard let header = JWTSegments.header(of: identityToken), header.alg == "RS256",
            let kid = header.kid, !kid.isEmpty
        else { throw Self.invalid("malformed identity token") }

        let jwksData = try await cache.jwks(containing: kid, now: now)
        let claims: AppleIdentityClaims
        do {
            let jwks = try JSONDecoder().decode(JWKS.self, from: jwksData)
            guard let key = jwks.keys.first(where: { $0.keyIdentifier?.string == kid }) else {
                throw Self.invalid("unknown key id")
            }
            let signers = JWTSigners()
            try signers.use(jwk: key, isDefault: true)
            claims = try signers.verify(identityToken, as: AppleIdentityClaims.self)
        } catch let error as APIError {
            throw error
        } catch {
            throw Self.invalid("identity token signature is invalid")
        }

        guard claims.iss.value == Self.issuer else { throw Self.invalid("wrong issuer") }
        guard claims.aud.value.contains(bundleID) else { throw Self.invalid("wrong audience") }
        guard claims.exp.value > now else { throw Self.invalid("identity token expired") }
        guard !claims.sub.value.isEmpty else { throw Self.invalid("missing subject") }

        let expectedNonce = Self.nonceHash(rawNonce)
        guard let nonce = claims.nonce,
            Self.constantTimeEquals(Data(nonce.utf8), Data(expectedNonce.utf8))
        else {
            throw APIError(code: .appleNonceMismatch, message: "nonce does not match")
        }
        return AppleIdentity(subject: claims.sub.value, bundleID: bundleID)
    }

    /// `SHA256(rawNonce)` as lowercase hex — what the app put in the Apple request.
    public static func nonceHash(_ rawNonce: String) -> String {
        SHA256.hash(data: Data(rawNonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    static func invalid(_ message: String) -> APIError {
        APIError(code: .appleTokenInvalid, message: message)
    }
}

/// The claims of an Apple identity token this server reads. Checks run in the verifier, after
/// the signature, so this type's `verify(using:)` does nothing.
struct AppleIdentityClaims: JWTPayload {
    var iss: IssuerClaim
    var sub: SubjectClaim
    var aud: AudienceClaim
    var exp: ExpirationClaim
    var nonce: String?

    func verify(using signer: JWTSigner) throws {}
}

/// Reads the unverified header and payload of a compact JWS.
enum JWTSegments {
    struct Header: Decodable {
        var alg: String?
        var kid: String?
    }

    static func header(of token: String) -> Header? {
        segment(0, of: token).flatMap { try? JSONDecoder().decode(Header.self, from: $0) }
    }

    /// The decoded payload JSON (no signature check).
    static func payload(of token: String) -> Data? {
        segment(1, of: token)
    }

    private static func segment(_ index: Int, of token: String) -> Data? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        return Data(base64URLEncoded: String(parts[index]))
    }
}
