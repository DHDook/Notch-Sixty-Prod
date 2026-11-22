import SwiftUI

/// E27 S3a: the Equalizer page's gain row. The headroom badge (EQ sine-gain prediction against
/// the preamp, red when the post-EQ meter clipped in the last two seconds), the input preamp
/// (or its trim while auto preamp is on), the auto preamp switch and
/// the output gain. Every control uses the engine's existing gain setters.
struct ProductionEQGainBar: View {
    var engine: AudioIOEngine
    @ObservedObject var autoPreamp: EQAutoPreampController
    let perform: (() throws -> Void) -> Void

    @State private var monitor = EQClipMonitor()
    @State private var clipTripped = false
    private let enhanced = FeatureFlags().isEnabled(.eqPageEnhancements)
    private let overRangeIsDelta = !FeatureFlags().isEnabled(.legacyKernel)

    private var badge: EQHeadroomBadge {
        EQHeadroomBadge.evaluate(
            boostDB: autoPreamp.prediction.boostDB,
            preampDB: engine.gainConfiguration.inputPreampDB,
            headroomAttenuationDB: engine.gainConfiguration.headroomAttenuationDB,
            clipTripped: clipTripped,
            protection: EQClipProtection(
                dynamics: engine.dynamicsConfiguration,
                outputProtection: UnifiedGraphOutputProtection.current()
            )
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: DesignSpacing.m.pt) {
            badgeView

            Spacer(minLength: 8)

            if autoPreamp.isActive {
                ProductionGainStepper(
                    title: "Trim",
                    value: autoPreamp.trimDB,
                    range: DSPGainConfiguration.inputPreampRange,
                    set: { value in perform { try autoPreamp.setTrim(value) } }
                )
                .frame(maxWidth: 200)
                .help("Your own input level. Auto preamp lowers the input by the EQ's predicted boost on top of it.")
                Text("Preamp " + DesignFormat.db(Double(engine.gainConfiguration.inputPreampDB), signed: true))
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProductionGainStepper(
                    title: "Preamp",
                    value: engine.gainConfiguration.inputPreampDB,
                    range: DSPGainConfiguration.inputPreampRange,
                    set: { value in perform { try autoPreamp.setManual(value) } }
                )
                .frame(maxWidth: 200)
                .help("Gain before all processing. Lower it to leave headroom for EQ boosts.")
            }

            if enhanced { termsView }

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
            .frame(maxWidth: 200)
            .help("Gain after all processing, before the output device.")
        }
        .padding(.horizontal, DesignSpacing.m.pt)
        .padding(.vertical, DesignSpacing.s.pt)
        .designSurface(.medium)
        .task { await pollMeter() }
        .onAppear { autoPreamp.reconcile() }
    }

    /// E33 S3 (design 6): each term of the one preamp model and the total the engine gets.
    private var termsView: some View {
        let text = Self.termsText(autoPreamp.preamp)
        return Text(text)
            .font(DesignType.caption.font.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("The input preamp is the sum of your own level, the auto-preamp attenuation and the A/B loudness-match trim.")
            .accessibilityLabel("Preamp terms: \(text)")
            .accessibilityIdentifier("eq.gain.preampTerms")
    }

    static func termsText(_ model: EQPreampModel) -> String {
        String(format: "Manual %+.1f  Auto %+.1f  Match %+.1f  =  %+.1f dB",
               model.manualDB, model.autoTrimDB, model.matchDB, model.totalDB)
    }

    private var badgeView: some View {
        let appearance = Self.appearance(of: badge)
        let detail = appearance.detail + (autoPreamp.prediction.omitsFIRBands ? " Imported FIR bands are not included." : "")
        return HStack(spacing: DesignSpacing.s.pt) {
            Label(appearance.title, systemImage: appearance.symbol)
                .font(.callout.bold())
                .foregroundStyle(appearance.color)
                .fixedSize()
            Text(detail)
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, DesignSpacing.m.pt)
        .padding(.vertical, DesignSpacing.s.pt)
        .frame(alignment: .leading)
        .designTint(appearance.color)
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
                color: StatusLevel.good.color
            )
        case .uncovered(let boost, let shortfall):
            return Appearance(
                title: "May clip",
                detail: String(format: "EQ boosts up to %+.1f dB; lower the preamp by %.1f dB.", boost, shortfall),
                symbol: "exclamationmark.triangle.fill",
                color: StatusLevel.attention.color
            )
        case .uncoveredProtected(let boost, let shortfall, let protection):
            let hard = protection.hasLimiter
            let ceiling = protection.limiterCeilingDB ?? protection.outputHardLimitDB ?? 0
            return Appearance(
                title: hard ? "May clip: limiter will catch it" : "May clip: softened",
                detail: hard
                    ? String(format: "EQ boosts up to %+.1f dB, so peaks will likely hit the %@ (%.1f dB). Lower the preamp by %.1f dB to keep it from working.",
                             boost, protection.primaryName, ceiling, shortfall)
                    : String(format: "EQ boosts up to %+.1f dB; the %@ will reduce overs but cannot guarantee none. Lower the preamp by %.1f dB.",
                             boost, protection.primaryName, shortfall),
                symbol: "exclamationmark.triangle.fill",
                color: StatusLevel.attention.color
            )
        case .clipped:
            return Appearance(
                title: "Clipping",
                detail: "The post-EQ meter reached full scale in the last 2 seconds.",
                symbol: "xmark.octagon.fill",
                color: StatusLevel.problem.color
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
