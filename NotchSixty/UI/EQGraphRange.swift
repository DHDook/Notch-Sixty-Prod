import Foundation

/// E27 S2: the Equalizer graph's visible ranges and per-band curve rules as plain value types.
/// Drawing only; the values the page stores and the engine receives are unchanged.

/// The visible gain range of the magnitude view (design 7). Drags map to this range; the
/// number fields keep their own +/-24 dB limits.
enum EQGraphYRange: String, CaseIterable, Identifiable, Sendable {
    case plusMinus3
    case plusMinus6
    case plusMinus12
    case plusMinus24
    case plusMinus36
    case auto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plusMinus3: return "±3 dB"
        case .plusMinus6: return "±6 dB"
        case .plusMinus12: return "±12 dB"
        case .plusMinus24: return "±24 dB"
        case .plusMinus36: return "±36 dB"
        case .auto: return "Auto"
        }
    }

    /// The symmetric half-range of a fixed preset.
    var fixedHalfRange: Double? {
        switch self {
        case .plusMinus3: return 3
        case .plusMinus6: return 6
        case .plusMinus12: return 12
        case .plusMinus24: return 24
        case .plusMinus36: return 36
        case .auto: return nil
        }
    }

    /// Half-ranges Auto may choose: the presets, then the engine's +/-48 dB response clamp.
    static let autoSteps: [Double] = [3, 6, 12, 24, 36, 48]

    /// Auto: the smallest step at or above the largest |response| + 3 dB.
    static func autoHalfRange(peakMagnitudeDB: Double) -> Double {
        let wanted = (peakMagnitudeDB.isFinite ? abs(peakMagnitudeDB) : 0) + 3
        return autoSteps.first { $0 >= wanted } ?? autoSteps[autoSteps.count - 1]
    }

    /// The half-range to draw. `previous` is the half-range drawn last; while a drag is in
    /// progress (`growOnly`) Auto never shrinks, so the axis does not jump under the pointer.
    func halfRange(peakMagnitudeDB: Double, previous: Double?, growOnly: Bool) -> Double {
        if let fixed = fixedHalfRange { return fixed }
        let wanted = Self.autoHalfRange(peakMagnitudeDB: peakMagnitudeDB)
        if growOnly, let previous { return max(previous, wanted) }
        return wanted
    }

    /// Gridline spacing that keeps about four lines per side.
    static func gridStep(halfRange: Double) -> Double {
        switch halfRange {
        case ...3: return 1
        case ...6: return 2
        case ...12: return 3
        case ...24: return 6
        default: return 12
        }
    }
}

/// The visible frequency span: the full range to 0.49 fs, or the audible 20 Hz to 20 kHz.
enum EQGraphXZoom: String, CaseIterable, Identifiable, Sendable {
    case full
    case audible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .full: return "Full range"
        case .audible: return "Audible"
        }
    }

    static let audibleCeilingHz = 20_000.0

    /// The right-hand edge. Never above 0.49 fs, so a 44.1 kHz device cannot show 20 kHz+ it
    /// does not have. A non-finite or non-positive rate falls back to 48 kHz.
    func maximumFrequency(sampleRate: Double) -> Double {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let ceiling = max(EQGraphGeometry.minimumFrequency * 1.01, rate * 0.49)
        switch self {
        case .full: return ceiling
        case .audible: return min(Self.audibleCeilingHz, ceiling)
        }
    }
}

/// Which per-band curves sit under the total (design 8).
enum EQBandCurvesMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case selected
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .selected: return "Selected"
        case .all: return "All"
        }
    }
}

enum EQBandCurves {
    /// The bands whose curve is drawn: none, only the selection, or every enabled band that has
    /// a magnitude curve (imported FIR bands have none).
    static func drawn(
        mode: EQBandCurvesMode,
        bands: [EQBand],
        selectedID: UUID?
    ) -> [EQBand] {
        let candidates = bands.filter { $0.enabled && $0.type != .fir }
        switch mode {
        case .off: return []
        case .selected: return candidates.filter { $0.id == selectedID }
        case .all: return candidates
        }
    }

    /// The band's own response in dB (a one-band cascade).
    static func responseDB(of band: EQBand, sampleRate: Double, frequencyHz: Double) -> Double {
        let program = ProductionEQResponseMath.compile(bands: [band], sampleRate: sampleRate)
        return ProductionEQResponseMath.responseDB(program: program, sampleRate: sampleRate, frequencyHz: frequencyHz)
    }

    /// The two extreme curves of a dynamic band: its static gain moved to the lowest and highest
    /// gain the dynamics can reach (cut by up to |range|; boost by up to the maximum boost when
    /// the direction allows it), clamped to the +/-24 dB band limit. The graph shades between
    /// them. Nil for a static band or one whose type has no dynamic gain.
    static func dynamicEnvelope(of band: EQBand) -> (lower: EQBand, upper: EQBand)? {
        guard band.enabled, band.dynamic.enabled, band.type.supportsDynamicEQ else { return nil }
        let dynamic = band.dynamic
        let cut = dynamic.direction == .boostOnly ? 0 : min(0, dynamic.rangeDB)
        let boost = dynamic.direction == .cutOnly ? 0 : max(0, dynamic.maxBoostDB)
        let limits = StereoEQConfiguration.bandGainRange
        var lower = band
        var upper = band
        lower.gainDB = min(max(band.gainDB + cut, limits.lowerBound), limits.upperBound)
        upper.gainDB = min(max(band.gainDB + boost, limits.lowerBound), limits.upperBound)
        guard lower.gainDB != upper.gainDB else { return nil }
        return (lower, upper)
    }

    /// The bands of the lane the page is not editing, for the dashed ghost curve: the other of
    /// Left/Right or Mid/Side. Nil in Linked mode, which has one lane.
    static func otherLane(in configuration: StereoEQConfiguration) -> (label: String, bands: [EQBand])? {
        switch configuration.channelMode {
        case .linked:
            return nil
        case .independent:
            return configuration.editChannel == .right ? ("Left", configuration.leftBands) : ("Right", configuration.rightBands)
        case .midSide:
            return configuration.editChannel == .side ? ("Mid", configuration.midBands) : ("Side", configuration.sideBands)
        }
    }
}

/// Remembers the last Auto half-range so a drag only grows the axis (design 7). A reference
/// type kept in view state: reading and updating it does not invalidate the view.
final class EQAutoRangeMemory {
    private(set) var half: Double?

    func resolve(_ range: EQGraphYRange, peakMagnitudeDB: Double, growOnly: Bool) -> Double {
        let value = range.halfRange(peakMagnitudeDB: peakMagnitudeDB, previous: half, growOnly: growOnly)
        half = value
        return value
    }
}
