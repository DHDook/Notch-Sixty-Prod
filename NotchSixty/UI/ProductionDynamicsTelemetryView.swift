import Foundation
import SwiftUI

enum ProductionDynamicsTelemetryKind: Hashable {
    case compressor, multiband, expander, pauseGate, gainRider
    case denoiser, deEsser, mainsHum, loudnessMatch, loudnessContour, dialogue, limiter
}

private struct ProductionDynamicsTelemetryItem: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

struct ProductionDynamicsTelemetryView: View {
    var engine: AudioIOEngine
    let kind: ProductionDynamicsTelemetryKind

    @State private var items: [ProductionDynamicsTelemetryItem] = []
    @State private var statusText: String?
    @State private var attachment: UUID?

    var body: some View {
        GroupBox("Live Status") {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                ForEach(panels, id: \.0) { source, curve in
                    GainReductionPanel(engine: engine, source: source, curve: curve)
                }
                if let statusText {
                    Text(statusText).font(DesignType.caption.font).foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    Text(engine.lifecycleState == .running ? "Waiting for processor telemetry…" : "Start processing to view live status.")
                        .font(DesignType.caption.font).foregroundStyle(.tertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: DesignSpacing.m.pt)], alignment: .leading, spacing: DesignSpacing.s.pt) {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                                Text(item.label).font(DesignType.caption.font).foregroundStyle(.secondary)
                                Text(item.value)
                                    .font(.system(.body, design: .monospaced).weight(.medium))
                                    .monospacedDigit()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, DesignSpacing.xs.pt)
        }
        // E32 S3 (design 7): the text follows the monitor's frames (about 8 Hz while something moves, and on every
        // rest or polling change); there is no third poll.
        .onReceive(GainReductionMonitor.shared(for: engine).$textRevision) { _ in refresh() }
        .onChange(of: kind) { _, _ in refresh() }
        .onAppear {
            refresh()
            attachment = GainReductionMonitor.shared(for: engine).attach(hertz: GainReductionMonitor.rowHertz)
        }
        .onDisappear {
            if let attachment { GainReductionMonitor.shared(for: engine).detach(attachment) }
            attachment = nil
        }
    }

    /// E28 S5: the gain-reduction panels for this stage (bar, 10 s history and, where a static law exists, the curve).
    private var panels: [(GainReductionSource, DynamicsTransferCurve?)] {
        let d = engine.dynamicsConfiguration
        switch kind {
        case .compressor: return [(.compressor, DynamicsTransferCurve(d.compressor))]
        case .expander: return [(.expander, DynamicsTransferCurve(d.expander))]
        case .limiter: return [(.limiter, DynamicsTransferCurve(d.limiter))]
        case .deEsser: return [(.deEsser, DynamicsTransferCurve(d.deEsser))]
        case .multiband:
            // E33 S5b: panels for the first three bands; bands 4 and 5 have chips only (the bar views take S6's list, G17).
            let all: [(GainReductionSource, DynamicsTransferCurve?)] = [
                (.multibandLow, DynamicsTransferCurve(d.multibandCompressor, band: 0)),
                (.multibandMid, DynamicsTransferCurve(d.multibandCompressor, band: 1)),
                (.multibandHigh, DynamicsTransferCurve(d.multibandCompressor, band: 2))]
            return FeatureFlags().isEnabled(.eqPageEnhancements) ? Array(all.prefix(d.multibandCompressor.bandCountValue)) : all
        default: return []
        }
    }

    @MainActor
    private func refresh() {
        // The hub is the only reader of the read-and-reset readbacks (E28 G5); the monitor keeps it polling.
        guard engine.lifecycleState == .running,
              let diagnostics = ProductionMeterHub.shared(for: engine).latestContext?.diagnostics.renderKernelDiagnostics else {
            items = []
            statusText = nil
            return
        }

        func db(_ value: Float) -> String { DesignFormat.db(Double(value)) }
        func percent(_ value: Float) -> String { DesignFormat.percent(Double(value)) }
        func item(_ id: String, _ label: String, _ value: String) -> ProductionDynamicsTelemetryItem {
            .init(id: id, label: label, value: value)
        }

        switch kind {
        case .compressor:
            statusText = nil
            items = [item("gr", "Gain Reduction", db(diagnostics.compressorGainReductionDB))]
        case .multiband:
            statusText = nil
            // E33 S5b: one chip per existing band (the kernel path reports no band count and keeps three).
            let count = diagnostics.multibandBandCount >= 2 ? Int(diagnostics.multibandBandCount) : 3
            let reductions = [diagnostics.multibandLowGainReductionDB, diagnostics.multibandMidGainReductionDB,
                              diagnostics.multibandHighGainReductionDB, diagnostics.multibandBand4GainReductionDB,
                              diagnostics.multibandBand5GainReductionDB]
            let ids = ["low", "mid", "high", "band4", "band5"]
            items = (0..<min(count, 5)).map { band in
                item(count == 3 ? ids[band] : "band\(band + 1)",
                     "\(ProductionDynamicsView.multibandBandTitle(band, of: count).replacingOccurrences(of: " Band", with: "")) GR",
                     db(reductions[band]))
            }
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
            let readout = LoudnessReadouts.match(
                shortTermLUFS: diagnostics.loudnessShortTermLUFS, gainDB: diagnostics.loudnessMatchGainDB,
                maxCorrectionDB: engine.dynamicsConfiguration.loudnessMatch.maxCorrectionDB)
            statusText = FeatureFlags().isEnabled(.dynamicsExtras) ? readout.status : nil
            items = [
                item("lufs", "Short-Term Loudness", String(format: "%.1f LUFS", Double(diagnostics.loudnessShortTermLUFS))),
                item("gain", "Match Gain", db(diagnostics.loudnessMatchGainDB)),
            ]
        case .loudnessContour:
            let readout = LoudnessReadouts.contour(scale: diagnostics.loudnessContourScale)
            statusText = readout.status
            items = [
                item("amount", "Contour Applied", percent(readout.scale)),
                item("lufs", "Short-Term Loudness", String(format: "%.1f LUFS", Double(diagnostics.loudnessShortTermLUFS))),
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

/// E28 S7d part 3 (G21): the words beside the Loudness Match and Loudness Contour numbers. Pure, so a test can pin them.
enum LoudnessReadouts {
    /// Within this many dB of zero the match gain reads as "at target".
    static let settledDB: Float = 0.1

    static func match(shortTermLUFS: Float, gainDB: Float, maxCorrectionDB: Double) -> (status: String, atLimit: Bool) {
        guard shortTermLUFS.isFinite, gainDB.isFinite else { return ("Measuring", false) }
        let atLimit = Double(abs(gainDB)) >= maxCorrectionDB - 0.05
        if abs(gainDB) < settledDB { return ("At target", false) }
        let direction = gainDB > 0 ? "Boosting" : "Cutting"
        return (String(format: "%@ %.1f dB%@", direction, Double(abs(gainDB)), atLimit ? " (at the maximum correction)" : ""), atLimit)
    }

    static func contour(scale: Float) -> (status: String, scale: Float) {
        let clamped = scale.isFinite ? min(max(scale, 0), 1) : 0
        if clamped < 0.01 { return ("Contour idle (level at the reference)", 0) }
        return (String(format: "Contour at %.0f%% of its full curve", Double(clamped * 100)), clamped)
    }
}
