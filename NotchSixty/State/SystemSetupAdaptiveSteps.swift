import Foundation

// E25 S4: pure logic behind the adaptive Alignment, Bass and Correction steps. The steps read the arrangement
// class: feeds only on two channels, a mono-bass design for class C, a skipped bass step with the matrix reason for
// the downstream classes. No SwiftUI, no engine; nothing here runs on an audio thread. Delays are in milliseconds
// and every frame count is computed from the measurement's own rate, so the logic is rate-free.

// MARK: - What each step does for an arrangement

enum SystemSetupBassStepMode: Equatable, Sendable {
    /// A DSP-fed subwoofer on its own output: the existing joint design (class A).
    case dspSubwoofers
    /// Class C: the crossover frequency and slope of the pair's mono bass are designed from the feed measurements.
    case monoBass
    /// Nothing to design; the text says why.
    case skipped(reason: String)
}

enum SystemSetupAdaptiveSteps {
    /// Two channels in use means the feeds are measured and aligned; there is no profile and no sub output.
    static func isFeedSession(_ arrangement: SystemArrangement?) -> Bool {
        arrangement.map { $0.outputs.channelsInUse == 2 } ?? false
    }

    static func bassMode(_ arrangement: SystemArrangement?) -> SystemSetupBassStepMode? {
        guard let arrangement else { return nil }
        switch arrangement.arrangementClass {
        case .a:
            return arrangement.bass == .dspToSubOutputs && arrangement.subwooferCount > 0
                ? .dspSubwoofers : .skipped(reason: "You have no subwoofer output, so there is nothing to blend.")
        case .b: return .skipped(reason: "All speakers play full range, so there is no bass to blend.")
        case .c: return .monoBass
        case .d, .e: return .skipped(reason: SystemCapabilityMatrix.receiverSetsBass)
        }
    }

    /// Shown on the Alignment step in place of subwoofer controls, nil when the app aligns a subwoofer itself.
    static func alignmentSubNote(_ arrangement: SystemArrangement?) -> String? {
        guard let arrangement else { return nil }
        switch arrangement.arrangementClass {
        case .d, .e: return SystemCapabilityMatrix.receiverSetsBass
        case .b, .c: return "Alignment covers the left and right feeds: level, delay and polarity."
        case .a: return nil
        }
    }

    /// Receiver advice for the Bass and Correction steps (downstream classes only).
    static func receiverAdvice(_ arrangement: SystemArrangement?) -> String? {
        guard let arrangement else { return nil }
        switch arrangement.arrangementClass {
        case .d, .e: return SystemCapabilityMatrix.receiverAdvice
        default: return nil
        }
    }

    /// How the Correction and verification steps describe a downstream sub, nil when none is downstream.
    static func correctionNote(_ arrangement: SystemArrangement?) -> String? {
        guard let arrangement else { return nil }
        switch arrangement.arrangementClass {
        case .d, .e:
            return "Each feed is corrected as the full system through the receiver. The subwoofer is part of that system and is not separable."
        default: return nil
        }
    }

    /// The measurement suite's label for a measured source: a downstream sub cannot be told apart from the feed.
    static func measuredSourceLabel(_ source: MultichannelCalibrationSource, arrangement: SystemArrangement?) -> String {
        guard let arrangement, arrangement.arrangementClass == .d || arrangement.arrangementClass == .e else {
            return source.displayName
        }
        switch source {
        case .speaker(let role) where role == .frontLeft || role == .frontRight:
            return "\(source.displayName) (with the receiver's subwoofer, not separable)"
        default: return source.displayName
        }
    }

    /// Why the compiler would refuse this arrangement, or nil.
    static func compileIssue(_ arrangement: SystemArrangement) -> String? {
        SystemSetupArrangementPlanner.refusal(arrangement, preserving: nil)
    }

    // MARK: Alignment on the feeds

    /// The left and right feed calibration the alignment rows describe. Nil when a feed is not among the rows.
    static func feedCalibration(
        from alignment: SystemSetupAlignment
    ) -> (left: SpeakerFeedCalibration, right: SpeakerFeedCalibration)? {
        func calibration(_ role: OutputProgramRole) -> SpeakerFeedCalibration? {
            guard let row = alignment.rows.first(where: { $0.source == .speaker(role) }) else { return nil }
            return SpeakerFeedCalibration(
                trimDB: row.levelDB, delayMs: row.delayMilliseconds, polarityInverted: row.polarityInverted)
        }
        guard let left = calibration(.frontLeft), let right = calibration(.frontRight) else { return nil }
        return (left, right)
    }

    /// The arrangement with the feeds' calibration replaced; the mono-bass filter is untouched.
    static func applying(
        feeds: (left: SpeakerFeedCalibration, right: SpeakerFeedCalibration), to arrangement: SystemArrangement
    ) -> SystemArrangement {
        var result = arrangement
        var alignment = result.stereoAlignment ?? StereoBassAlignment()
        alignment.left = feeds.left
        alignment.right = feeds.right
        result.stereoAlignment = alignment
        return result
    }
}

// MARK: - Mono-bass design

/// The Bass step for class C. The pair's crossover frequency and slope come from how low the weaker feed plays.
///
/// Rule (documented, deterministic): measure each feed's seat-weighted response, smoothed to a third of an octave,
/// against its 250 Hz to 2 kHz mean. The extension point is where the response last falls below -6 dB scanning down
/// from 250 Hz. The crossover sits a half octave above the weaker feed's extension point so the shared band stays
/// inside what both speakers reproduce, in 5 Hz steps within 60 to 120 Hz. Speakers that stop above 90 Hz get the
/// 48 dB per octave slope so the overlap with the rest of the program stays short; otherwise 24 dB per octave.
struct SystemSetupMonoBassDesign: Equatable, Sendable {
    static let crossoverRangeHz = 60.0...120.0
    static let referenceBandHz = 250.0...2_000.0
    static let extensionThresholdDB = -6.0
    static let harmonicHeadroom = 1.5
    static let steepSlopeAboveHz = 90.0
    /// Analysis window after the direct arrival, seconds.
    static let windowSeconds = 0.25

    var crossoverHz: Double
    var filter: MonoBassFilter
    var leftExtensionHz: Double
    var rightExtensionHz: Double
    var sampleRate: Double

    static func make(
        seats: [MultichannelCalibrationSeat],
        measurements: [MultichannelCalibrationMeasurement],
        sampleRate: Double
    ) throws -> SystemSetupMonoBassDesign {
        let included = seats.filter { $0.included && $0.weight > 0 }
        guard !included.isEmpty else { throw SystemSetupBassError.noMainSpeakers }
        func extensionHz(_ role: OutputProgramRole) throws -> Double {
            let source = MultichannelCalibrationSource.speaker(role)
            var power = [Double](repeating: 0, count: analysisGrid.count)
            var totalWeight = 0.0
            for seat in included {
                guard let m = measurements.last(where: { $0.seatID == seat.id && $0.source == source }) else {
                    throw SystemSetupBassError.missingMeasurement(seat: seat.name, source: source.displayName)
                }
                guard let arrival = m.channel.quality.directArrivalSeconds, arrival.isFinite, arrival >= 0 else {
                    throw SystemSetupBassError.missingArrival(source: source.displayName)
                }
                let p = powerSpectrum(m.channel.impulseResponse, arrivalSeconds: arrival, sampleRate: sampleRate)
                for i in p.indices { power[i] += seat.weight * p[i] }
                totalWeight += seat.weight
            }
            return extensionPoint(power: power.map { $0 / max(totalWeight, 1e-12) })
        }
        let left = try extensionHz(.frontLeft)
        let right = try extensionHz(.frontRight)
        return design(leftExtensionHz: left, rightExtensionHz: right, sampleRate: sampleRate)
    }

    /// The crossover and slope for the two feeds' extension points.
    static func design(leftExtensionHz: Double, rightExtensionHz: Double, sampleRate: Double) -> SystemSetupMonoBassDesign {
        let weaker = max(leftExtensionHz, rightExtensionHz)
        let raw = weaker * harmonicHeadroom
        let stepped = (raw / 5).rounded() * 5
        let fc = min(max(stepped, crossoverRangeHz.lowerBound), crossoverRangeHz.upperBound)
        let slope = weaker >= steepSlopeAboveHz ? 48 : 24
        return SystemSetupMonoBassDesign(
            crossoverHz: fc, filter: MonoBassFilter(family: .linkwitzRiley, slopeDBPerOctave: slope),
            leftExtensionHz: leftExtensionHz, rightExtensionHz: rightExtensionHz, sampleRate: sampleRate)
    }

    // MARK: Analysis

    /// 20 to 250 Hz at twelve points per octave, then the reference band at four points per octave.
    private static let lowGrid: [Double] = (0...Int(ceil(12 * log2(250.0 / 20.0)))).map { 20 * pow(2, Double($0) / 12) }
    private static let referenceGrid: [Double] = {
        let octaves = log2(referenceBandHz.upperBound / referenceBandHz.lowerBound)
        return (0...Int(ceil(4 * octaves))).map { referenceBandHz.lowerBound * pow(2, Double($0) / 4) }
    }()
    private static let analysisGrid: [Double] = lowGrid + referenceGrid

    /// Squared magnitude at each analysis frequency, by a direct sum over the windowed response.
    static func powerSpectrum(_ impulse: [Float], arrivalSeconds: Double, sampleRate: Double) -> [Double] {
        let start = max(0, Int((arrivalSeconds - 0.0005) * sampleRate))
        let length = min(impulse.count - start, Int(windowSeconds * sampleRate))
        guard length > 16 else { return [Double](repeating: 0, count: analysisGrid.count) }
        let fadeStart = Int(Double(length) * 0.8)
        let window: (Int) -> Double = { n in
            n < fadeStart ? 1 : 0.5 * (1 + cos(Double.pi * Double(n - fadeStart) / Double(length - fadeStart)))
        }
        return analysisGrid.map { f in
            let omega = 2 * Double.pi * f / sampleRate
            let step = (cos(omega), -sin(omega))
            var rotor = (1.0, 0.0)
            var re = 0.0, im = 0.0
            for n in 0..<length {
                let x = Double(impulse[start + n]) * window(n)
                re += x * rotor.0
                im += x * rotor.1
                rotor = (rotor.0 * step.0 - rotor.1 * step.1, rotor.0 * step.1 + rotor.1 * step.0)
            }
            return re * re + im * im
        }
    }

    /// Where the third-octave-smoothed response last falls below the threshold scanning down from 250 Hz; 20 Hz when
    /// it never does.
    static func extensionPoint(power: [Double]) -> Double {
        let lowCount = lowGrid.count
        let reference = Array(power[lowCount...])
        let referenceMean = reference.reduce(0, +) / Double(max(reference.count, 1))
        guard referenceMean > 0 else { return lowGrid.last! }
        let halfWidth = pow(2, 1.0 / 6)
        func smoothed(_ i: Int) -> Double {
            let f = lowGrid[i]
            var sum = 0.0, count = 0.0
            for j in 0..<lowCount where lowGrid[j] >= f / halfWidth && lowGrid[j] <= f * halfWidth {
                sum += power[j]; count += 1
            }
            return 10 * log10(max(sum / max(count, 1) / referenceMean, 1e-12))
        }
        for i in stride(from: lowCount - 1, through: 0, by: -1) where smoothed(i) < extensionThresholdDB {
            return lowGrid[i]
        }
        return lowGrid[0]
    }
}
