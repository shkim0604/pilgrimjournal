import Foundation

/// Why the on-device model can or cannot draft requests, in the app's own terms.
public enum ShareModelAvailability: Equatable, Sendable {
    case available
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    /// The feature switch is off.
    case disabled
}

/// Stands in for `SystemLanguageModel.Availability.UnavailableReason`, so the mapping is
/// testable without the framework.
enum ShareModelUnavailableReason {
    case deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, other
}

extension ShareModelAvailability {
    static func resolve(
        switchOn: Bool, osSupported: Bool, reason: ShareModelUnavailableReason?
    ) -> ShareModelAvailability {
        guard switchOn else { return .disabled }
        guard osSupported else { return .unsupportedOS }
        switch reason {
        case nil: return .available
        case .deviceNotEligible: return .deviceNotEligible
        case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
        case .modelNotReady, .other: return .modelNotReady
        }
    }
}
