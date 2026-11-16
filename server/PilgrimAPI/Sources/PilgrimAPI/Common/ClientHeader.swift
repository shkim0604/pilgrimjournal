import Foundation

/// The `X-Pilgrim-Client` header: `<platform>/<marketingVersion> (<build>) <bundleId>`,
/// for example `ios/1.3.0 (31) com.dhouse.PilgrimJournal` (design.md 2절).
///
/// Required on every `/api/v1/*` request. Missing, malformed or older than `MIN_CLIENT_VERSION`
/// → 426 `CLIENT_UPGRADE_REQUIRED`; a bundle ID outside `BundleIDs.all` → 400.
public struct ClientHeader: Equatable, Sendable, CustomStringConvertible {
    public static let name = "X-Pilgrim-Client"

    public var platform: ClientPlatform
    public var version: ClientVersion
    public var build: String
    public var bundleID: String

    public init(platform: ClientPlatform, version: ClientVersion, build: String, bundleID: String) {
        self.platform = platform
        self.version = version
        self.build = build
        self.bundleID = bundleID
    }

    /// Parses the header value. Returns nil for anything malformed (the server answers 426).
    public init?(_ value: String) {
        let parts = value.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let platformAndVersion = parts[0].split(
            separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard platformAndVersion.count == 2,
            let platform = ClientPlatform(rawValue: String(platformAndVersion[0])),
            let version = ClientVersion(String(platformAndVersion[1]))
        else { return nil }
        let buildPart = parts[1]
        guard buildPart.count > 2, buildPart.first == "(", buildPart.last == ")" else {
            return nil
        }
        let build = buildPart.dropFirst().dropLast()
        guard build.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") })
        else { return nil }
        let bundleID = parts[2]
        guard !bundleID.isEmpty,
            bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-".contains($0)) })
        else { return nil }
        self.init(
            platform: platform, version: version, build: String(build), bundleID: String(bundleID)
        )
    }

    public var description: String {
        "\(platform.rawValue)/\(version) (\(build)) \(bundleID)"
    }

    /// Whether the bundle ID is one of the two app bundles.
    public var isKnownBundle: Bool { BundleIDs.all.contains(bundleID) }
}

public enum ClientPlatform: String, Sendable, Codable, CaseIterable {
    case ios, macos
}

/// A dotted numeric marketing version (`1.3.0`), compared component by component with missing
/// components treated as 0 (`1.3 == 1.3.0`).
public struct ClientVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                let number = Int(part)
            else { return nil }
            components.append(number)
        }
        self.components = components
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: ClientVersion, rhs: ClientVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: ClientVersion, rhs: ClientVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public func hash(into hasher: inout Hasher) {
        var trimmed = components
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }
}
