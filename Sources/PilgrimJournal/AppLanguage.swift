import Foundation

#if os(macOS)
import AppKit
#endif

/// The app's display language, chosen in Settings.
///
/// Stored exactly where iOS's own per-app language setting (Settings ›
/// Pilgrim › Language) and macOS's per-app language list put it:
/// `AppleLanguages` in the app's own defaults domain. The two therefore stay
/// in sync, and Foundation reads it at launch, so a change applies the next
/// time the app opens (String(localized:) has no way to switch live).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case korean = "ko"
    case english = "en"

    static let defaultsKey = "AppleLanguages"

    var id: String { rawValue }

    /// Language names are shown in their own language, as Apple's pickers do.
    var title: String {
        switch self {
        case .system: String(localized: "시스템 설정")
        case .korean: "한국어"
        case .english: "English"
        }
    }

    /// Reads only the app's own domain: `UserDefaults.standard` would also
    /// return the device-wide language list and make "system" look like an
    /// explicit choice.
    static func current(
        in defaults: UserDefaults = .standard,
        domainName: String? = Bundle.main.bundleIdentifier
    ) -> AppLanguage {
        guard let domainName,
            let languages = defaults.persistentDomain(forName: domainName)?[defaultsKey]
                as? [String],
            let first = languages.first
        else { return .system }
        if first.hasPrefix(AppLanguage.korean.rawValue) { return .korean }
        if first.hasPrefix(AppLanguage.english.rawValue) { return .english }
        return .system
    }

    func apply(to defaults: UserDefaults = .standard) {
        switch self {
        case .system: defaults.removeObject(forKey: Self.defaultsKey)
        case .korean, .english: defaults.set([rawValue], forKey: Self.defaultsKey)
        }
    }

    #if os(macOS)
    /// Opens a fresh instance of the app and quits this one, so a new
    /// language takes effect without the user hunting for Quit.
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
    #endif
}
