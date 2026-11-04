import Foundation

/// The one place that knows where users get help. Settings › 도움말, the
/// privacy screen and the account-deletion screen all read from here.
enum SupportLinks {
    // `site/index.html`, deployed from the public shkim0604/pilgrim-support
    // repo via GitHub Pages. Keep it equal to the App Store Connect Support URL.
    static let supportPage = URL(string: "https://shkim0604.github.io/pilgrim-support/")!

    static let contactEmail = "d.house0827@gmail.com"

    static let contactMail = URL(string: "mailto:\(contactEmail)")!

    // Subscription screens must link the terms of use and the privacy policy
    // (guideline 3.1.2). The app uses Apple's standard EULA; if App Store
    // Connect is given a custom EULA, point this at it instead.
    static let termsOfUse = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    // Keep equal to the App Store Connect Privacy Policy URL.
    static let privacyPolicy = supportPage

    /// Where macOS manages App Store subscriptions; iOS uses the system sheet.
    static let manageSubscriptions = URL(string: "https://apps.apple.com/account/subscriptions")!
}
