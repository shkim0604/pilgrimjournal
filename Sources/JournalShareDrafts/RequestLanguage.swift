import Foundation

/// The language a diary is written in, and the language its prayer requests are shared in.
/// A diary is processed in its own language (Korean diary → Korean prompt, English diary →
/// English prompt): sending Korean diaries through English read better line by line but lost
/// names and 동생/형 on the way back (docs/roadmap.md). The share language is a separate,
/// later choice, made by translating the finished lines.
public enum RequestLanguage: String, Codable, Sendable, CaseIterable {
    case korean = "ko"
    case english = "en"

    /// Korean when at least a third of the letters are Hangul, so a Korean diary full of
    /// English work terms ("Launch week") still counts as Korean.
    public static func detect(_ text: String) -> RequestLanguage {
        var hangul = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        return hangul * 3 >= hangul + latin && hangul > 0 ? .korean : .english
    }

    public var locale: Locale.Language { Locale.Language(identifier: rawValue) }
}
