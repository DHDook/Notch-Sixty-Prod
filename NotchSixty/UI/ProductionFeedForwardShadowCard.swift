import SwiftUI

/// E4 S9c: the feed-forward canceller learning in
/// shadow, compared per third-octave band with the offline design. Nothing
/// here plays anti-noise.
struct ProductionFeedForwardShadowCard: View {
    @ObservedObject var shadow: QuietZoneFeedForwardShadow

    var body: some View {
        let status = shadow.status
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Feed-Forward Shadow")
                        .font(DesignType.sectionTitle.font)
                    Text("Adapts on both microphones without playing anything. Reductions are predictions at the seat, with the speakers' leakage into the reference left out.")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(status.state.displayName.uppercased())
                    .font(DesignType.caption.font.bold())
                    .tracking(1)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DesignSpacing.m.pt)
                    .padding(.vertical, DesignSpacing.s.pt)
                    .glassEffect(.regular, in: .capsule)
            }

            switch status.state {
            case .inactive:
                EmptyView()
            case .waiting(let reason), .fault(let reason):
                Text(reason)
                    .font(DesignType.label.font)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .adapting:
                adapting(status)
            }
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    @ViewBuilder
    private func adapting(_ status: QuietZoneFeedForwardShadowStatus) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
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
        .font(DesignType.label.font)
        .foregroundStyle(.secondary)

        echo(status.echo)

        if !status.comparison.bands.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    ForEach(["Band", "Shadow", "Offline design", "Target"], id: \.self) {
                        Text($0).font(DesignType.caption.font.bold()).foregroundStyle(.secondary)
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
                    .font(DesignType.caption.font.monospacedDigit())
                }
            }
        }
    }

    @ViewBuilder
    private func echo(_ echo: QuietZoneFeedForwardEchoReadout) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            switch echo.alignment {
            case .off(let reason):
                Text(reason)
            case .waiting(let reason):
                Text("Echo removal waiting: \(reason).")
            case .searching:
                Text("Echo removal: aligning to the programme.")
            case .locked:
                if let removal = echo.removalDB {
                    Text(String(format: "Echo removal: %.1f dB of the speakers' programme taken out of the reference (offset %d samples).", removal, echo.offsetSamples))
                } else {
                    Text("Echo removal: aligned.")
                }
            }
            if let drift = echo.driftPPM {
                Text(String(format: "Output and input clocks differ by %.0f ppm.", drift))
            }
            switch echo.stability {
            case .passed(let loop):
                Text(String(format: "Leakage stability: passed (loop gain %.3f).", loop))
            case .notChecked(let why):
                Text("Leakage stability: \(why).")
            case .refused(let why):
                Text("Would be refused: \(why).").foregroundStyle(StatusLevel.attention.color)
            }
            if echo.measureAgain {
                Text("Removal stayed under 10 dB; measure leakage again.").foregroundStyle(StatusLevel.attention.color)
            }
        }
        .font(DesignType.label.font)
        .foregroundStyle(.secondary)
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
