import Foundation

// E33 S27 (G52, owner decision 33): the linear-phase EQ's length, and its design through the core.
//
// The linear-phase EQ is one FIR whose delay is half its length, so a narrow bass band needs a long one: a band about
// B Hz wide is followed to within about half a dB when the delay times B is at least four (measured in
// core/tests/test_eq_linear_phase.cpp). Four lengths: about 21 ms (the default, the length every saved EQ has always
// had), 85, 170 and 340 ms. Lengths apply to the linear-phase mode only; mixed phase is the band filters plus all-pass
// correction sections and has no FIR length.
//
// Realtime impact: none. The design runs on a background task (control plane) and the render path only sees the
// published taps. Allocation: the tap array and the core's FFT work, on the calling thread. Latency: the delay below,
// declared to the graph as before. Sample rates: every rate to 384 kHz (340 ms is 261,121 taps at 384 kHz, inside the
// 262,144-tap limit of the long FIR engine).

enum EQLinearPhaseLength: String, Codable, CaseIterable, Identifiable, Sendable {
    /// About 21 ms: the default. Absent from stored profiles, which therefore load at this length.
    case ms21
    case ms85
    case ms170
    case ms340

    static let `default`: EQLinearPhaseLength = .ms21

    var id: String { rawValue }

    /// The delay the name promises, in milliseconds.
    var nominalMilliseconds: Double {
        switch self {
        case .ms21: return 1_000.0 / 46.875
        case .ms85: return 85
        case .ms170: return 170
        case .ms340: return 340
        }
    }

    var displayName: String {
        switch self {
        case .ms21: return "21 ms"
        case .ms85: return "85 ms"
        case .ms170: return "170 ms"
        case .ms340: return "340 ms"
        }
    }

    /// The group delay in frames at `sampleRate`. The default keeps the rule the C design used (rate / 46.875, between 512
    /// and 8192 frames), so a saved EQ sounds as it did.
    func groupDelayFrames(sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0 else { return 0 }
        switch self {
        case .ms21:
            return UInt32(min(8_192, max(512, (sampleRate / 46.875).rounded())))
        default:
            let frames = (sampleRate * nominalMilliseconds / 1_000).rounded()
            return UInt32(min(Double(Self.maximumGroupDelayFrames), max(1, frames)))
        }
    }

    func tapCount(sampleRate: Double) -> Int { Int(groupDelayFrames(sampleRate: sampleRate)) * 2 + 1 }

    /// The core's limit: (262,144 - 1) / 2 frames.
    static let maximumGroupDelayFrames = (Int(N60_EQ_LINEAR_PHASE_MAX_TAPS) - 1) / 2

    /// Tap-lanes (taps times lanes the FIR runs on) the stage budget allows. An estimate sized so 340 ms at 384 kHz holds
    /// on a stereo layout and a 5.1 layout holds up to 170 ms at 384 kHz; the bench check in E22 confirms or moves it.
    static let tapLaneBudget = 1_048_576

    /// Why this length cannot run on this layout and rate, named; nil when it fits the FIR engine's tap limit (`firScheme`)
    /// and the stage budget.
    func refusal(sampleRate: Double, laneCount: Int, firScheme: UInt32 = UnifiedGraphFIRScheme.current()) -> String? {
        let taps = tapCount(sampleRate: sampleRate)
        let kHz = (sampleRate / 1_000).formatted(.number.precision(.fractionLength(0...1)))
        if taps > UnifiedGraphFIRScheme.maxTaps(firScheme) {
            return "A \(displayName) linear-phase EQ needs \(taps) taps at \(kHz) kHz; the FIR engine in use takes at most "
                + "\(UnifiedGraphFIRScheme.maxTaps(firScheme)). Choose a shorter length."
        }
        if taps * max(1, laneCount) > Self.tapLaneBudget {
            return "A \(displayName) linear-phase EQ on \(laneCount) channels at \(kHz) kHz is more than the processing budget "
                + "for this stage. Choose a shorter length."
        }
        return nil
    }

    /// The shortest length that follows the narrowest band: delay times bandwidth at least four (see the file note).
    /// `narrowestBandwidthHz` is nil when there are no bands to follow.
    static func suggested(narrowestBandwidthHz: Double?, sampleRate: Double) -> EQLinearPhaseLength {
        guard let bandwidth = narrowestBandwidthHz, bandwidth > 0 else { return .default }
        for length in allCases where Double(length.groupDelayFrames(sampleRate: sampleRate)) / sampleRate * bandwidth >= 4.0 {
            return length
        }
        return .ms340
    }

    /// Half-power width of the narrowest enabled band: f/Q for a bell, band pass or notch, the corner for a shelf, pass
    /// filter or tilt (their transition is about as wide as their corner). Nil with no enabled band.
    static func narrowestBandwidthHz(_ bands: [EQBand]) -> Double? {
        bands.filter(\.enabled).compactMap { band -> Double? in
            switch band.type {
            case .peaking, .bandPass, .notch: return band.frequencyHz / max(band.q, 0.1)
            case .lowShelf, .highShelf, .lowPass, .highPass, .tilt: return band.frequencyHz
            case .linkwitzTransform, .fir, .allPass: return nil
            }
        }.min()
    }
}

extension StereoEQConfiguration {
    /// The length the design uses: the stored one with the Equalizer enhancements on, 21 ms otherwise (the flag is
    /// process-wide and read here in Swift only; the engine never sees it).
    var effectiveLinearPhaseLength: EQLinearPhaseLength {
        FeatureFlags.isEnabledProcessWide(.eqPageEnhancements) ? linearPhaseLength : .default
    }
}

enum EQLinearPhaseLengthError: Error, LocalizedError, Equatable {
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .refused(let reason): return reason
        }
    }
}

/// One prepared biquad section of the EQ, as the linear-phase design takes it (the coefficients the stage runs).
struct EQLinearPhaseBand: Equatable, Sendable {
    var enabled = true
    var type = N60BiquadFilterTypePeaking
    var frequencyHz = 0.0
    var gainDB = 0.0
    var q = 0.0
    var usesPreparedCoefficients = true
    var preparedCoefficients = N60BiquadCoefficients()

    static func == (l: Self, r: Self) -> Bool {
        l.enabled == r.enabled && l.type == r.type && l.frequencyHz == r.frequencyHz && l.gainDB == r.gainDB && l.q == r.q
            && l.preparedCoefficients.b0 == r.preparedCoefficients.b0 && l.preparedCoefficients.b1 == r.preparedCoefficients.b1
            && l.preparedCoefficients.b2 == r.preparedCoefficients.b2 && l.preparedCoefficients.a1 == r.preparedCoefficients.a1
            && l.preparedCoefficients.a2 == r.preparedCoefficients.a2
    }
}

struct EQLinearPhaseDesignInfo: Equatable, Sendable {
    var tapCount: UInt32 = 0
    var groupDelayFrames: UInt32 = 0
    /// Group delay plus the convolver's partition (what the graph reports).
    var totalLatencyFrames: UInt32 = 0
    var groupDelayMilliseconds = 0.0
    /// The largest difference, in dB, between the FIR and the drawn curve over 20 Hz to min(20 kHz, 0.45 fs).
    var maxErrorDB = 0.0
}

enum EQLinearPhaseDesigner {
    /// The linear-phase FIR of `bands` at `length`, designed by the core. Control plane; allocates; safe off the main actor.
    static func design(
        bands: [EQLinearPhaseBand], sampleRate: Double, length: EQLinearPhaseLength
    ) throws -> (taps: [Float], info: EQLinearPhaseDesignInfo) {
        let delay = length.groupDelayFrames(sampleRate: sampleRate)
        let tapCount = Int(delay) * 2 + 1
        guard delay > 0, tapCount <= Int(N60_EQ_LINEAR_PHASE_MAX_TAPS) else { throw EQConfigurationError.linearPhaseDesignFailed }
        var sections: [Float] = []
        sections.reserveCapacity(bands.count * 5)
        for band in bands where band.enabled {
            guard band.usesPreparedCoefficients, N60BiquadCoefficientsAreFinite(band.preparedCoefficients) else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let c = band.preparedCoefficients
            sections.append(contentsOf: [c.b0, c.b1, c.b2, c.a1, c.a2])
        }
        var taps = [Float](repeating: 0, count: tapCount)
        var report = n60_eq_linear_phase_report()
        let count = UInt32(sections.count / 5)
        let designed = taps.withUnsafeMutableBufferPointer { out in
            sections.withUnsafeBufferPointer { input in
                n60_eq_linear_phase_design(
                    sampleRate, delay, input.baseAddress, count, out.baseAddress, UInt64(out.count), &report)
            }
        }
        guard designed == 1 else { throw EQConfigurationError.linearPhaseDesignFailed }
        var info = EQLinearPhaseDesignInfo()
        info.tapCount = report.tapCount
        info.groupDelayFrames = report.groupDelayFrames
        info.totalLatencyFrames = report.groupDelayFrames + N60_CONVOLUTION_PARTITION_FRAMES
        info.groupDelayMilliseconds = Double(report.groupDelayFrames) / sampleRate * 1_000
        info.maxErrorDB = report.maxErrorDb
        return (taps, info)
    }
}

extension EQConfiguration {
    /// The prepared sections of the legacy single-list EQ for the linear-phase design.
    func linearPhaseBands(sampleRate: Double) throws -> [EQLinearPhaseBand] {
        guard bands.count <= Self.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
        var result: [EQLinearPhaseBand] = []
        result.reserveCapacity(enabledBandCount)
        for (index, band) in bands.enumerated() where band.enabled {
            guard try EQBandRules.validate(band, index: index, sampleRate: sampleRate) else { continue }
            guard band.type != .allPass else {
                throw EQConfigurationError.allPassRequiresMinimumPhase
            }
            if band.type == .fir { continue }
            for section in try band.compiledSections(sampleRate: sampleRate) {
                result.append(EQLinearPhaseBand(
                    type: section.type, frequencyHz: section.frequencyHz, gainDB: section.gainDB, q: section.q,
                    preparedCoefficients: section.coefficients))
            }
        }
        return result
    }
}
