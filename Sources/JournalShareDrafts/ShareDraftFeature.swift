import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Entry point for the app: whether on-device drafting can run here, and the model if so.
public enum ShareDraftFeature {
    /// Switch for turning the feature off in a build without touching the callers.
    public static let onDeviceDraftsEnabled = true

    public static func availability() -> ShareModelAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *) {
            let reason: ShareModelUnavailableReason?
            switch SystemLanguageModel(guardrails: .permissiveContentTransformations).availability {
            case .available:
                reason = nil
            case .unavailable(let why):
                switch why {
                case .deviceNotEligible: reason = .deviceNotEligible
                case .appleIntelligenceNotEnabled: reason = .appleIntelligenceNotEnabled
                case .modelNotReady: reason = .modelNotReady
                @unknown default: reason = .other
                }
            }
            return .resolve(
                switchOn: onDeviceDraftsEnabled, osSupported: true, reason: reason)
        }
        #endif
        return .resolve(switchOn: onDeviceDraftsEnabled, osSupported: false, reason: nil)
    }

    public static func makeModel() -> (any ShareLanguageModel)? {
        #if canImport(FoundationModels)
        if #available(iOS 26, macOS 26, *), availability() == .available {
            return FoundationModelsShareLanguageModel()
        }
        #endif
        return nil
    }
}
