import Foundation
import PilgrimAPI
import Vapor

/// Web module — owned by task S2 (openspec/changes/add-private-groups/tasks.md).
///
/// `/.well-known/apple-app-site-association` and the `/i/:code` page, on `routes.root`.
///
/// `configure` calls `register(_:)` once, after the shared route groups (`app.pilgrimRoutes`)
/// exist, in both `serve` and `worker`. Only edit files in this folder.
///
/// Neither route checks `X-Pilgrim-Client` or touches the database (design.md 6절): the invite
/// page never says whether a code exists or which group it belongs to.
enum WebModule {
    /// The team that signs both app bundles; `APPLE_TEAM_ID` overrides it.
    static let defaultTeamID = "7JZU3246YR"

    static func register(_ app: Application) throws {
        let root = app.pilgrimRoutes.root
        let teamID = app.pilgrimConfig.appleTeamID ?? defaultTeamID
        let association = try appSiteAssociation(teamID: teamID)

        root.get(".well-known", "apple-app-site-association") { _ -> Response in
            var headers = HTTPHeaders()
            headers.contentType = .json
            headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=3600")
            return Response(status: .ok, headers: headers, body: .init(data: association))
        }

        root.get("i", ":code") { req -> Response in
            let raw = req.parameters.get("code") ?? ""
            let base = req.pilgrimConfig.publicBaseURL
            var headers = HTTPHeaders()
            headers.contentType = .html
            headers.replaceOrAdd(name: "X-Robots-Tag", value: "noindex")
            headers.replaceOrAdd(name: .cacheControl, value: "no-store")
            return Response(
                status: .ok, headers: headers,
                body: .init(string: invitePage(code: raw, baseURL: base)))
        }
    }

    // MARK: - AASA

    struct AppSiteAssociation: Encodable {
        struct AppLinks: Encodable {
            var details: [Detail]
        }
        struct Detail: Encodable {
            var appIDs: [String]
            var components: [Component]
        }
        struct Component: Encodable {
            var path: String
            var comment: String

            enum CodingKeys: String, CodingKey {
                case path = "/"
                case comment
            }
        }
        var applinks: AppLinks
    }

    static func appSiteAssociation(teamID: String) throws -> Data {
        let value = AppSiteAssociation(
            applinks: .init(details: [
                .init(
                    appIDs: [BundleIDs.release, BundleIDs.debug].map { "\(teamID).\($0)" },
                    components: [.init(path: "/i/*", comment: "group invites")])
            ]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    // MARK: - Invite page

    /// Where "App Store" points until the app's own listing ID is fixed.
    static let appStoreURL = "https://apps.apple.com/search?term=Pilgrim%20Journal"

    /// The same page for every code, valid or not: a well-formed code is shown grouped
    /// (`XXXX-XXXX-XXXX`) for typing in by hand, anything else is shown as given.
    static func invitePage(code raw: String, baseURL: URL) -> String {
        let shown: String
        let link: String
        if let code = InviteCode(normalizing: raw) {
            shown = code.grouped
            link = code.url(base: baseURL).absoluteString
        } else {
            shown = String(raw.prefix(32))
            link = baseURL.appendingPathComponent("i").absoluteString
        }
        let code = escapeHTML(shown)
        let href = escapeHTML(link)
        return """
            <!doctype html>
            <html lang="ko">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="robots" content="noindex">
            <title>Pilgrim 그룹 초대 · Group invite</title>
            <style>
            :root { color-scheme: light dark; --bg: #faf8f4; --fg: #2b2620; --muted: #6f665b;
                    --card: #ffffff; --accent: #8a5a2b; }
            @media (prefers-color-scheme: dark) {
              :root { --bg: #1c1a17; --fg: #f1ebe2; --muted: #b3a998; --card: #272420;
                      --accent: #d9a46b; } }
            body { margin: 0; background: var(--bg); color: var(--fg);
                   font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", sans-serif; }
            main { max-width: 420px; margin: 0 auto; padding: 48px 16px; }
            section { background: var(--card); border-radius: 16px; padding: 24px; margin-bottom: 16px; }
            h1 { font-size: 22px; margin: 0 0 8px; }
            p { margin: 0 0 16px; color: var(--muted); }
            .code { font: 600 24px/1.2 ui-monospace, Menlo, monospace; letter-spacing: 2px;
                    padding: 12px; text-align: center; border: 1px dashed var(--muted);
                    border-radius: 12px; margin-bottom: 16px; user-select: all; overflow-wrap: anywhere; }
            a.button { display: block; text-align: center; padding: 12px; border-radius: 12px;
                       text-decoration: none; font-weight: 600; margin-bottom: 8px; }
            a.primary { background: var(--accent); color: #fff; }
            a.secondary { color: var(--accent); border: 1px solid var(--accent); }
            </style>
            </head>
            <body>
            <main>
            <section lang="ko">
            <h1>그룹 초대</h1>
            <p>Pilgrim 앱에서 그룹 초대를 열어 주세요. 앱이 없으면 App Store에서 받은 뒤 아래 초대 코드를 입력하면 됩니다.</p>
            <div class="code">\(code)</div>
            <a class="button primary" href="\(href)">Pilgrim 앱에서 열기</a>
            <a class="button secondary" href="\(appStoreURL)">App Store에서 받기</a>
            </section>
            <section lang="en">
            <h1>Group invite</h1>
            <p>Open this invite in the Pilgrim app. If you don't have it yet, get it from the App Store and enter the invite code above.</p>
            <a class="button primary" href="\(href)">Open in Pilgrim</a>
            <a class="button secondary" href="\(appStoreURL)">Get it on the App Store</a>
            </section>
            </main>
            </body>
            </html>
            """
    }

    static func escapeHTML(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }
}
