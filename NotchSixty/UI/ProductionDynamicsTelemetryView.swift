import Foundation
import SwiftUI

enum ProductionDynamicsTelemetryKind: Hashable {
    case compressor, multiband, expander, pauseGate, gainRider
    case denoiser, deEsser, mainsHum, loudnessMatch, dialogue, limiter
}

private struct ProductionDynamicsTelemetryItem: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

struct ProductionDynamicsTelemetryView: View {
    @ObservedObject var engine: AudioIOEngine
    let kind: ProductionDynamicsTelemetryKind

    @State private var items: [ProductionDynamicsTelemetryItem] = []
    @State private var statusText: String?

    var body: some View {
        GroupBox("Live Status") {
            VStack(alignment: .leading, spacing: 8) {
                if let statusText {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    Text(engine.lifecycleState == .running ? "Waiting for processor telemetry…" : "Start processing to view live status.")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label).font(.caption2).foregroundStyle(.secondary)
                                Text(item.value)
                                    .font(.system(.body, design: .monospaced).weight(.medium))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 5)
        }
        .task(id: kind) { await pollSelectedProcessor() }
    }

    @MainActor
    private func pollSelectedProcessor() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(nanoseconds: 125_000_000) // 8 Hz
        }
    }

    @MainActor
    private func refresh() {
        guard engine.lifecycleState == .running,
              let diagnostics = engine.diagnosticsSnapshot().renderKernelDiagnostics else {
            items = []
            statusText = nil
            return
        }

        func db(_ value: Float) -> String { String(format: "%.1f dB", Double(value)) }
        func percent(_ value: Float) -> String { String(format: "%.0f%%", Double(value * 100)) }
        func item(_ id: String, _ label: String, _ value: String) -> ProductionDynamicsTelemetryItem {
            .init(id: id, label: label, value: value)
        }

        switch kind {
        case .compressor:
            statusText = nil
            items = [item("gr", "Gain Reduction", db(diagnostics.compressorGainReductionDB))]
        case .multiband:
            statusText = nil
            items = [
                item("low", "Low GR", db(diagnostics.multibandLowGainReductionDB)),
                item("mid", "Mid GR", db(diagnostics.multibandMidGainReductionDB)),
                item("high", "High GR", db(diagnostics.multibandHighGainReductionDB)),
            ]
        case .expander:
            statusText = nil
            items = [item("attenuation", "Attenuation", db(diagnostics.expanderAttenuationDB))]
        case .pauseGate:
            statusText = diagnostics.pauseGateOpen ? "Gate open" : "Gate closed"
            items = [item("gain", "Gate Gain", percent(diagnostics.pauseGateGain))]
        case .gainRider:
            statusText = nil
            items = [
                item("rider", "Rider Attenuation", db(diagnostics.gainRiderAttenuationDB)),
                item("sustained", "Sustained Limiter GR", db(diagnostics.sustainedLimiterGainReductionDB)),
            ]
        case .denoiser:
            if diagnostics.denoiserCaptureActive {
                statusText = "Capturing noise profile · \(Int((diagnostics.denoiserCaptureProgress * 100).rounded()))%"
            } else if diagnostics.denoiserCapturedProfile {
                statusText = "Captured profile locked"
            } else if diagnostics.denoiserProfileReady {
                statusText = "Adaptive noise estimate ready"
            } else {
                statusText = "Building noise estimate"
            }
            items = [
                item("noise", "Estimated Noise", String(format: "%.1f dBFS", Double(diagnostics.denoiserEstimatedNoiseDBFS))),
                item("mean", "Mean Suppression", db(diagnostics.denoiserMeanSuppressionDB)),
                item("max", "Max Suppression", db(diagnostics.denoiserMaxSuppressionDB)),
            ]
        case .deEsser:
            statusText = nil
            items = [item("gr", "Gain Reduction", db(diagnostics.deEsserGainReductionDB))]
        case .mainsHum:
            statusText = diagnostics.mainsDetectionConfidence >= 0.55 ? "Stable mains estimate" : "Listening for a stable mains tone"
            items = [
                item("frequency", "Detected Fundamental", String(format: "%.2f Hz", Double(diagnostics.mainsDetectedFrequencyHz))),
                item("confidence", "Confidence", percent(diagnostics.mainsDetectionConfidence)),
            ]
        case .loudnessMatch:
            statusText = nil
            items = [
                item("lufs", "Short-Term Loudness", String(format: "%.1f LUFS", Double(diagnostics.loudnessShortTermLUFS))),
                item("gain", "Match Gain", db(diagnostics.loudnessMatchGainDB)),
            ]
        case .dialogue:
            statusText = nil
            items = [
                item("boost", "Dialogue Boost", db(diagnostics.dialogueBoostDB)),
                item("gap", "Program / Dialogue Gap", db(diagnostics.dialogueGapDB)),
                item("confidence", "Voice Confidence", percent(diagnostics.dialogueVoiceConfidence)),
            ]
        case .limiter:
            statusText = diagnostics.truePeakGuardActive ? "True-peak guard active" : nil
            items = [item("gr", "Gain Reduction", db(diagnostics.limiterGainReductionDB))]
        }
    }
}
