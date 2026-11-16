import Foundation
import PilgrimAPI

/// Invite links and codes as people type, paste or scan them (design.md 6절).
///
/// Accepts `https://pilgrim.delight-house.org/i/<code>` (any case, trailing slash, query), a
/// bare code (`ABCD-EFGH-JKMN`, lowercase, `I`/`L`/`O` look-alikes) and a link without a scheme
/// (`pilgrim.delight-house.org/i/<code>`). Links to other hosts are rejected so a QR code for
/// some other site never turns into a join attempt.
public enum InviteLink {
    /// The hosts whose `/i/<code>` links are invites.
    public static let defaultHosts: Set<String> = [APIPaths.productionBaseURL.host ?? ""]

    /// The invite code in `input`, or nil.
    public static func code(from input: String, allowedHosts: Set<String> = defaultHosts)
        -> InviteCode?
    {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return code(from: url, allowedHosts: allowedHosts)
        }
        if trimmed.contains("/") {
            guard let url = URL(string: "https://" + trimmed) else { return nil }
            return code(from: url, allowedHosts: allowedHosts)
        }
        return InviteCode(normalizing: trimmed)
    }

    /// The invite code of a Universal Link or scanned URL, or nil for any other URL.
    public static func code(from url: URL, allowedHosts: Set<String> = defaultHosts)
        -> InviteCode?
    {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
            let host = url.host?.lowercased(),
            allowedHosts.contains(where: { $0.lowercased() == host })
        else { return nil }
        return InviteCode(url: url)
    }

    /// `https://<server>/i/<code>` (also the QR payload).
    public static func url(for code: InviteCode, serverURL: URL = APIPaths.productionBaseURL)
        -> URL
    {
        code.url(base: serverURL)
    }

    /// The hosts to accept for a configuration (its own host plus production).
    public static func allowedHosts(for configuration: GroupServerConfiguration) -> Set<String> {
        var hosts = defaultHosts
        if let host = configuration.serverURL.host { hosts.insert(host) }
        return hosts
    }
}
