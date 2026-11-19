import Foundation

/// The one place that knows where users get help. Settings › 도움말, the
/// privacy screen and the account-deletion screen all read from here.
enum SupportLinks {
    // `site/index.html`, deployed from the public shkim0604/pilgrim-support
    // repo via GitHub Pages. Keep it equal to the App Store Connect Support URL.
    static let supportPage = URL(string: "https://shkim0604.github.io/pilgrim-support/")!

    // `site/group-terms.html`, from `docs/group-terms.md`; the group sign-up sheet links here.
    static var groupTerms: URL {
        let page = "group-terms.html"
        // The page is Korean first; other app languages jump to its English half.
        let isKorean = Bundle.main.preferredLocalizations.first == "ko"
        return URL(string: isKorean ? page : page + "#en", relativeTo: supportPage)!.absoluteURL
    }

    static let contactEmail = "d.house0827@gmail.com"

    static let contactMail = URL(string: "mailto:\(contactEmail)")!
}
