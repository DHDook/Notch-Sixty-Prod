import SwiftUI

/// E33 S7 (design 12, B2b): the per-frame sum of the hub's `gr.*` readings of the processors that are on, and the
/// active processors that cut level without a `gr.*` channel, which the sum cannot include.
enum TotalGainReduction {
    struct Result: Equatable {
        var totalDB: Float
        var counted: [GainReductionSource]
        var notCounted: [String]
    }

    /// The `gr.*` sources whose processor is on under `d`. Multiband bands past the band count are off.
    static func activeSources(in d: DynamicsConfiguration) -> [GainReductionSource] {
        var out: [GainReductionSource] = []
        if ProductionDynamicsModule.compressor.isActive(in: d) { out.append(.compressor) }
        if ProductionDynamicsModule.deEsser.isActive(in: d) { out.append(.deEsser) }
        if ProductionDynamicsModule.multiband.isActive(in: d) {
            let bands: [GainReductionSource] = [.multibandLow, .multibandMid, .multibandHigh, .multibandBand4, .multibandBand5]
            out.append(contentsOf: bands.prefix(max(d.multibandCompressor.bandCountValue, 2)))
        }
        if ProductionDynamicsModule.expander.isActive(in: d) { out.append(.expander) }
        if ProductionDynamicsModule.limiter.isActive(in: d) { out.append(.limiter) }
        return out
    }

    /// Active processors that change level but publish no `gr.*` reading.
    static func uncountedNames(in d: DynamicsConfiguration) -> [String] {
        let candidates: [(ProductionDynamicsModule, String)] = [
            (.gainRider, "Gain rider"), (.denoiser, "Denoiser"), (.loudnessMatch, "Loudness Match"),
            (.dialogueLeveler, "Dialogue leveller"), (.automaticHeadroom, "Automatic headroom"),
            (.deHarsh, "De-harsh"), (.softClipper, "Soft clipper"),
        ]
        return candidates.filter { $0.0.isActive(in: d) }.map(\.1)
    }

    /// Sums `latest` over the active sources; a non-finite or negative reading counts as zero.
    static func compute(configuration d: DynamicsConfiguration, latest: (GainReductionSource) -> Float) -> Result {
        let sources = activeSources(in: d)
        let total = sources.reduce(Float(0)) { sum, source in
            let value = latest(source)
            return sum + (value.isFinite ? max(0, value) : 0)
        }
        return Result(totalDB: total, counted: sources, notCounted: uncountedNames(in: d))
    }

    static func text(_ result: Result?) -> String {
        guard let result else { return "—" }
        return String(format: "%.1f dB", Double(result.totalDB))
    }

    static let label = "Total (sum of stages)"

    static func note(_ result: Result) -> String? {
        guard !result.notCounted.isEmpty else { return nil }
        return "Not counted (no gain-reduction reading): " + result.notCounted.joined(separator: ", ") + "."
    }
}

/// The Total row on the Dynamics page and Meters > Dynamics. Both read `GainReductionMonitor`, so they agree.
struct TotalGainReductionRow: View {
    var engine: AudioIOEngine
    @ObservedObject var monitor: GainReductionMonitor

    var body: some View {
        let running = engine.lifecycleState == .running
        let result = running ? TotalGainReduction.compute(
            configuration: engine.dynamicsConfiguration, latest: { monitor.latest($0) }) : nil
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            HStack(alignment: .firstTextBaseline) {
                Text(TotalGainReduction.label).font(DesignType.caption.font).foregroundStyle(.secondary)
                Spacer()
                Text(TotalGainReduction.text(result))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
            }
            if let result, let note = TotalGainReduction.note(result) {
                Text(note).font(DesignType.caption.font).foregroundStyle(.tertiary)
            } else if !running {
                Text("Start processing to read gain reduction.").font(DesignType.caption.font).foregroundStyle(.tertiary)
            }
        }
        .padding(DesignSpacing.m.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .designSurface(.medium)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TotalGainReduction.label)
        .accessibilityValue(TotalGainReduction.text(result))
        .accessibilityIdentifier("gain-reduction-total")
        // The monitor republishes about 8 Hz; reading `textRevision` keeps this row on that cadence.
        .id(monitor.textRevision)
    }
}
