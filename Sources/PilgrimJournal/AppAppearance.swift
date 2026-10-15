import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// The user's light/dark choice in Settings, applied to every window.
///
/// Applied through the platform rather than SwiftUI's `preferredColorScheme`:
/// returning to "system" with `preferredColorScheme(nil)` does not reliably
/// undo an earlier override, and the AppKit/UIKit editor resolves its dynamic
/// colours from the window's appearance, not from SwiftUI's environment.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// `@AppStorage` key. Kept per device: the setting is about the screen in
    /// front of the user, so it is not synced.
    static let storageKey = "app-appearance"
    static let defaultValue = AppAppearance.system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "시스템 설정"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    /// Unknown or missing values (a newer build's choice, a damaged store) fall
    /// back to following the system, which the picker can always show.
    init(storedValue: String) {
        self = AppAppearance(rawValue: storedValue) ?? Self.defaultValue
    }

    #if os(macOS)
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
    #elseif os(iOS)
    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    /// Covers sheets and full-screen covers too, which present inside the
    /// same window.
    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }
    #endif
}
