import SwiftUI

/// E33 S14: the Release row's text while the limiter's Auto Release is on: "Auto" and the current effective time. It follows the
/// Dynamics page's meter frames (the Live Status box above it holds the monitor attachment), so it adds no poll of its own.
struct ProductionLimiterReleaseReadout: View {
    var engine: AudioIOEngine
    @State private var effectiveMs: Float = 0

    var body: some View {
        HStack {
            Text("Release").font(.subheadline.weight(.medium))
            Spacer()
            Text(LimiterAutoRelease.releaseText(effectiveMs: effectiveMs))
                .font(.system(.body, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityIdentifier("dynamics.limiter.release.auto.value")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Release")
        .accessibilityValue(LimiterAutoRelease.releaseText(effectiveMs: effectiveMs))
        .accessibilityIdentifier("dynamics.limiter.release.auto")
        .onReceive(GainReductionMonitor.shared(for: engine).$textRevision) { _ in refresh() }
        .onAppear { refresh() }
    }

    @MainActor
    private func refresh() {
        guard engine.lifecycleState == .running,
              let diagnostics = ProductionMeterHub.shared(for: engine).latestContext?.diagnostics.renderKernelDiagnostics else {
            effectiveMs = 0
            return
        }
        effectiveMs = diagnostics.limiterEffectiveReleaseMs
    }
}
