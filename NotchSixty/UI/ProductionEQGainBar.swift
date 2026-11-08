import SwiftUI

/// E27 S3a: the Equalizer page's gain row. The headroom badge (EQ sine-gain prediction against
/// the preamp, red when the post-EQ meter clipped in the last two seconds), the input preamp
/// (or its trim while auto preamp is on), the auto preamp switch and
/// the output gain. Every control uses the engine's existing gain setters.
struct ProductionEQGainBar: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var autoPreamp: EQAutoPreampController
    let perform: (() throws -> Void) -> Void

    @State private var monitor = EQClipMonitor()
    @State private var clipTripped = false
    private let overRangeIsDelta = !FeatureFlags().isEnabled(.legacyKernel)

    private var badge: EQHeadroomBadge {
        EQHeadroomBadge.evaluate(
            boostDB: autoPreamp.prediction.boostDB,
            preampDB: engine.gainConfiguration.inputPreampDB,
            headroomAttenuationDB: engine.gainConfiguration.headroomAttenuationDB,
            clipTripped: clipTripped
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            badgeView

            Spacer(minLength: 8)

            if autoPreamp.isActive {
                ProductionGainStepper(
                    title: "Trim",
                    value: autoPreamp.trimDB,
                    range: DSPGainConfiguration.inputPreampRange,
                    set: { value in perform { try autoPreamp.setTrim(value) } }
                )
                .frame(maxWidth: 230)
                .help("Your own input level. Auto preamp lowers the input by the EQ's predicted boost on top of it.")
                Text(String(format: "Preamp %+.1f dB", engine.gainConfiguration.inputPreampDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProductionGainStepper(
                    title: "Preamp",
                    value: engine.gainConfiguration.inputPreampDB,
                    range: DSPGainConfiguration.inputPreampRange,
                    set: { value in perform { try engine.setInputPreampDB(value) } }
                )
                .frame(maxWidth: 230)
                .help("Gain before all processing. Lower it to leave headroom for EQ boosts.")
            }

            Toggle("Auto preamp", isOn: Binding(
                get: { autoPreamp.isOn },
                set: { on in perform { try autoPreamp.setOn(on) } }
            ))
            .toggleStyle(.switch)
            .fixedSize()
            .help("Lowers the preamp by the largest boost the EQ can apply, rounded up to 0.1 dB, so boosts do not clip.")

            ProductionGainStepper(
                title: "Output",
                value: engine.gainConfiguration.outputGainDB,
                range: DSPGainConfiguration.outputGainRange,
                set: { value in perform { try engine.setOutputGainDB(value) } }
            )
            .frame(maxWidth: 230)
            .help("Gain after all processing, before the output device.")
        }
        .padding(12)
        .background(.quaternary.opacity(0.24), in: .rect(cornerRadius: 14))
        .task { await pollMeter() }
        .onAppear { autoPreamp.reconcile() }
    }

    private var badgeView: some View {
        let appearance = Self.appearance(of: badge)
        return VStack(alignment: .leading, spacing: 2) {
            Label(appearance.title, systemImage: appearance.symbol)
                .font(.callout.bold())
                .foregroundStyle(appearance.color)
            Text(appearance.detail + (autoPreamp.prediction.omitsFIRBands ? " Imported FIR bands are not included." : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(appearance.color.opacity(0.14), in: .rect(cornerRadius: 10))
        .help("A prediction from the filter math for a steady sine at full scale, not a bound on inter-sample peaks. The red state comes from the post-EQ meter.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Headroom: \(appearance.title). \(appearance.detail)")
    }

    struct Appearance {
        var title: String
        var detail: String
        var symbol: String
        var color: Color
    }

    static func appearance(of badge: EQHeadroomBadge) -> Appearance {
        switch badge {
        case .covered(let boost, let margin):
            return Appearance(
                title: "Headroom OK",
                detail: boost > 0
                    ? String(format: "EQ boosts up to %+.1f dB; %.1f dB spare.", boost, margin)
                    : "The EQ does not boost.",
                symbol: "checkmark.circle.fill",
                color: .green
            )
        case .uncovered(let boost, let shortfall):
            return Appearance(
                title: "May clip",
                detail: String(format: "EQ boosts up to %+.1f dB; lower the preamp by %.1f dB.", boost, shortfall),
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
        case .clipped:
            return Appearance(
                title: "Clipping",
                detail: "The post-EQ meter reached full scale in the last 2 seconds.",
                symbol: "xmark.octagon.fill",
                color: .red
            )
        }
    }

    /// Samples the post-EQ meter about ten times a second while this page is shown.
    private func pollMeter() async {
        while !Task.isCancelled {
            let now = ProcessInfo.processInfo.systemUptime
            if engine.lifecycleState == .running,
               let post = engine.diagnosticsSnapshot().renderKernelDiagnostics?.postEQMeter {
                monitor.ingest(
                    peakLinear: max(post.peakLeft, post.peakRight),
                    overRangeSamples: post.overRangeSamples,
                    overRangeIsDelta: overRangeIsDelta,
                    at: now
                )
            } else {
                monitor.reset()
            }
            let tripped = monitor.isTripped(at: now)
            if tripped != clipTripped { clipTripped = tripped }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
