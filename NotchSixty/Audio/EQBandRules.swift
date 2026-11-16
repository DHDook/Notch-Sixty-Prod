import Foundation

/// E32 S1: the one rule for what an Equalizer band may hold and whether it can render at a
/// sample rate. Pure Swift, no engine state. The page, its value parser, `sanitized`, the engine
/// validators, `StereoPlaybackControl` and the profile importers all call it.
///
/// Limits: frequency 20 Hz up to 192 kHz (and under 0.49 of the device rate when edited),
/// Q 0.1 to 20, gain `StereoEQConfiguration.bandGainRange`, dynamic ranges from
/// `DynamicEQBandConfiguration`, and a notch is cut-only when dynamic.
enum EQBandRules {
    static let minimumFrequency = 20.0
    static let maximumAbsoluteFrequency = 192_000.0
    static let frequencyRange = minimumFrequency...maximumAbsoluteFrequency
    static let qRange = 0.1...20.0
    static let defaultQ = 0.707
    static var gainRange: ClosedRange<Double> { StereoEQConfiguration.bandGainRange }
    /// Linkwitz transform target frequency lower limit.
    static let linkwitzTargetMinimum = 1.0

    /// Highest frequency an edit may reach at `sampleRate`: 0.49 of the rate, never below 20 Hz.
    static func maximumFrequency(sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else { return minimumFrequency }
        return min(max(minimumFrequency, sampleRate * 0.49), maximumAbsoluteFrequency)
    }

    enum RenderState: Equatable, Sendable {
        /// The engine renders the band.
        case active
        /// The band sits at or above half the sample rate; the engine skips it.
        case aboveNyquist(limitHz: Double)
        case invalid(reason: String)

        var isActive: Bool { self == .active }
    }

    /// Why `band` breaks the rule at any sample rate, or nil. FIR bands carry their own kernel and
    /// are judged by it. Disabled bands are judged on their values too; callers filter on `enabled`.
    static func invalidReason(_ band: EQBand) -> String? {
        if band.type == .fir { return nil }
        guard band.frequencyHz.isFinite, frequencyRange.contains(band.frequencyHz) else { return "Frequency is not valid" }
        guard band.gainDB.isFinite, gainRange.contains(band.gainDB) else { return "Gain is out of range" }
        guard band.q.isFinite, qRange.contains(band.q) else { return "Q is not valid" }
        if band.type == .linkwitzTransform {
            guard band.linkwitzTargetHz.isFinite, band.linkwitzTargetHz > 0,
                  band.linkwitzTargetQ.isFinite, band.linkwitzTargetQ > 0 else {
                return "Linkwitz target is not valid"
            }
        }
        if band.dynamic.enabled {
            guard band.type.supportsDynamicEQ else { return "Dynamic EQ is unavailable for this type" }
            guard DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),
                  DynamicEQBandConfiguration.qRange.contains(band.q),
                  band.dynamic.isValid else { return "Dynamic values are out of range" }
            if band.type == .notch, band.dynamic.direction != .cutOnly { return "A dynamic notch can only cut" }
        }
        return nil
    }

    /// Whether `band` renders at `sampleRate`.
    static func renderState(_ band: EQBand, sampleRate: Double) -> RenderState {
        guard sampleRate.isFinite, sampleRate > 0 else { return .invalid(reason: "Unknown sample rate") }
        if band.type == .fir { return .active }
        if let reason = invalidReason(band) { return .invalid(reason: reason) }
        if band.type == .linkwitzTransform, band.linkwitzTargetHz >= sampleRate * 0.5 {
            return .invalid(reason: "Linkwitz target is not valid")
        }
        if band.frequencyHz >= sampleRate * 0.5 { return .aboveNyquist(limitHz: sampleRate * 0.5) }
        return .active
    }

    /// The engine's gate (E32 S2): throws `invalidBand(index:)` for a band outside the rule, and
    /// returns whether the band renders at `sampleRate` (false above Nyquist, where the engine skips
    /// it). `sampleRate` nil judges the values only (no stream is running).
    static func validate(_ band: EQBand, index: Int, sampleRate: Double?) throws -> Bool {
        if band.type == .fir {
            guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
            if let sampleRate { try kernel.validate(for: sampleRate) } else { try kernel.validateMetadata() }
            return true
        }
        guard invalidReason(band) == nil else { throw EQConfigurationError.invalidBand(index: index) }
        guard let sampleRate else { return true }
        if band.type == .linkwitzTransform, band.linkwitzTargetHz >= sampleRate * 0.5 {
            throw EQConfigurationError.invalidBand(index: index)
        }
        return band.frequencyHz < sampleRate * 0.5
    }

    /// Enabled bands the engine renders at `sampleRate` (what "N ACTIVE" counts).
    static func activeCount(in bands: [EQBand], sampleRate: Double) -> Int {
        bands.lazy.filter { $0.enabled && renderState($0, sampleRate: sampleRate).isActive }.count
    }

    /// Enabled bands the engine skips because they sit at or above Nyquist.
    static func aboveNyquistCount(in bands: [EQBand], sampleRate: Double) -> Int {
        bands.lazy.filter {
            guard $0.enabled, case .aboveNyquist = renderState($0, sampleRate: sampleRate) else { return false }
            return true
        }.count
    }

    /// "Inactive above Nyquist (44.1 kHz)".
    static func nyquistText(limitHz: Double) -> String {
        String(format: "Inactive above Nyquist (%.1f kHz)", limitHz / 1_000)
    }

    /// The band clamped to every limit above. Non-finite values fall back to defaults.
    static func sanitized(_ input: EQBand, sampleRate: Double) -> EQBand {
        sanitized(input, ceiling: maximumFrequency(sampleRate: sampleRate))
    }

    /// As above for a band whose device rate is not known (a profile import): the ceiling is the
    /// highest frequency the rule allows at any rate.
    static func sanitizedForImport(_ input: EQBand) -> EQBand {
        sanitized(input, ceiling: maximumAbsoluteFrequency)
    }

    private static func sanitized(_ input: EQBand, ceiling: Double) -> EQBand {
        var band = input
        if !band.frequencyHz.isFinite { band.frequencyHz = 1_000 }
        band.frequencyHz = clamp(band.frequencyHz, minimumFrequency...ceiling)

        if !band.gainDB.isFinite { band.gainDB = 0 }
        band.gainDB = clamp(band.gainDB, gainRange)

        if !band.q.isFinite || band.q <= 0 { band.q = defaultQ }
        band.q = clamp(band.q, qRange)

        if !band.linkwitzTargetHz.isFinite || band.linkwitzTargetHz <= 0 { band.linkwitzTargetHz = 40 }
        band.linkwitzTargetHz = clamp(band.linkwitzTargetHz, linkwitzTargetMinimum...ceiling)
        if !band.linkwitzTargetQ.isFinite || band.linkwitzTargetQ <= 0 { band.linkwitzTargetQ = defaultQ }
        band.linkwitzTargetQ = clamp(band.linkwitzTargetQ, qRange)

        if band.type != .peaking { band.constantQ = false }
        if !band.type.supportsDynamicEQ { band.dynamic.enabled = false }
        if band.type == .notch { band.dynamic.direction = .cutOnly }

        if band.dynamic.enabled {
            typealias R = EQBandDynamicConfiguration
            band.frequencyHz = clamp(band.frequencyHz, DynamicEQBandConfiguration.frequencyRange.lowerBound...min(DynamicEQBandConfiguration.frequencyRange.upperBound, ceiling))
            band.q = clamp(band.q, DynamicEQBandConfiguration.qRange)
            band.dynamic.thresholdDB = clamp(band.dynamic.thresholdDB, R.thresholdRange)
            band.dynamic.ratio = clamp(band.dynamic.ratio, R.ratioRange)
            band.dynamic.rangeDB = clamp(band.dynamic.rangeDB, R.rangeRange)
            band.dynamic.attackMs = clamp(band.dynamic.attackMs, R.attackRange)
            band.dynamic.releaseMs = clamp(band.dynamic.releaseMs, R.releaseRange)
            band.dynamic.boostThresholdDB = clamp(band.dynamic.boostThresholdDB, R.boostThresholdRange)
            band.dynamic.boostRatio = clamp(band.dynamic.boostRatio, R.boostRatioRange)
            band.dynamic.maxBoostDB = clamp(band.dynamic.maxBoostDB, R.maxBoostRange)
            band.dynamic.rmsWindowMs = clamp(band.dynamic.rmsWindowMs, R.rmsWindowRange)
        }
        return band
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

extension StereoEQConfiguration {
    /// Every band of every lane in use for the current channel mode.
    var allLaneBands: [EQBand] {
        switch channelMode {
        case .linked: return linkedBands
        case .independent: return leftBands + rightBands
        case .midSide: return midBands + sideBands
        }
    }

    /// Enabled bands the engine renders at `sampleRate` ("N ACTIVE").
    func activeBandCount(sampleRate: Double) -> Int {
        EQBandRules.activeCount(in: allLaneBands, sampleRate: sampleRate)
    }

    /// Enabled bands the engine skips above Nyquist at `sampleRate`.
    func aboveNyquistBandCount(sampleRate: Double) -> Int {
        EQBandRules.aboveNyquistCount(in: allLaneBands, sampleRate: sampleRate)
    }
}
