import Foundation

/// E33 S14 (graph ABI v46, behind `e33.page-enhancements`): the limiter's programme-dependent release. Swift decides and publishes
/// it as bit 2 of the PROTECTION stage's trailing word (the core never reads the flag). Off: every stage renders as before.
enum LimiterAutoRelease {
    /// Bit value in the PROTECTION stage's trailing word (ABI v46).
    static let wordBit: Float = 4

    /// Whether the control is offered and honoured: the page flag is on and the frozen kernel is not selected (it keeps its
    /// fixed release).
    nonisolated static var isAvailable: Bool {
        FeatureFlags.isEnabledProcessWide(.eqPageEnhancements) && !FeatureFlags.isEnabledProcessWide(.legacyKernel)
    }

    /// The Release row's text while Auto Release is on: "Auto" with the current effective time once the engine reports one.
    static func releaseText(effectiveMs: Float) -> String {
        guard effectiveMs.isFinite, effectiveMs > 0 else { return "Auto" }
        return String(format: "Auto, %.0f ms", Double(effectiveMs))
    }
}
