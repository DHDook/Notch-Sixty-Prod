import SwiftUI

/// E4 S6: what the adaptive tonal canceller would do.
/// It runs in shadow: computed and metered, never played.
struct ProductionAdaptiveQuietZoneCard: View {
    @ObservedObject var shadow: AdaptiveQuietZoneShadow
    /// E4 S7: output round trip for the current hardware.
    var latencyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Adaptive Quiet Zone")
                        .font(DesignType.sectionTitle.font)
                    Text("Shadow only: computed and metered, never played. Weights are a correction on top of the live tonal canceller when it is running.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(shadow.status.state.displayName.uppercased())
                    .font(DesignType.caption.font.bold())
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignSpacing.m.pt)
                    .padding(.vertical, DesignSpacing.s.pt)
                    .glassEffect(.regular, in: .capsule)
            }

            if shadow.status.tones.isEmpty {
                Text(emptyMessage)
                    .font(DesignType.label.font)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(["Tone", "Status", "Path (seed)", "Weight", "Offline", "Measured", "Predicted"], id: \.self) {
                            Text($0).font(DesignType.caption.font.bold()).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(shadow.status.tones) { tone in
                        GridRow {
                            Text(String(format: "%.1f Hz", tone.frequencyHz))
                            Text(tone.adapting ? "Adapting" : "Holding")
                                .foregroundStyle(tone.adapting ? .green : .secondary)
                            Text(String(format: "%.1f dB, %.0f°", tone.pathGainDB, tone.pathPhaseDegrees))
                            Text(String(format: "%.1f dBFS", tone.weightDBFS))
                            Text(String(format: "%.1f dBFS", tone.offlineDBFS))
                            Text(String(format: "%.1f dBFS", tone.measuredDBFS))
                            Text(String(format: "%.1f dBFS (%+.1f dB)", tone.predictedDBFS, -tone.predictedReductionDB))
                        }
                        .font(DesignType.label.font.monospacedDigit())
                    }
                }
            }

            Label("Output latency: \(latencyText)", systemImage: "timer")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignSpacing.l.pt) {
                Label(guardText, systemImage: guardSymbol)
                    .foregroundStyle(guardColor)
                if let rate = shadow.status.sampleRate {
                    Text(String(format: "%.1f kHz", rate / 1000))
                        .foregroundStyle(.secondary)
                }
                if shadow.status.gaps > 0 {
                    Text("\(shadow.status.gaps) microphone gaps")
                        .foregroundStyle(.secondary)
                }
                if shadow.status.modelResets > 0 {
                    Text("\(shadow.status.modelResets) model resets")
                        .foregroundStyle(StatusLevel.attention.color)
                }
            }
            .font(DesignType.caption.font)
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var emptyMessage: String {
        switch shadow.status.state {
        case .unsupportedRate:
            return "The error microphone's sample rate is outside 8–768 kHz."
        case .waitingForMicrophone:
            return "Waiting for error-microphone audio from the ambient monitor."
        default:
            return "Starts once the live tonal canceller has designed at least one tone."
        }
    }

    private var guardText: String {
        switch shadow.status.guardState {
        case .arming: return "Howl guard arming"
        case .clear: return "Howl guard clear"
        case .wouldHaveTripped(let reason): return "Howl guard would have tripped (\(reason))"
        }
    }

    private var guardSymbol: String {
        if case .wouldHaveTripped = shadow.status.guardState { return "exclamationmark.triangle.fill" }
        return "checkmark.shield"
    }

    private var guardColor: Color {
        if case .wouldHaveTripped = shadow.status.guardState { return .orange }
        return .secondary
    }
}
