#if canImport(Translation)
import Foundation
import JournalShareDrafts
import Translation

/// Translates finished prayer requests into the share language with the system's on-device
/// translation models, so the text still never leaves the machine. Asking the language model
/// to translate instead flipped meanings ("잠을 잘 못 자도록"); see docs/roadmap.md.
@available(macOS 26, iOS 26, *)
enum RequestTranslator {
    struct Unavailable: Error {
        let message: String
    }

    static func translate(
        _ texts: [String], from source: RequestLanguage, to target: RequestLanguage
    ) async -> Result<[String], Unavailable> {
        let status = await LanguageAvailability().status(from: source.locale, to: target.locale)
        guard status == .installed else {
            return .failure(
                Unavailable(
                    message: "번역 언어 팩이 없습니다 (시스템 설정 > 일반 > 언어 및 지역 > 번역 언어에서 한국어·영어를 내려받으세요)."
                ))
        }
        let session = TranslationSession(installedSource: source.locale, target: target.locale)
        var translated: [String] = []
        for text in texts {
            do {
                translated.append(try await session.translate(text).targetText)
            } catch {
                return .failure(Unavailable(message: "번역하지 못했습니다: \(error.localizedDescription)"))
            }
        }
        return .success(translated)
    }
}
#endif
