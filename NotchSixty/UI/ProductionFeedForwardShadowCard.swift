import SwiftUI

/// E4 S9c (flag `e4.adaptive-anc`): the feed-forward canceller learning in
/// shadow, compared per third-octave band with the offline design. Nothing
/// here plays anti-noise.
struct ProductionFeedForwardShadowCard: View {
    @ObservedObject var shadow: QuietZoneFeedForwardShadow

    var body: some View {
        let status = shadow.status
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Feed-Forward Shadow")
                        .font(.headline)
                    Text("Adapts on both microphones without playing anything. Reductions are predictions at the seat, with the speakers' leakage into the reference left out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(status.state.displayName.uppercased())
                    .font(.caption.bold())
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }

            switch status.state {
            case .inactive:
                EmptyView()
            case .waiting(let reason), .fault(let reason):
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .adapting:
                adapting(status)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private func adapting(_ status: QuietZoneFeedForwardShadowStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(seedText(status.seedSource))
            Text(String(
                format: "%.0f Hz native, %.0f Hz adaptive rate; %.0f s since the last restart.",
                status.sampleRate ?? 0, status.decimatedRate ?? 0, status.adaptedSeconds
            ))
            if let measured = status.measuredDBFS, let predicted = status.predictedDBFS {
                Text(String(format: "Seat microphone %.1f dBFS, predicted with the shadow %.1f dBFS.", measured, predicted))
            }
            Text("Guard: \(guardText(status.guardState)). Gaps \(status.gaps), model resets \(status.modelResets), gain limited \(status.gainLimited).")
        }
        .font(.callout)
        .foregroundStyle(.secondary)

        if !status.comparison.bands.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    ForEach(["Band", "Shadow", "Offline design", "Target"], id: \.self) {
                        Text($0).font(.caption.bold()).foregroundStyle(.secondary)
                    }
                }
                ForEach(status.comparison.bands) { band in
                    GridRow {
                        Text(String(format: "%g Hz", band.centreHz))
                        reduction(band.shadowReductionDB)
                        if let offline = band.offlineReductionDB {
                            reduction(offline)
                        } else {
                            Text("—")
                        }
                        Text(String(format: "≥ %.0f dB", QuietZoneFeedForwardShadowComparison.targetReductionDB))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
        }
    }

    private func reduction(_ db: Double) -> some View {
        Text(String(format: "%.1f dB", db))
            .foregroundStyle(db >= QuietZoneFeedForwardShadowComparison.targetReductionDB ? Color.primary : Color.orange)
    }

    private func seedText(_ source: QuietZoneFeedForwardShadowPlan.SeedSource?) -> String {
        switch source {
        case .offlineDesign: return "Started from the offline design."
        case .zeroWeights(let reason): return reason
        case nil: return ""
        }
    }

    private func guardText(_ state: AdaptiveQuietZoneShadowStatus.Guard) -> String {
        switch state {
        case .arming: return "arming"
        case .clear: return "clear"
        case .wouldHaveTripped(let why): return "would have tripped (\(why))"
        }
    }
}
