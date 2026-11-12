#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model behind `ShareLanguageModel`. Nothing it receives or returns is kept.
@available(iOS 26, macOS 26, *)
public struct FoundationModelsShareLanguageModel: ShareLanguageModel {
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)

    public init() {}

    public func respond(instructions: String, prompt: String, maximumTokens: Int) async throws
        -> String
    {
        // A fresh session per call keeps earlier diaries out of the ~4K context window; greedy
        // so the same prompt version gives comparable answers.
        let session = LanguageModelSession(model: model, instructions: instructions)
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumTokens)
        return try await session.respond(to: prompt, options: options).content
    }
}
#endif
