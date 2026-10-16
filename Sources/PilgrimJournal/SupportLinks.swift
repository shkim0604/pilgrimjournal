import Foundation

/// The one place that knows where users get help. Settings › 도움말, the
/// privacy screen and the account-deletion screen all read from here.
enum SupportLinks {
    // `site/index.html`, deployed from the public shkim0604/pilgrim-support
    // repo via GitHub Pages. Keep it equal to the App Store Connect Support URL.
    static let supportPage = URL(string: "https://shkim0604.github.io/pilgrim-support/")!

    static let contactEmail = "d.house0827@gmail.com"

    static let contactMail = URL(string: "mailto:\(contactEmail)")!
}
