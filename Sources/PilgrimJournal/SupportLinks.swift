import Foundation

/// The one place that knows where users get help. Settings › 도움말, the
/// privacy screen and the account-deletion screen all read from here.
enum SupportLinks {
    // `site/index.html`, deployed from the public shkim0604/pilgrim-support
    // repo via GitHub Pages. Keep it equal to the App Store Connect Support URL.
    static let supportPage = URL(string: "https://shkim0604.github.io/pilgrim-support/")!

    // `site/group-terms.html`, from `docs/group-terms.md`; the group sign-up sheet links here.
    static let groupTerms = supportPage.appending(path: "group-terms.html")

    static let contactEmail = "d.house0827@gmail.com"

    static let contactMail = URL(string: "mailto:\(contactEmail)")!
}
