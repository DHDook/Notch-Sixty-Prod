import SwiftUI

/// E33 S27 (G52): the Length picker, the accuracy readout and the "needs a longer length" warning under the Phase picker,
/// shown in Linear phase mode with the Equalizer enhancements on. The text comes from `EQLinearPhaseLengthReadout`, a
/// plain value the tests check without a view.
struct EQLinearPhaseLengthReadout: Equatable {
    /// "Delay 85 ms", or nil when the design for the current length has not landed yet.
    var delayText: String
    /// How closely the result follows the drawn curve, or nil while the design is pending.
    var accuracyText: String?
    /// A narrow band needs a longer length than the one chosen, or the design misses the curve by more than a dB.
    var warning: String?
    var suggested: EQLinearPhaseLength

    static let accuracyWarningDB = 1.0

    static func make(
        length: EQLinearPhaseLength, bands: [EQBand], sampleRate: Double, info: EQLinearPhaseDesignInfo?
    ) -> EQLinearPhaseLengthReadout {
        let delayFrames = length.groupDelayFrames(sampleRate: sampleRate)
        let delayMs = Double(delayFrames) / max(sampleRate, 1) * 1_000
        let landed = info.flatMap { $0.groupDelayFrames == delayFrames ? $0 : nil }
        let bandwidth = EQLinearPhaseLength.narrowestBandwidthHz(bands)
        let suggested = EQLinearPhaseLength.suggested(narrowestBandwidthHz: bandwidth, sampleRate: sampleRate)
        var warning: String?
        if let bandwidth, suggested != length,
           Double(delayFrames) < Double(suggested.groupDelayFrames(sampleRate: sampleRate)) {
            let width = bandwidth.formatted(.number.precision(.fractionLength(0)))
            warning = "A band about \(width) Hz wide needs a longer length to be followed closely. Suggested: \(suggested.displayName)."
        } else if let landed, landed.maxErrorDB > accuracyWarningDB {
            warning = "The result differs from the drawn curve by up to "
                + "\(landed.maxErrorDB.formatted(.number.precision(.fractionLength(1)))) dB."
        }
        return EQLinearPhaseLengthReadout(
            delayText: "Delay \(delayMs.formatted(.number.precision(.fractionLength(delayMs < 100 ? 1 : 0)))) ms",
            accuracyText: landed.map {
                "Follows the drawn curve within \($0.maxErrorDB.formatted(.number.precision(.fractionLength(1)))) dB"
            },
            warning: warning,
            suggested: suggested)
    }
}

struct EQLinearPhaseLengthControl: View {
    let engine: AudioIOEngine
    let configuration: StereoEQConfiguration
    let sampleRate: Double
    let choose: (EQLinearPhaseLength) -> Void

    var body: some View {
        let readout = EQLinearPhaseLengthReadout.make(
            length: configuration.linearPhaseLength, bands: configuration.editableBands, sampleRate: sampleRate,
            info: engine.linearPhaseDesignInfo)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DesignSpacing.s.pt) {
                Picker("Length", selection: Binding(get: { configuration.linearPhaseLength }, set: choose)) {
                    ForEach(EQLinearPhaseLength.allCases) { length in Text(length.displayName).tag(length) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityLabel("Linear phase length")
                Text(readout.delayText)
                    .font(DesignType.caption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let accuracy = readout.accuracyText {
                Text(accuracy).font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            if let warning = readout.warning {
                HStack(spacing: 6) {
                    Text(warning).font(DesignType.caption.font).foregroundStyle(.orange)
                    if readout.suggested != configuration.linearPhaseLength {
                        Button("Use \(readout.suggested.displayName)") { choose(readout.suggested) }
                            .buttonStyle(.link)
                            .font(DesignType.caption.font)
                    }
                }
            }
        }
    }
}
