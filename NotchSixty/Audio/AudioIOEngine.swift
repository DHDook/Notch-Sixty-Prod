import Combine
import CoreAudio
import Foundation

enum EQFilterType: String, CaseIterable, Identifiable, Codable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case bandPass
    case linkwitzTransform
    case tilt
    case fir
    case notch
    case allPass

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .bandPass: return "Band Pass"
        case .linkwitzTransform: return "Linkwitz Transform"
        case .tilt: return "Tilt"
        case .fir: return "FIR"
        case .notch: return "Notch"
        case .allPass: return "All-Pass"
        }
    }


    var supportsSlope: Bool {
        switch self {
        case .lowShelf, .highShelf, .lowPass, .highPass: return true
        default: return false
        }
    }

    var dynamicEQShape: N60DynamicEQShape? {
        switch self {
        case .peaking: return N60DynamicEQShapePeak
        case .lowShelf: return N60DynamicEQShapeLowShelf
        case .highShelf: return N60DynamicEQShapeHighShelf
        case .bandPass: return N60DynamicEQShapeBandPass
        case .tilt: return N60DynamicEQShapeTilt
        case .notch: return N60DynamicEQShapeNotch
        case .lowPass, .highPass, .linkwitzTransform, .fir, .allPass: return nil
        }
    }

    var supportsDynamicEQ: Bool { dynamicEQShape != nil }

    var cType: N60BiquadFilterType {
        switch self {
        case .peaking: return N60BiquadFilterTypePeaking
        case .lowShelf: return N60BiquadFilterTypeLowShelf
        case .highShelf: return N60BiquadFilterTypeHighShelf
        case .lowPass: return N60BiquadFilterTypeLowPass
        case .highPass: return N60BiquadFilterTypeHighPass
        case .bandPass: return N60BiquadFilterTypeBandPass
        case .linkwitzTransform: return N60BiquadFilterTypeLinkwitzTransform
        case .tilt: return N60BiquadFilterTypeTilt
        case .fir:
            preconditionFailure("FIR EQ bands are convolution assets, not biquad filter types.")
        case .notch: return N60BiquadFilterTypeNotch
        case .allPass: return N60BiquadFilterTypeAllPass
        }
    }
}

enum EQFilterSlope: Int, CaseIterable, Identifiable, Codable, Sendable {
    case db6 = 6
    case db12 = 12
    case db18 = 18
    case db24 = 24
    case db36 = 36
    case db48 = 48
    case db60 = 60
    case db72 = 72
    case db84 = 84
    case db96 = 96

    var id: Int { rawValue }
    var displayName: String { "\(rawValue) dB/oct" }
    var order: Int { rawValue / 6 }
}

enum EQPhaseMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case minimumPhase
    case mixedPhase
    case linearPhase

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimumPhase: return "Minimum phase"
        case .mixedPhase: return "Mixed phase"
        case .linearPhase: return "Linear phase"
        }
    }
}

struct EQBandDynamicConfiguration: Equatable, Codable, Sendable {
    static let thresholdRange = -60.0...0.0
    static let ratioRange = 1.0...10.0
    static let rangeRange = -24.0...0.0
    static let attackRange = 1.0...100.0
    static let releaseRange = 10.0...1_000.0
    static let boostThresholdRange = -60.0...0.0
    static let boostRatioRange = 1.0...10.0
    static let maxBoostRange = 0.0...12.0
    static let rmsWindowRange = 5.0...200.0

    var enabled = false
    var thresholdDB = -24.0
    var ratio = 2.0
    var rangeDB = -24.0
    var attackMs = 10.0
    var releaseMs = 100.0
    var direction: DynamicEQDirection = .cutOnly
    var boostThresholdDB = -40.0
    var boostRatio = 2.0
    var maxBoostDB = 6.0
    var detectorMode: DynamicEQDetectorMode = .peak
    var rmsWindowMs = 50.0

    var isValid: Bool {
        thresholdDB.isFinite && Self.thresholdRange.contains(thresholdDB)
            && ratio.isFinite && Self.ratioRange.contains(ratio)
            && rangeDB.isFinite && Self.rangeRange.contains(rangeDB)
            && attackMs.isFinite && Self.attackRange.contains(attackMs)
            && releaseMs.isFinite && Self.releaseRange.contains(releaseMs)
            && boostThresholdDB.isFinite && Self.boostThresholdRange.contains(boostThresholdDB)
            && boostRatio.isFinite && Self.boostRatioRange.contains(boostRatio)
            && maxBoostDB.isFinite && Self.maxBoostRange.contains(maxBoostDB)
            && rmsWindowMs.isFinite && Self.rmsWindowRange.contains(rmsWindowMs)
    }
}

struct EQFIRKernel: Equatable, Codable, Sendable {
    var name: String
    var sampleRate: Double?
    var taps: [Float]

    init(name: String, sampleRate: Double? = nil, taps: [Float]) {
        self.name = name
        self.sampleRate = sampleRate
        self.taps = taps
    }

    func validateMetadata() throws {
        guard !taps.isEmpty, taps.count <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw EQConfigurationError.invalidFIRTapCount(taps.count)
        }
        guard taps.allSatisfy(\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        if let sampleRate {
            guard sampleRate.isFinite, sampleRate > 0 else {
                throw EQConfigurationError.firSampleRateMismatch(filter: sampleRate, output: 0)
            }
        }
    }

    func validate(for outputSampleRate: Double) throws {
        try validateMetadata()
        if let sampleRate {
            guard outputSampleRate.isFinite,
                  outputSampleRate > 0,
                  abs(sampleRate - outputSampleRate) < 0.5 else {
                throw EQConfigurationError.firSampleRateMismatch(filter: sampleRate, output: outputSampleRate)
            }
        }
    }

    var conservativeBoostDB: Double {
        let l1 = taps.reduce(0.0) { $0 + abs(Double($1)) }
        guard l1 > 1.0 else { return 0.0 }
        return 20.0 * log10(l1)
    }

    static func validation(sampleRate: Double? = nil) -> EQFIRKernel {
        EQFIRKernel(name: "Validation FIR", sampleRate: sampleRate, taps: [0.25, 0.5, 0.25])
    }
}

enum EQFIRCompiler {
    static func cascade(base: [Float] = [1.0], kernels: [EQFIRKernel]) throws -> [Float] {
        guard !base.isEmpty, base.allSatisfy(\.isFinite) else {
            throw EQConfigurationError.nonFiniteFIRTap
        }
        var combined = base
        for kernel in kernels {
            let outputCount64 = UInt64(combined.count) + UInt64(kernel.taps.count) - 1
            guard outputCount64 <= UInt64(N60_CONVOLUTION_MAX_TAPS) else {
                throw EQConfigurationError.firTapBudgetExceeded(Int(outputCount64))
            }
            let outputCount = Int(outputCount64)
            var output = [Float](repeating: 0, count: outputCount)
            let ok = combined.withUnsafeBufferPointer { lhs in
                kernel.taps.withUnsafeBufferPointer { rhs in
                    output.withUnsafeMutableBufferPointer { destination in
                        N60FIRConvolveControlPlane(
                            lhs.baseAddress!, UInt32(lhs.count),
                            rhs.baseAddress!, UInt32(rhs.count),
                            destination.baseAddress!, UInt32(destination.count)
                        )
                    }
                }
            }
            guard ok else { throw EQConfigurationError.firCascadeFailed }
            combined = output
        }
        return combined
    }
}

struct EQBand: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var enabled: Bool
    var type: EQFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double
    var slope: EQFilterSlope
    var constantQ: Bool
    var linkwitzTargetHz: Double
    var linkwitzTargetQ: Double
    var firKernel: EQFIRKernel?
    var dynamic: EQBandDynamicConfiguration

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        type: EQFilterType = .peaking,
        frequencyHz: Double = 1_000,
        gainDB: Double = 0,
        q: Double = 0.707,
        slope: EQFilterSlope = .db12,
        constantQ: Bool = false,
        linkwitzTargetHz: Double = 40.0,
        linkwitzTargetQ: Double = 0.707,
        firKernel: EQFIRKernel? = nil,
        dynamic: EQBandDynamicConfiguration = EQBandDynamicConfiguration()
    ) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
        self.slope = slope
        self.constantQ = constantQ
        self.linkwitzTargetHz = linkwitzTargetHz
        self.linkwitzTargetQ = linkwitzTargetQ
        self.firKernel = firKernel
        self.dynamic = dynamic
    }

    var compiledCType: N60BiquadFilterType {
        if type == .peaking && constantQ {
            return N60BiquadFilterTypePeakingConstantQ
        }
        return type.cType
    }

    func linkwitzCoefficients(sampleRate: Double) -> N60BiquadCoefficients? {
        guard type == .linkwitzTransform else { return nil }
        var coefficients = N60BiquadCoefficients()
        guard N60BiquadDesignLinkwitzTransform(
            sampleRate,
            frequencyHz,
            q,
            linkwitzTargetHz,
            linkwitzTargetQ,
            &coefficients
        ) else { return nil }
        return coefficients
    }

    func compiledSections(sampleRate: Double) throws -> [N60BiquadBandSnapshot] {
        func snapshot(
            type: N60BiquadFilterType,
            gainDB: Double,
            q: Double,
            coefficients: N60BiquadCoefficients
        ) -> N60BiquadBandSnapshot {
            var result = N60BiquadBandSnapshot()
            result.enabled = true
            result.type = type
            result.frequencyHz = frequencyHz
            result.gainDB = gainDB
            result.q = q
            result.coefficients = coefficients
            return result
        }

        if type == .fir {
            return []
        }

        if type == .linkwitzTransform {
            guard let coefficients = linkwitzCoefficients(sampleRate: sampleRate) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return [snapshot(type: compiledCType, gainDB: 0, q: q, coefficients: coefficients)]
        }

        if type == .tilt {
            // Commercial convention: gainDB is the total low-to-high differential.
            // Positive tilt raises highs and lowers lows symmetrically by half.
            var low = N60BiquadCoefficients()
            var high = N60BiquadCoefficients()
            let half = gainDB * 0.5
            guard N60BiquadDesign(N60BiquadFilterTypeLowShelf, sampleRate, frequencyHz, -half, 0.707, &low),
                  N60BiquadDesign(N60BiquadFilterTypeHighShelf, sampleRate, frequencyHz, half, 0.707, &high) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return [
                snapshot(type: N60BiquadFilterTypeLowShelf, gainDB: -half, q: 0.707, coefficients: low),
                snapshot(type: N60BiquadFilterTypeHighShelf, gainDB: half, q: 0.707, coefficients: high),
            ]
        }

        if type == .lowPass || type == .highPass {
            let order = UInt32(slope.order)
            let count = N60BiquadButterworthSectionCount(order)
            guard count > 0, count <= UInt32(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return try (0..<count).map { sectionIndex in
                var coefficients = N60BiquadCoefficients()
                guard N60BiquadDesignButterworthSection(
                    type.cType, sampleRate, frequencyHz, order, sectionIndex, &coefficients
                ) else { throw EQConfigurationError.invalidBand(index: Int(sectionIndex)) }
                return snapshot(type: type.cType, gainDB: 0, q: q, coefficients: coefficients)
            }
        }

        if type == .lowShelf || type == .highShelf {
            let order = slope.order
            let pairCount = order / 2
            let hasFirst = order.isMultiple(of: 2) == false
            var result: [N60BiquadBandSnapshot] = []
            result.reserveCapacity((order + 1) / 2)
            if hasFirst {
                var coefficients = N60BiquadCoefficients()
                let sectionGain = gainDB / Double(order)
                guard N60BiquadDesignFirstOrderShelf(
                    type.cType, sampleRate, frequencyHz, sectionGain, &coefficients
                ) else { throw EQConfigurationError.invalidBand(index: 0) }
                result.append(snapshot(type: type.cType, gainDB: sectionGain, q: q, coefficients: coefficients))
            }
            if pairCount > 0 {
                let sectionGain = gainDB * 2.0 / Double(order)
                for pair in 0..<pairCount {
                    var coefficients = N60BiquadCoefficients()
                    guard N60BiquadDesign(type.cType, sampleRate, frequencyHz, sectionGain, q, &coefficients) else {
                        throw EQConfigurationError.invalidBand(index: pair)
                    }
                    result.append(snapshot(type: type.cType, gainDB: sectionGain, q: q, coefficients: coefficients))
                }
            }
            guard result.count <= Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND) else {
                throw EQConfigurationError.invalidBand(index: 0)
            }
            return result
        }

        var coefficients = N60BiquadCoefficients()
        guard N60BiquadDesign(compiledCType, sampleRate, frequencyHz, gainDB, q, &coefficients) else {
            throw EQConfigurationError.invalidBand(index: 0)
        }
        return [snapshot(type: compiledCType, gainDB: gainDB, q: q, coefficients: coefficients)]
    }
}

enum EQConfigurationError: Error, LocalizedError, Equatable {
    case tooManyBands(Int)
    case invalidBand(index: Int)
    case allPassRequiresMinimumPhase
    case linearPhaseDesignFailed
    case mixedPhaseDesignFailed
    case convolutionProgramUnavailable
    case firKernelRequired
    case invalidFIRTapCount(Int)
    case nonFiniteFIRTap
    case firSampleRateMismatch(filter: Double, output: Double)
    case firTapBudgetExceeded(Int)
    case firCascadeFailed

    var errorDescription: String? {
        switch self {
        case .tooManyBands(let count):
            return "Parametric EQ supports at most \(Int(N60_MAX_EQ_BANDS)) bands; configuration contains \(count)."
        case .invalidBand(let index):
            return "EQ band \(index + 1) is invalid for the current output sample rate."
        case .allPassRequiresMinimumPhase:
            return "User All-Pass bands require Minimum phase EQ mode; Mixed Phase owns its correction all-pass sections internally."
        case .linearPhaseDesignFailed:
            return "Unable to design the linear-phase FIR for the current EQ configuration."
        case .mixedPhaseDesignFailed:
            return "Unable to design the bounded all-pass correction for the current Mixed Phase EQ configuration."
        case .convolutionProgramUnavailable:
            return "No safe FIR program slot is currently available."
        case .firKernelRequired:
            return "FIR EQ bands require an impulse-response kernel before they can be enabled."
        case .invalidFIRTapCount(let count):
            return "FIR EQ tap count \(count) is outside the supported 1...\(Int(N60_CONVOLUTION_MAX_TAPS)) range."
        case .nonFiniteFIRTap:
            return "FIR EQ coefficients must all be finite."
        case .firSampleRateMismatch(let filter, let output):
            return "FIR EQ kernel rate \(filter) Hz does not match the active output rate \(output) Hz."
        case .firTapBudgetExceeded(let count):
            return "The cascaded EQ FIR would require \(count) taps, exceeding the \(Int(N60_CONVOLUTION_MAX_TAPS))-tap realtime budget."
        case .firCascadeFailed:
            return "Unable to compile the active per-band FIR kernels into the EQ convolution program."
        }
    }
}

struct DSPGainConfiguration: Equatable, Codable, Sendable {
    static let inputPreampRange = -60.0...24.0
    static let headroomAttenuationRange = -48.0...0.0
    static let outputGainRange = -60.0...12.0

    var inputPreampDB: Double = 0
    var headroomAttenuationDB: Double = 0
    var outputGainDB: Double = 0

    static func linearGain(forDB db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }
}

enum DSPGainConfigurationError: Error, LocalizedError, Equatable {
    case invalidInputPreamp(Double)
    case invalidHeadroomAttenuation(Double)
    case invalidOutputGain(Double)

    var errorDescription: String? {
        switch self {
        case .invalidInputPreamp(let value):
            return "Input preamp \(value) dB is outside the supported -60...+24 dB range."
        case .invalidHeadroomAttenuation(let value):
            return "Headroom attenuation \(value) dB is outside the supported -48...0 dB range."
        case .invalidOutputGain(let value):
            return "Output gain \(value) dB is outside the supported -60...+12 dB range."
        }
    }
}

enum CrossoverTopology: String, CaseIterable, Identifiable, Codable, Sendable {
    case linkwitzRiley24
    case linkwitzRiley48

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linkwitzRiley24: return "Linkwitz-Riley 24 dB/oct"
        case .linkwitzRiley48: return "Linkwitz-Riley 48 dB/oct"
        }
    }

    var cType: N60CrossoverTopology {
        switch self {
        case .linkwitzRiley24: return N60CrossoverTopologyLinkwitzRiley24
        case .linkwitzRiley48: return N60CrossoverTopologyLinkwitzRiley48
        }
    }
}

enum CrossoverMonitorMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case recombined
    case mainsOnly
    case subOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recombined: return "Recombined preview"
        case .mainsOnly: return "Mains only"
        case .subOnly: return "Sub only"
        }
    }

    var cType: N60CrossoverMonitorMode {
        switch self {
        case .recombined: return N60CrossoverMonitorModeRecombined
        case .mainsOnly: return N60CrossoverMonitorModeMainsOnly
        case .subOnly: return N60CrossoverMonitorModeSubOnly
        }
    }
}

enum SpeakerCrossoverMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case mainsSub
    case biAmp
    case triAmp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mainsSub: return "Mains + Sub"
        case .biAmp: return "Bi-Amp"
        case .triAmp: return "Tri-Amp"
        }
    }

    var cType: N60SpeakerCrossoverMode {
        switch self {
        case .mainsSub: return N60SpeakerCrossoverModeMainsSub
        case .biAmp: return N60SpeakerCrossoverModeBiAmp
        case .triAmp: return N60SpeakerCrossoverModeTriAmp
        }
    }

    func supports(bus: SpeakerOutputBus) -> Bool {
        if bus == .leftFullRange || bus == .rightFullRange { return true }
        switch self {
        case .mainsSub:
            return bus == .leftHigh || bus == .rightHigh || bus == .subMono
        case .biAmp:
            return bus == .leftLow || bus == .rightLow || bus == .leftHigh || bus == .rightHigh
        case .triAmp:
            return bus == .leftLow || bus == .rightLow
                || bus == .leftMid || bus == .rightMid
                || bus == .leftHigh || bus == .rightHigh
        }
    }
}

struct BassManagementConfiguration: Equatable, Codable, Sendable {
    static let frequencyRange = 20.0...500.0
    static let subGainRange = -24.0...12.0
    static let subPhaseAlignmentQRange = 0.1...10.0
    static let speakerFrequencyRange = 20.0...20_000.0

    var enabled = false
    var frequencyHz: Double = 80
    var topology: CrossoverTopology = .linkwitzRiley24
    var monitorMode: CrossoverMonitorMode = .recombined
    var subGainDB: Double = 0
    var subPolarityInverted = false
    var subPhaseAlignmentEnabled = false
    var subPhaseAlignmentFrequencyHz: Double = 80
    var subPhaseAlignmentQ: Double = 0.7
    // Optional for backward-compatible profile decoding. Nil preserves the
    // existing recombined-stereo bass-management behavior.
    var physicalOutputMode: SpeakerCrossoverMode? = nil
    var upperFrequencyHz: Double? = nil
    var upperTopology: CrossoverTopology? = nil

    var lowerFrequencyRange: ClosedRange<Double> {
        switch physicalOutputMode {
        case .biAmp, .triAmp:
            return Self.speakerFrequencyRange
        case .mainsSub, .none:
            return Self.frequencyRange
        }
    }

    func makeSpeakerBusSplitterSnapshot(sampleRate: Double) throws -> N60SpeakerBusSplitterSnapshot {
        guard enabled, let physicalOutputMode else {
            throw BassManagementConfigurationError.physicalCrossoverModeRequired
        }
        guard frequencyHz.isFinite, lowerFrequencyRange.contains(frequencyHz),
              frequencyHz < sampleRate * 0.5 else {
            throw BassManagementConfigurationError.invalidFrequency(frequencyHz)
        }
        let upper = upperFrequencyHz ?? max(frequencyHz + 1.0, frequencyHz * 2.0)
        if physicalOutputMode == .triAmp {
            guard upper.isFinite, Self.speakerFrequencyRange.contains(upper),
                  upper > frequencyHz, upper < sampleRate * 0.5 else {
                throw BassManagementConfigurationError.invalidUpperFrequency(upper)
            }
        }
        var snapshot = N60SpeakerBusSplitterSnapshot()
        guard N60SpeakerBusSplitterSnapshotMake(
            sampleRate,
            physicalOutputMode.cType,
            frequencyHz,
            topology.cType,
            upper,
            (upperTopology ?? topology).cType,
            DSPGainConfiguration.linearGain(forDB: subGainDB),
            subPolarityInverted,
            subPhaseAlignmentEnabled,
            subPhaseAlignmentFrequencyHz,
            subPhaseAlignmentQ,
            &snapshot
        ) else {
            throw BassManagementConfigurationError.speakerBusSplitterDesignFailed
        }
        return snapshot
    }
}

enum BassManagementConfigurationError: Error, LocalizedError, Equatable {
    case invalidFrequency(Double)
    case invalidSubGain(Double)
    case invalidSubPhaseAlignmentFrequency(Double)
    case invalidSubPhaseAlignmentQ(Double)
    case invalidUpperFrequency(Double)
    case physicalCrossoverModeRequired
    case physicalCrossoverChangeRequiresIdle
    case speakerBusSplitterDesignFailed
    case graphDesignFailed

    var errorDescription: String? {
        switch self {
        case .invalidFrequency(let value):
            return "Crossover frequency \(value) Hz is outside the supported 20...500 Hz range."
        case .invalidSubGain(let value):
            return "Sub gain \(value) dB is outside the supported -24...+12 dB range."
        case .invalidSubPhaseAlignmentFrequency(let value):
            return "Sub phase-alignment frequency \(value) Hz is outside the supported 20...500 Hz range."
        case .invalidSubPhaseAlignmentQ(let value):
            return "Sub phase-alignment Q \(value) is outside the supported 0.1...10 range."
        case .invalidUpperFrequency(let value):
            return "Upper crossover frequency \(value) Hz must be above the lower crossover and below the active Nyquist limit."
        case .physicalCrossoverModeRequired:
            return "Choose Mains + Sub, Bi-Amp, or Tri-Amp before routing split speaker buses."
        case .physicalCrossoverChangeRequiresIdle:
            return "Stop processing before changing a physical speaker crossover."
        case .speakerBusSplitterDesignFailed:
            return "Unable to design the physical speaker crossover for the active output sample rate."
        case .graphDesignFailed:
            return "Unable to design the crossover for the current output sample rate."
        }
    }
}

struct RoomCorrectionFilter: Equatable, Codable, Sendable {
    var name: String
    var sampleRate: Double?
    var leftTaps: [Float]
    var rightTaps: [Float]?
    var declaredLatencyFrames: UInt32

    static let validation = RoomCorrectionFilter(
        name: "Deterministic 3-tap validation",
        sampleRate: nil,
        leftTaps: [0.25, 0.5, 0.25],
        rightTaps: nil,
        declaredLatencyFrames: 1
    )

    func validateSampleRate(forOutputSampleRate outputSampleRate: Double) throws {
        guard let sampleRate else { return }
        guard sampleRate.isFinite,
              abs(sampleRate - outputSampleRate) < 0.5 else {
            throw RoomCorrectionConfigurationError.sampleRateMismatch(
                filter: sampleRate,
                output: outputSampleRate
            )
        }
    }
}

struct RoomCorrectionConfiguration: Equatable, Codable, Sendable {
    var enabled = false
    var filter: RoomCorrectionFilter?
}

enum RoomCorrectionConfigurationError: Error, LocalizedError, Equatable {
    case filterRequired
    case invalidTapCount(Int)
    case mismatchedStereoTapCount(left: Int, right: Int)
    case nonFiniteTap
    case sampleRateMismatch(filter: Double, output: Double)
    case invalidDeclaredLatency(UInt32)
    case convolutionProgramUnavailable
    case graphAttachmentFailed

    var errorDescription: String? {
        switch self {
        case .filterRequired:
            return "Room correction cannot be enabled until a correction filter is loaded."
        case .invalidTapCount(let count):
            return "Room-correction FIR tap count \(count) is outside the supported 1...\(Int(N60_CONVOLUTION_MAX_TAPS)) range."
        case .mismatchedStereoTapCount(let left, let right):
            return "Room-correction left/right FIR lengths must match (left \(left), right \(right))."
        case .nonFiniteTap:
            return "Room-correction FIR coefficients must all be finite."
        case .sampleRateMismatch(let filter, let output):
            return "Room-correction filter rate \(filter) Hz does not match the active output rate \(output) Hz."
        case .invalidDeclaredLatency(let frames):
            return "Room-correction declared filter latency \(frames) frames exceeds the FIR length."
        case .convolutionProgramUnavailable:
            return "No safe room-correction FIR program slot is currently available."
        case .graphAttachmentFailed:
            return "Unable to attach the prepared room-correction FIR to the DSP graph."
        }
    }
}


struct SpeakerIRFilter: Equatable, Codable, Sendable {
    var name: String
    var sampleRate: Double?
    var leftTaps: [Float]
    var rightTaps: [Float]?
    var declaredLatencyFrames: UInt32

    static let validation = SpeakerIRFilter(
        name: "Deterministic Speaker IR validation",
        sampleRate: nil,
        leftTaps: [0.20, 0.60, 0.20],
        rightTaps: nil,
        declaredLatencyFrames: 1
    )

    func validateSampleRate(forOutputSampleRate outputSampleRate: Double) throws {
        guard let sampleRate else { return }
        guard sampleRate.isFinite,
              abs(sampleRate - outputSampleRate) < 0.5 else {
            throw SpeakerIRConfigurationError.sampleRateMismatch(
                filter: sampleRate,
                output: outputSampleRate
            )
        }
    }
}

struct SpeakerIRConfiguration: Equatable, Codable, Sendable {
    var enabled = false
    var filter: SpeakerIRFilter?
}

enum SpeakerIRConfigurationError: Error, LocalizedError, Equatable {
    case filterRequired
    case invalidTapCount(Int)
    case mismatchedStereoTapCount(left: Int, right: Int)
    case nonFiniteTap
    case sampleRateMismatch(filter: Double, output: Double)
    case invalidDeclaredLatency(UInt32)
    case convolutionProgramUnavailable
    case graphAttachmentFailed

    var errorDescription: String? {
        switch self {
        case .filterRequired:
            return "Speaker IR cannot be enabled until an impulse response is loaded."
        case .invalidTapCount(let count):
            return "Speaker IR tap count \(count) is outside the supported 1...\(Int(N60_CONVOLUTION_MAX_TAPS)) range."
        case .mismatchedStereoTapCount(let left, let right):
            return "Speaker IR left/right FIR lengths must match (left \(left), right \(right))."
        case .nonFiniteTap:
            return "Speaker IR coefficients must all be finite."
        case .sampleRateMismatch(let filter, let output):
            return "Speaker IR rate \(filter) Hz does not match the active output rate \(output) Hz."
        case .invalidDeclaredLatency(let frames):
            return "Speaker IR declared filter latency \(frames) frames exceeds the FIR length."
        case .convolutionProgramUnavailable:
            return "No safe Speaker IR FIR program slot is currently available."
        case .graphAttachmentFailed:
            return "Unable to attach the prepared Speaker IR to the DSP graph."
        }
    }
}

struct EQConfiguration: Equatable, Sendable {
    static let maximumBandCount = Int(N60_MAX_EQ_BANDS)

    var phaseMode: EQPhaseMode
    var bypassed: Bool
    var bands: [EQBand]

    init(
        phaseMode: EQPhaseMode = .minimumPhase,
        bypassed: Bool = false,
        bands: [EQBand] = []
    ) {
        self.phaseMode = phaseMode
        self.bypassed = bypassed
        self.bands = bands
    }

    var enabledBandCount: Int {
        bands.reduce(into: 0) { count, band in
            if band.enabled { count += 1 }
        }
    }

    private func validateBand(_ band: EQBand, index: Int, sampleRate: Double) throws -> Bool {
        if band.type == .fir {
            guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
            try kernel.validate(for: sampleRate)
            return true
        }
        guard band.frequencyHz.isFinite,
              band.frequencyHz > 0,
              band.gainDB.isFinite,
              StereoEQConfiguration.bandGainRange.contains(band.gainDB),
              band.q.isFinite,
              band.q > 0 else {
            throw EQConfigurationError.invalidBand(index: index)
        }
        if band.type == .linkwitzTransform {
            guard band.linkwitzTargetHz.isFinite,
                  band.linkwitzTargetHz > 0,
                  band.linkwitzTargetHz < sampleRate * 0.5,
                  band.linkwitzTargetQ.isFinite,
                  band.linkwitzTargetQ > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
        }
        if band.dynamic.enabled {
            guard band.type.supportsDynamicEQ,
                  DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),
                  DynamicEQBandConfiguration.qRange.contains(band.q),
                  band.dynamic.isValid,
                  !(band.type == .notch && band.dynamic.direction != .cutOnly) else {
                throw EQConfigurationError.invalidBand(index: index)
            }
        }
        return band.frequencyHz < sampleRate * 0.5
    }

    func makeGraphSnapshot(
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration = DSPGainConfiguration(),
        bassManagementConfiguration: BassManagementConfiguration = BassManagementConfiguration()
    ) throws -> N60DSPGraphSnapshot {
        guard bands.count <= Self.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
        guard bassManagementConfiguration.frequencyHz.isFinite,
              bassManagementConfiguration.lowerFrequencyRange.contains(bassManagementConfiguration.frequencyHz) else {
            throw BassManagementConfigurationError.invalidFrequency(bassManagementConfiguration.frequencyHz)
        }
        if bassManagementConfiguration.physicalOutputMode == .triAmp {
            let upper = bassManagementConfiguration.upperFrequencyHz ?? .nan
            guard upper.isFinite, BassManagementConfiguration.speakerFrequencyRange.contains(upper),
                  upper > bassManagementConfiguration.frequencyHz, upper < sampleRate * 0.5 else {
                throw BassManagementConfigurationError.invalidUpperFrequency(upper)
            }
        }
        guard bassManagementConfiguration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(bassManagementConfiguration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(bassManagementConfiguration.subGainDB)
        }
        guard bassManagementConfiguration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(bassManagementConfiguration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                bassManagementConfiguration.subPhaseAlignmentFrequencyHz
            )
        }
        guard bassManagementConfiguration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(bassManagementConfiguration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(
                bassManagementConfiguration.subPhaseAlignmentQ
            )
        }

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.inputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.inputPreampDB)
        graph.headroomGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.headroomAttenuationDB)
        graph.outputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.outputGainDB)
        graph.eqBypassed = bypassed
        N60DSPGraphSnapshotClearEQ(&graph)

        if phaseMode != .linearPhase && !bypassed {
            var renderIndex: UInt32 = 0
            var mixedSource: [N60BiquadBandSnapshot] = []
            for (modelIndex, band) in bands.enumerated() where band.enabled {
                if phaseMode == .mixedPhase && band.type == .allPass {
                    throw EQConfigurationError.allPassRequiresMinimumPhase
                }
                guard try validateBand(band, index: modelIndex, sampleRate: sampleRate) else { continue }
                for section in try band.compiledSections(sampleRate: sampleRate) {
                    let compiledCapacity = UInt32(EQConfiguration.maximumBandCount * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND))
                    guard renderIndex < compiledCapacity,
                          N60DSPGraphSnapshotSetEQPreparedBand(
                            &graph, renderIndex, section.type, section.frequencyHz,
                            section.gainDB, section.q, section.coefficients, true
                          ) else {
                        throw EQConfigurationError.invalidBand(index: modelIndex)
                    }
                    if phaseMode == .mixedPhase && section.type != N60BiquadFilterTypeAllPass {
                        mixedSource.append(section)
                    }
                    renderIndex += 1
                }
            }

            if phaseMode == .mixedPhase {
                var design = N60MixedPhaseDesignInfo()
                let designed = mixedSource.withUnsafeBufferPointer { buffer in
                    N60MixedPhaseDesign(sampleRate, buffer.baseAddress, UInt32(buffer.count), &design)
                }
                guard designed else { throw EQConfigurationError.mixedPhaseDesignFailed }
                graph.mixedPhaseEnabled = true
                graph.mixedPhaseCorrectionSectionCount = design.sectionCount
                let totalCapacity = UInt32(EQConfiguration.maximumBandCount * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND) + 12)
                for correctionIndex in 0..<design.sectionCount {
                    let section = N60MixedPhaseDesignSectionAt(&design, correctionIndex)
                    guard renderIndex < totalCapacity,
                          N60DSPGraphSnapshotSetEQPreparedBand(
                            &graph, renderIndex, section.type, section.frequencyHz,
                            section.gainDB, section.q, section.coefficients, true
                          ) else {
                        throw EQConfigurationError.mixedPhaseDesignFailed
                    }
                    renderIndex += 1
                }
            }
        }

        if phaseMode != .linearPhase && !bypassed {
            let dynamicBands = bands.filter { $0.enabled && $0.type == .peaking && $0.dynamic.enabled }
            if !dynamicBands.isEmpty {
                guard N60DynamicsSnapshotSetDynamicEQEnabled(&graph.dynamics, true) else {
                    throw DynamicsConfigurationError.invalidDynamicEQ
                }
                for (index, band) in dynamicBands.enumerated() {
                    let dynamic = band.dynamic
                    guard N60DynamicsSnapshotSetDynamicEQBand(
                        &graph.dynamics,
                        sampleRate,
                        UInt32(index),
                        true,
                        band.frequencyHz,
                        Float(band.q),
                        0.0,
                        Float(dynamic.thresholdDB),
                        Float(dynamic.ratio),
                        Float(dynamic.rangeDB),
                        Float(dynamic.attackMs),
                        Float(dynamic.releaseMs),
                        dynamic.direction.cType,
                        Float(dynamic.boostThresholdDB),
                        Float(dynamic.boostRatio),
                        Float(dynamic.maxBoostDB),
                        dynamic.detectorMode.cType,
                        Float(dynamic.rmsWindowMs)
                    ) else {
                        throw EQConfigurationError.invalidBand(index: index)
                    }
                }
            }
        }

        guard N60DSPGraphSnapshotSetCrossover(
            &graph,
            bassManagementConfiguration.frequencyHz,
            bassManagementConfiguration.topology.cType,
            bassManagementConfiguration.monitorMode.cType,
            DSPGainConfiguration.linearGain(forDB: bassManagementConfiguration.subGainDB),
            bassManagementConfiguration.subPolarityInverted,
            bassManagementConfiguration.enabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        guard N60DSPGraphSnapshotSetSubPhaseAlignment(
            &graph,
            bassManagementConfiguration.subPhaseAlignmentFrequencyHz,
            bassManagementConfiguration.subPhaseAlignmentQ,
            bassManagementConfiguration.subPhaseAlignmentEnabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        return graph
    }

    func linearPhaseBands(sampleRate: Double) throws -> [N60LinearPhaseEQBand] {
        guard bands.count <= Self.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
        var result: [N60LinearPhaseEQBand] = []
        result.reserveCapacity(enabledBandCount)
        for (index, band) in bands.enumerated() where band.enabled {
            guard try validateBand(band, index: index, sampleRate: sampleRate) else { continue }
            guard band.type != .allPass else {
                throw EQConfigurationError.allPassRequiresMinimumPhase
            }
            if band.type == .fir { continue }
            for section in try band.compiledSections(sampleRate: sampleRate) {
                var cBand = N60LinearPhaseEQBand()
                cBand.enabled = true
                cBand.type = section.type
                cBand.frequencyHz = section.frequencyHz
                cBand.gainDB = section.gainDB
                cBand.q = section.q
                cBand.usesPreparedCoefficients = true
                cBand.preparedCoefficients = section.coefficients
                result.append(cBand)
            }
        }
        return result
    }
}

private struct PreparedEQFIRProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
    let designInfo: N60LinearPhaseEQDesignInfo?
}

private struct PreparedRoomCorrectionProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
}

private struct PreparedSpeakerIRProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
}

@MainActor
final class AudioIOEngine: ObservableObject {
    /// E6 S8: set by the app shell (on unless `e6.legacy-kernel` is on). The engine never reads
    /// the flag itself; with this false the kernel path runs exactly as before.
    var unifiedGraphEnabled = false

    /// E4 S14 (`e4.engine-lease`): when true, a live anti-noise target is guarded by the render
    /// path's dead-man lease. Set once at launch by the app; off enforces no lease.
    var activeQuietZoneLeaseEnabled = false
    private var activeQuietZoneLeaseKeeper: ActiveQuietZoneLeaseKeeper?

    /// E4 S18b: true when the lease is required and its renewal is running (the adaptive gate
    /// closes otherwise). With the lease flag off nothing is required, so this is true.
    var activeQuietZoneLeaseHealthy: Bool {
        !activeQuietZoneLeaseEnabled || activeQuietZoneLeaseKeeper?.isRunning == true
    }

    /// Starts or stops lease renewal to match whether anti-noise is live on the current session.
    private func syncActiveQuietZoneLease(active: Bool) {
        guard activeQuietZoneLeaseEnabled, active, let session = transportSession else {
            activeQuietZoneLeaseKeeper?.stop()
            activeQuietZoneLeaseKeeper = nil
            return
        }
        if activeQuietZoneLeaseKeeper == nil {
            activeQuietZoneLeaseKeeper = ActiveQuietZoneLeaseKeeper(
                renew: { [weak session] seconds in session?.renewActiveQuietZoneLease(seconds: seconds) },
                release: { [weak session] in session?.releaseActiveQuietZoneLease() }
            )
        }
        activeQuietZoneLeaseKeeper?.start()
    }

    /// E8 S4: the speaker routing a session renders, or nil. See `replaceSpeakerRoutingConfiguration`.
    private(set) var speakerRoutingConfiguration: SpeakerRoutingConfiguration?

    private let deviceCatalog: any OutputDeviceCataloging
    private let eventMonitor: AudioHardwareEventMonitor
    private let masterVolumeController: any MasterVolumeDeviceControlling
    private let globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring
    private let binauralProfileAssetStore: BinauralProfileAssetStore
    /// E6 S9c: converted HRTF assets per (asset, rate), shared by session start and live asset swaps.
    private let binauralAssetCache = BinauralResampledAssetCache()
    /// Newest live HRTF asset swap request; an older prepare that finishes later is dropped.
    private var headphoneAssetGeneration: UInt64 = 0
    /// The HRTF asset the running binaural graph renders (a requested swap is pending while it differs from the
    /// configuration's).
    private var renderedBinauralProfile: BinauralProfileReference?
    private let masterVolumeStore: (any MasterVolumePersisting)?
    /// Output whose stored software volume has already been restored. A sync
    /// for the same output (external change, device-list refresh) never
    /// overwrites the user's current level.
    private var masterVolumeSynchronizedOutputUID: String?
    private var lifecycle: AudioLifecycleStateMachine
    private var transportSession: CoreAudioTransportSession?
    private var nChannelTransportSession: CoreAudioNChannelTransportSession?
    private var binauralHeadphoneTransportSession: CoreAudioBinauralHeadphoneTransportSession?
    private var headTrackingController: SpatialHeadTrackingController?
    private var lifetimeArchivedCounters = AudioTransportCounters()
    private var processingSessionArchivedCounters = AudioTransportCounters()
    private var reconfigurationWorkItem: DispatchWorkItem?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryGeneration: UInt64 = 0
    private var recoveryConsecutiveBuildFailures = 0
    private var resumeAfterWake = false
    private var prepared = false
    private var activeEQFIRProgram: PreparedEQFIRProgram?
    private var nextEQFIRProgramSlot: UInt32 = 0
    private var activeRoomCorrectionProgram: PreparedRoomCorrectionProgram?
    private var nextRoomCorrectionProgramSlot: UInt32 = 0
    private var activeSpeakerIRProgram: PreparedSpeakerIRProgram?
    private var nextSpeakerIRProgramSlot: UInt32 = 0
    private var stagedRoomTreatment: LiveMIMORoomTreatmentPreparation?
    private var stagedAudioUnitRack: AudioUnitLiveRackSwitchboard?
    /// Set when a rate change or output recovery dropped a rack built for the
    /// previous format; cleared once the rebuild request has been issued.
    private var audioUnitRackRebuildPending = false
    /// Asked, on the main actor, to re-instantiate the plug-in rack at the
    /// current output format after the transport came back without it.
    var onAudioUnitRackRequiresRebuild: (@MainActor () -> Void)?
    /// Supplies the deployed room-correction filter re-synthesized for another
    /// output rate (the product layer owns the design source). The published
    /// configuration keeps the deployed filter; only the realtime program uses
    /// the adapted one.
    var roomCorrectionFilterAdapter: (@MainActor (RoomCorrectionFilter, Double) -> RoomCorrectionFilter?)?
    private var adaptedRoomCorrectionFilter:
        (source: RoomCorrectionFilter, sampleRate: Double, filter: RoomCorrectionFilter)?

    private(set) var sampleRateChangesHandled: UInt64 = 0
    private(set) var recoveryAttempts: UInt64 = 0
    private(set) var recoverySuccesses: UInt64 = 0
    private(set) var recoveryFailures: UInt64 = 0

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var routeConfiguration: AudioRouteConfiguration
    @Published private(set) var eqConfiguration = EQConfiguration()
    @Published private(set) var stereoEQConfiguration = StereoEQConfiguration()
    @Published private(set) var playbackControlConfiguration = PlaybackControlConfiguration()
    @Published private(set) var masterVolumeConfiguration = MasterVolumeConfiguration()
    @Published private(set) var masterVolumeCapabilities = MasterVolumeDeviceCapabilities.softwareOnly
    @Published private(set) var globalVolumeKeyMonitoringState: GlobalVolumeKeyMonitoringState = .stopped
    private(set) var softwareVolumeKeyStep = MasterVolumeKeyStep.fraction(denominator: 16)
    @Published private(set) var gainConfiguration = DSPGainConfiguration()
    @Published private(set) var bassManagementConfiguration = BassManagementConfiguration()
    @Published private(set) var multiOutputRoutingConfiguration: MultiOutputRoutingConfiguration?
    @Published private(set) var outputDeviceProfileConfiguration: OutputDeviceProfileConfiguration?
    @Published private(set) var headphoneDeviceProfileConfiguration: HeadphoneDeviceProfileConfiguration?
    @Published private(set) var speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()
    @Published private(set) var dynamicsConfiguration = DynamicsConfiguration()
    @Published private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()
    @Published private(set) var speakerIRConfiguration = SpeakerIRConfiguration()
    @Published private(set) var ambientCompensationRuntimeTarget =
        AmbientCompensationTarget.unity
    @Published private(set) var activeQuietZoneRuntimeTarget =
        ActiveQuietZoneRuntimeTarget.bypassed
    @Published private(set) var linearPhaseDesignInfo: N60LinearPhaseEQDesignInfo?
    @Published private(set) var headTrackingRuntimeStatus = HeadTrackingRuntimeStatus.disabled
    @Published private(set) var lastErrorDescription: String?
    @Published private(set) var lifecycleState: AudioLifecycleState
    /// E4 S7: the low-latency output profile Quiet Zone requests, and the
    /// buffer size it set on the current output (nil when off or not applied).
    @Published private(set) var lowLatencyOutputProfileActive = false
    @Published private(set) var lowLatencyOutputBufferFrames: UInt32?
    private let lowLatencyBufferProfile: LowLatencyOutputBufferProfile
    /// Restore deferred to the rebuild, so the physical output never changes
    /// size under a live tap aggregate.
    private var lowLatencyRestorePending = false

    init(
        deviceCatalog: any OutputDeviceCataloging = CoreAudioOutputDeviceCatalog(),
        initialRouteConfiguration: AudioRouteConfiguration = AudioRouteConfiguration(),
        eventMonitor: AudioHardwareEventMonitor = AudioHardwareEventMonitor(),
        masterVolumeController: any MasterVolumeDeviceControlling = CoreAudioMasterVolumeController(),
        globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring = CoreGraphicsGlobalVolumeKeyMonitor(),
        binauralProfileAssetStore: BinauralProfileAssetStore = BinauralProfileAssetStore(),
        masterVolumeStore: (any MasterVolumePersisting)? = nil,
        outputBufferSizeController: any OutputBufferSizeControlling = CoreAudioOutputBufferSizeController()
    ) {
        self.lowLatencyBufferProfile = LowLatencyOutputBufferProfile(
            controller: outputBufferSizeController
        )
        self.deviceCatalog = deviceCatalog
        self.masterVolumeStore = masterVolumeStore
        self.routeConfiguration = initialRouteConfiguration
        self.eventMonitor = eventMonitor
        self.masterVolumeController = masterVolumeController
        self.globalVolumeKeyMonitor = globalVolumeKeyMonitor
        self.binauralProfileAssetStore = binauralProfileAssetStore
        let lifecycle = AudioLifecycleStateMachine()
        self.lifecycle = lifecycle
        self.lifecycleState = lifecycle.state

        eventMonitor.onDeviceListChanged = { [weak self] in self?.handleDeviceListChanged() }
        eventMonitor.onSelectedOutputSampleRateChanged = { [weak self] in
            self?.scheduleSampleRateReconfiguration()
        }
        eventMonitor.onWillSleep = { [weak self] in self?.handleWillSleep() }
        eventMonitor.onDidWake = { [weak self] in self?.handleDidWake() }
        masterVolumeController.onExternalChange = { [weak self] in self?.handleMasterVolumeDeviceChange() }
        globalVolumeKeyMonitor.onVolumeIncrement = { [weak self] in self?.handleGlobalVolumeKey(direction: 1.0) }
        globalVolumeKeyMonitor.onVolumeDecrement = { [weak self] in self?.handleGlobalVolumeKey(direction: -1.0) }
    }

    var ambientCompensationAvailableHeadroomDB: Double {
        max(-gainConfiguration.headroomAttenuationDB, 0)
    }

    var ambientCompensationStereoSpeakerRuntimeAvailable: Bool {
        (transportSession != nil
            && nChannelTransportSession == nil
            && binauralHeadphoneTransportSession == nil
            && headphoneDeviceProfileConfiguration?.enabled != true)
            || ambientCompensationGraphRuntimeAvailable
    }

    /// E6 S9b: a graph-rendered N-channel speaker session runs ambient compensation in the graph (after the
    /// compressor and expander, before protection). Binaural headphones stay without it.
    var ambientCompensationGraphRuntimeAvailable: Bool {
        nChannelTransportSession != nil && liveGraphEditsAvailable
    }

    func replaceAmbientCompensationRuntimeTarget(
        _ target: AmbientCompensationTarget
    ) throws {
        let values = [
            target.levelDB,
            target.lowSupportDB,
            target.presenceSupportDB,
            target.detailSupportDB,
            target.confidence,
            target.ambientDeltaDB,
        ]
        guard values.allSatisfy(\.isFinite),
              target.levelDB >= -6.0,
              target.levelDB <=
                AmbientCompensationConfiguration
                    .hardMaximumLevelCompensationDB,
              target.lowSupportDB >= -2.0,
              target.lowSupportDB <=
                AmbientCompensationPlanner.maximumLowSupportDB,
              target.presenceSupportDB >= -3.0,
              target.presenceSupportDB <=
                AmbientCompensationPlanner.maximumPresenceSupportDB,
              target.detailSupportDB >= -1.5,
              target.detailSupportDB <=
                AmbientCompensationPlanner.maximumDetailSupportDB,
              target.conversationEvidence.isFinite,
              target.estimatedClearanceDB.isFinite else {
            throw AmbientCompensationError.invalidConfiguration
        }

        if target.mode == .conversationFocus {
            guard target.levelDB <= 0.000_1,
                  target.lowSupportDB >= -0.000_1,
                  target.presenceSupportDB <= 0.000_1,
                  target.detailSupportDB >= -0.000_1 else {
                throw AmbientCompensationError.invalidConfiguration
            }
        }

        let available = ambientCompensationAvailableHeadroomDB
        let positiveRecovery = max(target.levelDB, 0)
        guard positiveRecovery <= available + 0.000_1 else {
            throw AmbientCompensationError
                .insufficientDigitalHeadroom(
                    requested: positiveRecovery,
                    available: available
                )
        }

        let requestsDSP = abs(target.levelDB) > 0.000_1
            || abs(target.lowSupportDB) > 0.000_1
            || abs(target.presenceSupportDB) > 0.000_1
            || abs(target.detailSupportDB) > 0.000_1
        if requestsDSP,
           !ambientCompensationStereoSpeakerRuntimeAvailable {
            throw AmbientCompensationError.runtimeUnsupported
        }

        if ambientCompensationGraphRuntimeAvailable {
            var inputs = currentLiveGraphInputs
            inputs.ambient = target
            try republishLiveGraph(inputs)
            ambientCompensationRuntimeTarget = target
            lastErrorDescription = nil
            return
        }

        guard let session = transportSession else {
            ambientCompensationRuntimeTarget = target
            lastErrorDescription = nil
            return
        }

        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: gainConfiguration,
                ambientTarget: target
            )

        var graph = try stereoEQConfiguration.makeGraphSnapshot(
            sampleRate: session.outputFormat.sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration:
                renderBassManagementConfiguration(),
            dynamicsConfiguration: dynamicsConfiguration,
            playbackConfiguration: playbackControlConfiguration,
            masterGainLinear: currentMasterSoftwareGain
        )
        try attachActiveEQFIRProgramIfNeeded(
            to: &graph,
            stereoConfiguration: stereoEQConfiguration,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveRoomCorrectionProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveSpeakerIRProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try applyAudioUnitRackLatency(to: &graph)
        try attachAmbientCompensation(target, to: &graph)
        try attachActiveQuietZone(
            candidateQuietZone,
            to: &graph
        )
        try session.publishDSPGraph(graph)
        ambientCompensationRuntimeTarget = target
        activeQuietZoneRuntimeTarget = candidateQuietZone
        lastErrorDescription = nil
    }

    func clearAmbientCompensationRuntimeTarget() throws {
        try replaceAmbientCompensationRuntimeTarget(.unity)
    }

    var activeQuietZoneStereoSpeakerRuntimeAvailable: Bool {
        transportSession != nil
            && nChannelTransportSession == nil
            && binauralHeadphoneTransportSession == nil
            && headphoneDeviceProfileConfiguration?.enabled != true
            && outputDeviceProfileConfiguration?.enabled != true
            && multiOutputRoutingConfiguration?.enabled != true
    }

    /// Largest anti-noise peak the engine will accept: the planner's headroom-based value, then the
    /// always-on live-treatment cap (`LiveTreatmentSafeguards`), which no setting disables.
    var activeQuietZoneAvailableInjectionPeak: Double {
        LiveTreatmentSafeguards.limitedInjectionPeak(
            (try? ActiveQuietZonePlanner().availableInjectionPeak(
                headroomAttenuationDB:
                    gainConfiguration.headroomAttenuationDB,
                ambientLevelRecoveryDB:
                    max(
                        ambientCompensationRuntimeTarget.levelDB,
                        0
                    ),
                configuration: ActiveQuietZoneConfiguration()
            )) ?? 0
        )
    }

    /// Output sample rate of the running stereo transport, for the live-treatment arm switch.
    var liveTreatmentSampleRate: Double? {
        transportSession?.outputFormat.sampleRate
    }

    /// E4 S15: live howl-guard trips on the current transport session (0 without one). The Quiet
    /// Zone arm compares it with the value captured at arming.
    var liveTreatmentHowlTripCount: UInt64 { transportSession?.howlGuardTripCount ?? 0 }

    /// E4 S15: clears a latched howl-guard trip; the arm calls it before arming.
    func rearmHowlGuard() { transportSession?.rearmHowlGuard() }

    /// E4 S18b: when true, an active Quiet Zone target also stamps the render snapshot with its arm
    /// token, which lets the adaptive gain mailbox play. Set by the controller from the
    /// `e4.adaptive-tonal-live` flag; false leaves the snapshot exactly as before (generation 0).
    var adaptiveTonalMailboxEnabled = false

    /// E4 S20 (`e4.earned-cap`): the earned anti-noise cap at arm, linear. 0 (the default, flag
    /// off) keeps the fixed -40 dBFS snapshot cap exactly as before. Above 0 the snapshot cap is
    /// the arm ceiling (-18 dBFS) and the kernel starts its own ceiling here and raises it at most
    /// 3 dB per 5 s. Set by the Quiet Zone controller at arm; the engine never reads the flag.
    var earnedCapInitialLinear: Float = 0
    /// E4 S21 (`e4.earned-cap`): the speaker's excursion curve for this arm. Each tone gets a
    /// kernel cap equal to the curve's lowest value across its tracking range; nil (flag off)
    /// sets no caps and the snapshot is unchanged. Set by the Quiet Zone controller at arm.
    var excursionCapCurve: ExcursionCapCurve?

    /// The token the kernel holds for the current arm: never 0 (0 means no arm in the mailbox).
    var kernelArmGeneration: UInt64 { liveTreatmentGeneration &+ 1 }

    @discardableResult
    func publishActiveQuietZoneGainRecord(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        transportSession?.publishActiveQuietZoneGainRecord(record) ?? 0
    }

    func popActiveQuietZoneTelemetry() -> N60ActiveQuietZoneTelemetryRecord? {
        transportSession?.popActiveQuietZoneTelemetry()
    }

    var activeQuietZoneMailboxStats: N60ActiveQuietZoneMailboxStats {
        transportSession?.activeQuietZoneMailboxStats ?? N60ActiveQuietZoneMailboxStats()
    }

    /// E4 S18b: the worker's link onto the current session, or nil when none is running.
    var adaptiveTonalLink: (any AdaptiveTonalLiveLink)? {
        transportSession.map { CoreAudioAdaptiveTonalLink(session: $0) }
    }

    /// Latches the same fade as a kernel howl-guard trip; the arm then disarms on the trip count.
    func requestHowlTrip() { transportSession?.requestHowlTrip() }

    /// Output gain the user's volume and the headroom attenuation apply, in dB (0 = unity),
    /// for the live-treatment arm switch. Muted reads as -120.
    var liveTreatmentOutputGainDB: Double {
        let level = masterVolumeConfiguration.muted
            ? 0 : MasterVolumeConfiguration.softwareTaperGain(forLevel: masterVolumeConfiguration.level)
        let volumeDB = level > 1.0e-6 ? 20 * log10(level) : -120
        return gainConfiguration.headroomAttenuationDB + volumeDB
    }

    private var transportTeardownObservers: [(id: UUID, handler: (TransportTeardownCause) -> Void)] = []

    /// Registers a handler fired at the end of every transport teardown (control plane, main
    /// actor; never the audio callback). Multicast, so the Quiet Zone and MIMO arm switches
    /// each keep their own. Returns an id for `removeTransportTeardownObserver`.
    @discardableResult
    func addTransportTeardownObserver(_ handler: @escaping (TransportTeardownCause) -> Void) -> UUID {
        let id = UUID()
        transportTeardownObservers.append((id, handler))
        return id
    }

    func removeTransportTeardownObserver(_ id: UUID) {
        transportTeardownObservers.removeAll { $0.id == id }
    }

    /// Arm token for live treatment targets. It advances on every transport teardown and every
    /// disarm; `replaceActiveQuietZoneRuntimeTarget` rejects an active target stamped with any
    /// other value. Control plane only.
    private(set) var liveTreatmentGeneration: UInt64 = 0

    /// Called by the arm owner on disarm: targets built under the old arm can no longer play.
    func revokeLiveTreatmentArm() {
        liveTreatmentGeneration &+= 1
    }

    func replaceActiveQuietZoneRuntimeTarget(
        _ rawTarget: ActiveQuietZoneRuntimeTarget
    ) throws {
        let target = try rawTarget.validated()
        if target.active, target.armGeneration != liveTreatmentGeneration {
            throw ActiveQuietZoneError.armRevoked
        }
        if target.active,
           !activeQuietZoneStereoSpeakerRuntimeAvailable {
            throw ActiveQuietZoneError.runtimeUnsupported
        }
        if activeQuietZoneRuntimeTarget.active,
           target.active,
           !activeQuietZoneRuntimeTarget
                .frequencies(withinFraction: 0.02, of: target) {
            throw ActiveQuietZoneError
                .frequencyChangeRequiresDisarm
        }

        let available = LiveTreatmentSafeguards.limitedInjectionPeak(
            try ActiveQuietZonePlanner()
                .availableInjectionPeak(
                    headroomAttenuationDB:
                        gainConfiguration.headroomAttenuationDB,
                    ambientLevelRecoveryDB:
                        max(
                            ambientCompensationRuntimeTarget.levelDB,
                            0
                        ),
                    configuration:
                        ActiveQuietZoneConfiguration()
                )
        )
        if target.active,
           target.maximumSourceMagnitude
                > available + 1.0e-7 {
            throw ActiveQuietZoneError
                .insufficientOutputHeadroom
        }

        guard let session = transportSession else {
            guard !target.active else {
                throw ActiveQuietZoneError.runtimeUnsupported
            }
            activeQuietZoneRuntimeTarget = target
            lastErrorDescription = nil
            return
        }

        var graph = try stereoEQConfiguration.makeGraphSnapshot(
            sampleRate: session.outputFormat.sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration:
                renderBassManagementConfiguration(),
            dynamicsConfiguration: dynamicsConfiguration,
            playbackConfiguration:
                playbackControlConfiguration,
            masterGainLinear: currentMasterSoftwareGain
        )
        try attachActiveEQFIRProgramIfNeeded(
            to: &graph,
            stereoConfiguration: stereoEQConfiguration,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveRoomCorrectionProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try attachActiveSpeakerIRProgramIfNeeded(
            to: &graph,
            playbackConfiguration: playbackControlConfiguration
        )
        try applyAudioUnitRackLatency(to: &graph)
        try attachActiveQuietZone(target, to: &graph)
        // The lease exists before any anti-noise is published.
        if target.active { syncActiveQuietZoneLease(active: true) }
        do {
            try session.publishDSPGraph(graph)
        } catch {
            if !activeQuietZoneRuntimeTarget.active { syncActiveQuietZoneLease(active: false) }
            throw error
        }
        syncActiveQuietZoneLease(active: target.active)
        activeQuietZoneRuntimeTarget = target
        lastErrorDescription = nil
    }

    func clearActiveQuietZoneRuntimeTarget(
        fadeMilliseconds: Double = 100
    ) throws {
        try replaceActiveQuietZoneRuntimeTarget(
            ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds:
                    fadeMilliseconds
            )
        )
    }

    var physicalSpeakerBusRoutingActive: Bool {
        guard let routing = multiOutputRoutingConfiguration, routing.enabled else { return false }
        return routing.enabledRoutes.contains { !$0.bus.isFullRangeBus }
    }

    var liveNChannelActive: Bool { nChannelTransportSession != nil }

    /// Test seam (E6 S9c2): puts the engine in `.running` with a hardware-free N-channel session, so the live
    /// setters, the planner and the session-kind paths run against a real bridge and graph without Core Audio.
    func installTestingNChannelSession(_ session: CoreAudioNChannelTransportSession) throws {
        precondition(lifecycle.state == .idle && nChannelTransportSession == nil, "test seam needs an idle engine")
        for state: AudioLifecycleState in [.creatingTap, .creatingAggregate, .openingOutput, .starting, .running] {
            try setLifecycle(state)
        }
        nChannelTransportSession = session
    }

    /// Test seam: stops and drops the seam session and returns the engine to idle.
    func removeTestingNChannelSession() {
        nChannelTransportSession?.stop(fadeOut: false)
        nChannelTransportSession = nil
        try? setLifecycle(.stopping)
        try? setLifecycle(.idle)
    }
    var liveBinauralHeadphoneActive: Bool { binauralHeadphoneTransportSession != nil }
    private var immutableSemanticTransportActive: Bool {
        nChannelTransportSession != nil || binauralHeadphoneTransportSession != nil
    }

    private func renderBassManagementConfiguration(
        _ source: BassManagementConfiguration? = nil
    ) -> BassManagementConfiguration {
        var render = source ?? bassManagementConfiguration
        if physicalSpeakerBusRoutingActive {
            // The physical splitter runs after shared DSP/audition. Disabling the
            // older early recombined crossover prevents double filtering.
            render.enabled = false
            render.subPhaseAlignmentEnabled = false
        }
        return render
    }

    var roomTreatmentStagedForNextStart: Bool {
        stagedRoomTreatment != nil
    }

    func stageRoomTreatmentForNextStart(
        firProgram: MIMORoomTreatmentFIRProgram,
        permit: MIMORoomTreatmentActivationPermit,
        transitionConfiguration: MIMORoomTreatmentTransitionConfiguration = .conservative
    ) throws {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        guard let profile = outputDeviceProfileConfiguration,
              profile.enabled,
              let selectedOutputUID = routeConfiguration.selectedOutputUID else {
            throw OutputDeviceProfileError.profileDisabled
        }
        let preparation = LiveMIMORoomTreatmentPreparation(
            firProgram: firProgram,
            permit: permit,
            acceptedProfile: profile,
            acceptedSelectedOutputUID: selectedOutputUID,
            transitionConfiguration: transitionConfiguration
        )
        try preparation.validate(sampleRate: firProgram.sampleRate)
        stagedRoomTreatment = preparation
    }

    func clearStagedRoomTreatment() throws {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        stagedRoomTreatment = nil
    }

    func requestRoomTreatmentArm() -> Bool {
        nChannelTransportSession?.requestRoomTreatmentArm() ?? false
    }

    func requestRoomTreatmentBypass() {
        nChannelTransportSession?.requestRoomTreatmentBypass()
    }

    func latchRoomTreatmentFault(
        _ fault: N60MIMOTreatmentFault
    ) -> Bool {
        nChannelTransportSession?.latchRoomTreatmentFault(fault) ?? false
    }

    func requestRoomTreatmentFaultClear() {
        nChannelTransportSession?.requestRoomTreatmentFaultClear()
    }

    func revokeRoomTreatmentAuthorization() {
        nChannelTransportSession?.revokeRoomTreatmentAuthorization()
    }

    var selectedOutputDevice: AudioOutputDevice? {
        guard let selectedOutputUID = routeConfiguration.selectedOutputUID else { return nil }
        return outputDevices.first { $0.uid == selectedOutputUID }
    }

    /// PR97 read-only, current-session route binding. This is not a probe
    /// transmitter, a DAC latency measurement, or an ANC arming interface.
    func hardwareClockAcquisitionRoute()
        -> QuietZoneHardwareHALClockAcquisition.Route? {
        guard let session = transportSession,
              nChannelTransportSession == nil,
              binauralHeadphoneTransportSession == nil,
              let selected = selectedOutputDevice,
              selected.uid == session.selectedOutput.uid,
              selected.deviceID == session.selectedOutput.deviceID,
              abs(selected.nominalSampleRate - session.outputFormat.sampleRate) < 0.5,
              session.passiveFeedForwardOutputTimingSnapshot() != nil
        else { return nil }
        return (
            outputID: selected.uid,
            routeID: session.calibrationTimingRouteLeaseID,
            sampleRate: session.outputFormat.sampleRate
        )
    }

    /// Records a controlled EXTERNAL source probe with the live microphone.
    /// The instrumented source emitter supplies an independent, calibrated
    /// acoustic-emission timestamp; this entry point NEVER launches playback.
    func makeInstrumentedSourceProbeAcquisition(
        microphone: AudioInputDevice,
        inputChannelIndex: Int,
        position: QuietZoneFeedForwardPosition,
        sourceFixtureID: String,
        synchronizedClockID: String,
        physicalSourceID: String
    ) throws -> QuietZoneInstrumentedProbeAcquisition {
        guard let session = transportSession,
              let route = hardwareClockAcquisitionRoute()
        else { throw QuietZoneInstrumentedProbeError.staleRoute }
        let collector = try QuietZoneInstrumentedProbeCollector(
            position: position,
            microphoneID: microphone.uid,
            microphoneChannel: inputChannelIndex,
            sourceFixtureID: sourceFixtureID,
            synchronizedClockID: synchronizedClockID,
            physicalSourceID: physicalSourceID,
            routeLeaseID: route.routeID,
            sampleRate: route.sampleRate
        )
        let reference = try FeedForwardReferenceTransport(
            microphone: microphone, inputChannelIndex: inputChannelIndex
        )
        return try QuietZoneInstrumentedProbeAcquisition(
            reference: reference,
            collector: collector,
            currentRoute: { [weak self, weak session] in
                guard let self, let session,
                      self.transportSession === session
                else { return nil }
                return self.hardwareClockAcquisitionRoute()
            }
        )
    }

    /// Creates a microphone-only timing observer bound to the *specific*
    /// active speaker-output session. Changes to the selected device, route,
    /// format or session lifetime invalidate the observer on its next poll.
    func makeHardwareClockAcquisition(
        microphone: AudioInputDevice,
        inputChannelIndex: Int
    ) throws -> QuietZoneHardwareHALClockAcquisition {
        guard let session = transportSession,
              let route = hardwareClockAcquisitionRoute()
        else { throw QuietZoneHardwareClockCaptureError.incompatibleRoute }
        let reference = try FeedForwardReferenceTransport(
            microphone: microphone,
            inputChannelIndex: inputChannelIndex
        )
        return try QuietZoneHardwareHALClockAcquisition(
            reference: reference,
            microphoneID: microphone.uid,
            outputID: route.outputID,
            routeID: route.routeID,
            sampleRate: route.sampleRate,
            currentRoute: { [weak self, weak session] in
                guard let self, let session,
                      self.transportSession === session
                else { return nil }
                return self.hardwareClockAcquisitionRoute()
            },
            outputWitness: { [weak session] in
                session?.passiveFeedForwardOutputTimingSnapshot()
            }
        )
    }

    func audioUnitRackProcessingFormatForNextStart() throws
        -> AudioUnitRackProcessingFormat {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        try refreshOutputDevices()
        guard let output = selectedOutputDevice else {
            throw AudioRouteSelectionError.outputDeviceUnavailable(
                uid: routeConfiguration.selectedOutputUID
                    ?? "No output selected"
            )
        }

        let channelCount = audioUnitRackChannelCount()

        let format = AudioUnitRackProcessingFormat(
            sampleRate: output.nominalSampleRate,
            channelCount: channelCount,
            maximumFramesPerSlice: AudioUnitRackProcessingFormat
                .recommendedMaximumFramesPerSlice(sampleRate: output.nominalSampleRate)
        )
        try format.validate()
        return format
    }

    private func audioUnitRackChannelCount() -> Int {
        if let headphone = headphoneDeviceProfileConfiguration,
           headphone.enabled,
           headphone.spatialMode == .virtualSpeakers {
            return headphone.programLayout.roles.count
        }
        if let profile = outputDeviceProfileConfiguration, profile.enabled {
            return profile.programLayout.roles.count
        }
        return 2
    }

    /// A staged rack is bound to the sample rate and channel count it was
    /// instantiated for. After a nominal-rate change or output recovery the
    /// transport would reject it and fail; instead continue dry and ask the
    /// product layer to rebuild the rack at the new format once running.
    private func detachAudioUnitRackIfIncompatible(with output: AudioOutputDevice) {
        guard let rack = stagedAudioUnitRack else { return }
        let compatible = abs(rack.format.sampleRate - output.nominalSampleRate) < 0.5
            && rack.format.channelCount == audioUnitRackChannelCount()
        guard !compatible else { return }
        stagedAudioUnitRack = nil
        audioUnitRackRebuildPending = true
    }

    private func requestAudioUnitRackRebuildIfPending() {
        guard audioUnitRackRebuildPending, lifecycle.state == .running else { return }
        audioUnitRackRebuildPending = false
        onAudioUnitRackRequiresRebuild?()
    }

    /// Reinstalls a rack rebuilt for the current output format after
    /// `onAudioUnitRackRequiresRebuild`. Uses the controlled-restart path.
    func restoreAudioUnitRackAfterFormatChange(
        _ runtime: AudioUnitLiveRackRuntime
    ) throws {
        guard lifecycle.state == .running, stagedAudioUnitRack == nil else { return }
        try controlledRestartForAudioUnitRackMutation(runtime)
    }

    func stageAudioUnitRackForNextStart(
        _ runtime: AudioUnitLiveRackRuntime?
    ) throws {
        guard lifecycle.state == .idle else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        if let runtime {
            stagedAudioUnitRack = try AudioUnitLiveRackSwitchboard(
                format: runtime.format,
                initialRuntime: runtime
            )
        } else {
            stagedAudioUnitRack = nil
        }
    }

    func clearStagedAudioUnitRack() {
        guard lifecycle.state == .idle else { return }
        stagedAudioUnitRack = nil
    }

    func audioUnitRackProcessingFormatForMutation() throws
        -> AudioUnitRackProcessingFormat {
        switch lifecycle.state {
        case .idle:
            if let stagedAudioUnitRack {
                return stagedAudioUnitRack.format
            }
            return try audioUnitRackProcessingFormatForNextStart()
        case .running:
            if let stagedAudioUnitRack {
                return stagedAudioUnitRack.format
            }
            guard let output = selectedOutputDevice else {
                throw AudioRouteSelectionError.outputDeviceUnavailable(
                    uid: routeConfiguration.selectedOutputUID
                        ?? "No output selected"
                )
            }
            let channelCount = audioUnitRackChannelCount()
            let format = AudioUnitRackProcessingFormat(
                sampleRate: output.nominalSampleRate,
                channelCount: channelCount,
                maximumFramesPerSlice: AudioUnitRackProcessingFormat
                    .recommendedMaximumFramesPerSlice(sampleRate: output.nominalSampleRate)
            )
            try format.validate()
            return format
        default:
            throw AudioUnitRackMutationError
                .liveMutationRequiresRunningOrIdle(lifecycle.state)
        }
    }

    func activateAudioUnitRackMutation(
        _ candidate: AudioUnitRackMutationCandidate,
        crossfadeFrames: Int =
            AudioUnitLiveRackSwitchboard.defaultCrossfadeFrames
    ) async throws -> AudioUnitRackMutationActivation {
        switch lifecycle.state {
        case .idle:
            try stageAudioUnitRackForNextStart(candidate.runtime)
            return .stagedForNextStart

        case .running:
            if candidate.runtime == nil,
               stagedAudioUnitRack == nil {
                return .noAudioChange
            }

            if let switchboard = stagedAudioUnitRack,
               switchboard.format == candidate.format,
               switchboard.latencyFrames
                    == candidate.totalLatencyFrames {
                try await switchboard.transition(
                    to: candidate.runtime,
                    crossfadeFrames: crossfadeFrames
                )
                return .seamlessCrossfade(
                    generation:
                        switchboard.status.renderedGeneration
                )
            }

            try controlledRestartForAudioUnitRackMutation(
                candidate.runtime
            )
            return .controlledRestart

        default:
            throw AudioUnitRackMutationError
                .liveMutationRequiresRunningOrIdle(lifecycle.state)
        }
    }

    private func controlledRestartForAudioUnitRackMutation(
        _ runtime: AudioUnitLiveRackRuntime?
    ) throws {
        guard lifecycle.state == .running else {
            throw AudioUnitRackMutationError
                .liveMutationRequiresRunningOrIdle(lifecycle.state)
        }

        let previousSwitchboard = stagedAudioUnitRack
        let replacementSwitchboard: AudioUnitLiveRackSwitchboard?
        if let runtime {
            replacementSwitchboard =
                try AudioUnitLiveRackSwitchboard(
                    format: runtime.format,
                    initialRuntime: runtime
                )
        } else {
            replacementSwitchboard = nil
        }

        stop()
        stagedAudioUnitRack = replacementSwitchboard

        do {
            try start(resetProcessingSessionCounters: false)
        } catch {
            let activationError = error
            if lifecycle.state == .failed {
                if AudioLifecycleStateMachine.canTransition(
                    from: lifecycle.state,
                    to: .stopping
                ) {
                    try? setLifecycle(.stopping)
                }
                tearDownTransport(fadeOut: false)
                if AudioLifecycleStateMachine.canTransition(
                    from: lifecycle.state,
                    to: .idle
                ) {
                    try? setLifecycle(.idle)
                }
            }

            stagedAudioUnitRack = previousSwitchboard
            do {
                try start(resetProcessingSessionCounters: false)
            } catch {
                throw AudioUnitRackMutationError.rollbackFailed(
                    error.localizedDescription
                )
            }
            throw activationError
        }
    }

    func prepareForUse() {
        guard !prepared else { return }
        prepared = true
        do {
            try refreshOutputDevices()
            try eventMonitor.start()
            try syncMasterVolumeMonitorToSelectedOutput()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    @discardableResult
    func refreshOutputDevices() throws -> [AudioOutputDevice] {
        do {
            let discoveredDevices = try deviceCatalog.outputDevices()
            outputDevices = discoveredDevices
            return discoveredDevices
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func selectOutput(uid: String?) throws {
        guard lifecycle.state == .idle else { return }
        guard let uid else {
            routeConfiguration.selectedOutputUID = nil
            masterVolumeSynchronizedOutputUID = nil
            masterVolumeController.stopMonitoring()
            globalVolumeKeyMonitor.stop()
            globalVolumeKeyMonitoringState = .stopped
            masterVolumeCapabilities = .softwareOnly
            return
        }
        guard outputDevices.contains(where: { $0.uid == uid }) else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: uid)
            lastErrorDescription = error.localizedDescription
            throw error
        }
        routeConfiguration.selectedOutputUID = uid
        try syncMasterVolumeMonitorToSelectedOutput()
        lastErrorDescription = nil
    }

    func addEQBand(_ band: EQBand = EQBand()) throws {
        guard stereoEQConfiguration.editableBands.count < EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(stereoEQConfiguration.editableBands.count + 1)
        }
        var updated = stereoEQConfiguration
        var bands = updated.editableBands
        bands.append(band)
        updated.replaceEditableBands(bands)
        try applyStereoEQConfiguration(updated)
    }

    func updateEQBand(_ band: EQBand) throws {
        var updated = stereoEQConfiguration
        guard updated.editableBands.contains(where: { $0.id == band.id }) else { return }
        updated.updateEditableBand(band)
        try applyStereoEQConfiguration(updated)
    }

    func removeEQBand(id: UUID) throws {
        var updated = stereoEQConfiguration
        updated.removeEditableBand(id: id)
        try applyStereoEQConfiguration(updated)
    }

    func setEQBypassed(_ bypassed: Bool) throws {
        var updated = stereoEQConfiguration
        updated.bypassed = bypassed
        try applyStereoEQConfiguration(updated)
    }

    func setEQPhaseMode(_ mode: EQPhaseMode) throws {
        guard mode != stereoEQConfiguration.phaseMode else { return }
        var updated = stereoEQConfiguration
        updated.phaseMode = mode
        try applyStereoEQConfiguration(updated)
    }

    func setEQChannelMode(_ mode: EQChannelMode) throws {
        var updated = stereoEQConfiguration
        updated.setChannelMode(mode)
        try applyStereoEQConfiguration(updated)
    }

    func setEQEditChannel(_ channel: EQEditChannel) {
        var updated = stereoEQConfiguration
        updated.setEditChannel(channel)
        stereoEQConfiguration = updated
        eqConfiguration = legacyEQConfiguration(from: updated)
        lastErrorDescription = nil
    }

    func replaceStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {
        try applyStereoEQConfiguration(configuration)
    }

    func replaceEQConfiguration(_ configuration: EQConfiguration) throws {
        var updated = stereoEQConfiguration
        updated.phaseMode = configuration.phaseMode
        updated.bypassed = configuration.bypassed
        updated.replaceEditableBands(configuration.bands)
        try applyStereoEQConfiguration(updated)
    }

    func replacePlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {
        try applyPlaybackControlConfiguration(configuration)
    }

    func setCrosstalkCancellationEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkCancellationAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkCancellationAmountRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkCancellationAmount(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkCancellationAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setCrosstalkHeadShadowFrequency(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.crosstalkHeadShadowFrequencyRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(value)
        }
        var updated = playbackControlConfiguration
        updated.crosstalkHeadShadowFrequencyHz = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setSpeakerCrossfeedEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSpeakerCrossfeedAmount(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.speakerCrossfeedRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(value)
        }
        var updated = playbackControlConfiguration
        updated.speakerCrossfeedAmount = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setSymmetryBalanceEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.symmetryBalanceEnabled = enabled
        try applyPlaybackControlConfiguration(updated)
    }

    func setSymmetryBalancePosition(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.symmetryBalanceRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidSymmetryBalance(value)
        }
        var updated = playbackControlConfiguration
        updated.symmetryBalancePosition = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setChannelBalance(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.balanceRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidBalance(value)
        }
        var updated = playbackControlConfiguration
        updated.balance = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setInterChannelDelayMs(_ value: Double) throws {
        guard value.isFinite, PlaybackControlConfiguration.interChannelDelayRange.contains(value) else {
            throw PlaybackControlConfigurationError.invalidInterChannelDelay(value)
        }
        var updated = playbackControlConfiguration
        updated.interChannelDelayMs = value
        try applyPlaybackControlConfiguration(updated)
    }

    func setGlobalDSPBypassed(_ bypassed: Bool) throws {
        var updated = playbackControlConfiguration
        updated.globalBypassed = bypassed
        try applyPlaybackControlConfiguration(updated)
    }

    func setFlatAuditionEnabled(_ enabled: Bool) throws {
        var updated = playbackControlConfiguration
        updated.auditionMode = enabled ? .reference : .processed
        try applyPlaybackControlConfiguration(updated)
    }

    func setAuditionMode(_ mode: AuditionMode) throws {
        var updated = playbackControlConfiguration
        updated.auditionMode = mode
        try applyPlaybackControlConfiguration(updated)
    }

    func setSoftwareVolumeKeyStep(_ step: MasterVolumeKeyStep) {
        guard step.isValid else { return }
        softwareVolumeKeyStep = step
    }

    func setMasterVolumeLevel(_ level: Double) throws {
        guard level.isFinite, MasterVolumeConfiguration.levelRange.contains(level) else {
            throw MasterVolumeConfigurationError.invalidLevel(level)
        }
        var updated = masterVolumeConfiguration
        updated.level = level
        try applyMasterVolumeConfiguration(updated, writeDevice: true)
    }

    func setMasterMuted(_ muted: Bool) throws {
        var updated = masterVolumeConfiguration
        updated.muted = muted
        try applyMasterVolumeConfiguration(updated, writeDevice: true)
    }

    func replaceGainConfiguration(_ configuration: DSPGainConfiguration) throws {
        try applyGainConfiguration(configuration)
    }

    /// Applies the PR113B A/B-safe content domain as one complete graph
    /// transition. Playback-System state, output routing, room/speaker
    /// correction, master/output gain and Audio Unit topology remain owned by
    /// their existing domains and are only reattached to the candidate graph.
    ///
    /// The extra attenuation is intentionally non-positive and exists only for
    /// measured A/B level matching. It is not written back into the captured
    /// snapshot.
    func transitionContentAuditionState(
        _ state: ContentABAuditionState,
        additionalInputAttenuationDB: Double = 0
    ) throws {
        guard additionalInputAttenuationDB.isFinite,
              (-24.0...0.0).contains(additionalInputAttenuationDB) else {
            throw DSPGainConfigurationError.invalidInputPreamp(
                state.inputPreampDB + additionalInputAttenuationDB
            )
        }

        try validateStereoEQStorage(state.stereoEQ)

        var targetGain = gainConfiguration
        targetGain.inputPreampDB = min(
            max(
                state.inputPreampDB + additionalInputAttenuationDB,
                DSPGainConfiguration.inputPreampRange.lowerBound
            ),
            DSPGainConfiguration.inputPreampRange.upperBound
        )
        targetGain.headroomAttenuationDB = state.headroomAttenuationDB

        guard DSPGainConfiguration.inputPreampRange
                .contains(targetGain.inputPreampDB) else {
            throw DSPGainConfigurationError.invalidInputPreamp(
                targetGain.inputPreampDB
            )
        }
        guard DSPGainConfiguration.headroomAttenuationRange
                .contains(targetGain.headroomAttenuationDB) else {
            throw DSPGainConfigurationError.invalidHeadroomAttenuation(
                targetGain.headroomAttenuationDB
            )
        }

        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: targetGain
            )
        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: targetGain,
                ambientTarget: clampedAmbientTarget
            )

        if immutableSemanticTransportActive {
            if state.stereoEQ != stereoEQConfiguration
                || state.dynamics != dynamicsConfiguration
                || targetGain != gainConfiguration
                || clampedAmbientTarget != ambientCompensationRuntimeTarget {
                try requireLiveGraphEdits()
                var inputs = currentLiveGraphInputs
                inputs.stereoEQ = state.stereoEQ
                inputs.dynamics = state.dynamics
                inputs.gain = targetGain
                inputs.ambient = clampedAmbientTarget
                try republishLiveGraph(inputs)
            }
        } else if let session = transportSession {
            var graph = try state.stereoEQ.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: targetGain,
                bassManagementConfiguration:
                    renderBassManagementConfiguration(),
                dynamicsConfiguration: state.dynamics,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )

            var preparedEQFIRProgram: PreparedEQFIRProgram?
            if !processingIsBypassed(playbackControlConfiguration),
               state.stereoEQ.requiresEQFIRProgram,
               !state.stereoEQ.bypassed {
                let prepared =
                    try prepareEQFIRProgram(state.stereoEQ, for: session)
                try attachEQFIRProgram(prepared, to: &graph)
                preparedEQFIRProgram = prepared
            }

            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try attachAmbientCompensation(
                clampedAmbientTarget,
                to: &graph
            )
            try attachActiveQuietZone(
                candidateQuietZone,
                to: &graph
            )

            // Always use the sample-domain structural transition for A/B.
            // Even when only biquad/gain values differ this avoids an
            // instantaneous coefficient/gain discontinuity at the output.
            try session.transitionDSPGraph(graph)
            activeEQFIRProgram = preparedEQFIRProgram
            linearPhaseDesignInfo = preparedEQFIRProgram?.designInfo
        } else {
            // Validate the complete target graph while idle even though there
            // is no transport to publish it to yet.
            let validationRate =
                selectedOutputDevice?.nominalSampleRate ?? 48_000
            _ = try state.stereoEQ.makeGraphSnapshot(
                sampleRate: validationRate,
                gainConfiguration: targetGain,
                bassManagementConfiguration:
                    renderBassManagementConfiguration(),
                dynamicsConfiguration: state.dynamics,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            activeEQFIRProgram = nil
            linearPhaseDesignInfo = nil
        }

        stereoEQConfiguration = state.stereoEQ
        eqConfiguration = legacyEQConfiguration(from: state.stereoEQ)
        dynamicsConfiguration = state.dynamics
        gainConfiguration = targetGain
        ambientCompensationRuntimeTarget = clampedAmbientTarget
        activeQuietZoneRuntimeTarget = candidateQuietZone
        lastErrorDescription = nil
    }

    func setInputPreampDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.inputPreampRange.contains(value) else {
            throw DSPGainConfigurationError.invalidInputPreamp(value)
        }
        var updated = gainConfiguration
        updated.inputPreampDB = value
        try applyGainConfiguration(updated)
    }

    /// Applies a Headroom Assistant recommendation through the same
    /// sample-domain silent-boundary transition used for other click-sensitive
    /// structural graph changes. This changes only the existing headroom gain;
    /// it does not save/overwrite the selected Content Preset.
    func transitionHeadroomAttenuationDB(_ value: Double) throws {
        guard value.isFinite,
              DSPGainConfiguration.headroomAttenuationRange
                .contains(value) else {
            throw DSPGainConfigurationError
                .invalidHeadroomAttenuation(value)
        }

        var updated = gainConfiguration
        updated.headroomAttenuationDB = value

        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: updated
            )
        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: updated,
                ambientTarget: clampedAmbientTarget
            )

        if immutableSemanticTransportActive {
            if updated != gainConfiguration || clampedAmbientTarget != ambientCompensationRuntimeTarget {
                try requireLiveGraphEdits()
                var inputs = currentLiveGraphInputs
                inputs.gain = updated
                inputs.ambient = clampedAmbientTarget
                try republishLiveGraph(inputs)
            }
        } else if let session = transportSession {
            var graph = try stereoEQConfiguration
                .makeGraphSnapshot(
                    sampleRate:
                        session.outputFormat.sampleRate,
                    gainConfiguration: updated,
                    bassManagementConfiguration:
                        renderBassManagementConfiguration(),
                    dynamicsConfiguration:
                        dynamicsConfiguration,
                    playbackConfiguration:
                        playbackControlConfiguration,
                    masterGainLinear:
                        currentMasterSoftwareGain
                )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration:
                    stereoEQConfiguration,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration:
                    playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try attachAmbientCompensation(
                clampedAmbientTarget,
                to: &graph
            )
            try attachActiveQuietZone(
                candidateQuietZone,
                to: &graph
            )
            try session.transitionDSPGraph(graph)
        }

        gainConfiguration = updated
        ambientCompensationRuntimeTarget =
            clampedAmbientTarget
        activeQuietZoneRuntimeTarget =
            candidateQuietZone
        lastErrorDescription = nil
    }

    func setHeadroomAttenuationDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.headroomAttenuationRange.contains(value) else {
            throw DSPGainConfigurationError.invalidHeadroomAttenuation(value)
        }
        var updated = gainConfiguration
        updated.headroomAttenuationDB = value
        try applyGainConfiguration(updated)
    }

    func setOutputGainDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.outputGainRange.contains(value) else {
            throw DSPGainConfigurationError.invalidOutputGain(value)
        }
        var updated = gainConfiguration
        updated.outputGainDB = value
        try applyGainConfiguration(updated)
    }

    func replaceMultiOutputRoutingConfiguration(
        _ configuration: MultiOutputRoutingConfiguration?
    ) throws {
        if let configuration {
            try configuration.validateStructure()
        }
        if configuration?.enabled == true, outputDeviceProfileConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if configuration?.enabled == true, headphoneDeviceProfileConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
        }
        guard lifecycle.state == .idle || configuration == multiOutputRoutingConfiguration else {
            throw MultiOutputRoutingError.routingChangeRequiresIdle
        }
        multiOutputRoutingConfiguration = configuration
        lastErrorDescription = nil
    }

    func replaceOutputDeviceProfileConfiguration(
        _ configuration: OutputDeviceProfileConfiguration?
    ) throws {
        if configuration?.enabled == true {
            try configuration?.validateStructure(
                bassManagementEnabled: bassManagementConfiguration.enabled
            )
            if multiOutputRoutingConfiguration?.enabled == true {
                throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
            }
            if headphoneDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
        }
        guard lifecycle.state == .idle || configuration == outputDeviceProfileConfiguration else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        outputDeviceProfileConfiguration = configuration
        lastErrorDescription = nil
    }

    func replaceHeadphoneDeviceProfileConfiguration(
        _ configuration: HeadphoneDeviceProfileConfiguration?
    ) throws {
        if let configuration, configuration.enabled {
            if outputDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
            if multiOutputRoutingConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
            if !speakerDriverProcessingConfiguration.isNeutral {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("per-driver speaker processing")
            }
            if bassManagementConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker bass management")
            }
            if roomCorrectionConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker room correction")
            }
            if speakerIRConfiguration.enabled {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("Speaker IR")
            }
            if let output = selectedOutputDevice {
                try configuration.validateStructure(sampleRate: output.nominalSampleRate)
            }
        }
        if lifecycle.state != .idle {
            let context = HeadphoneLiveEditPlanner.Context(
                unifiedGraphEnabled: unifiedGraphEnabled,
                lifecycleRunning: lifecycle.state == .running,
                binauralSession: binauralHeadphoneTransportSession.map { $0.unifiedGraphActive ? .graph : .legacy } ?? .none,
                nChannelSessionActive: nChannelTransportSession != nil,
                stereoHeadphoneGraphActive: transportSession?.headphoneGraphActive == true)
            switch HeadphoneLiveEditPlanner.plan(from: headphoneDeviceProfileConfiguration, to: configuration, context: context) {
            case .unchanged: break
            case .refuse: throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
            case .liveEdit(let assetChanged):
                guard let configuration else { throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart }
                if transportSession?.headphoneGraphActive == true {
                    try applyLiveStereoHeadphoneEdit(configuration)
                } else {
                    try applyLiveHeadphoneEdit(configuration, assetChanged: assetChanged)
                }
                return
            case .reconfigure:
                try validateHeadphoneSessionKindChange(configuration)
                headphoneDeviceProfileConfiguration = configuration
                lastErrorDescription = nil
                scheduleSampleRateReconfiguration(countsAsSampleRateChange: false, fadeOut: true, settleDelay: 0.03)
                return
            }
        }
        headphoneDeviceProfileConfiguration = configuration
        if configuration?.enabled == true,
           configuration?.spatialMode == .virtualSpeakers,
           configuration?.headTracking?.enabled == true {
            headTrackingRuntimeStatus = .configuredStopped
        } else {
            headTrackingRuntimeStatus = .disabled
        }
        lastErrorDescription = nil
    }

    /// E6 S9c: everything a session-kind change would need at the rebuild, checked before the change is committed so
    /// a refusal leaves the running session and the stored configuration alone.
    private func validateHeadphoneSessionKindChange(_ configuration: HeadphoneDeviceProfileConfiguration?) throws {
        guard let configuration, configuration.enabled else { return }
        guard let output = selectedOutputDevice else {
            throw HeadphoneDeviceProfileError.outputDeviceRequired
        }
        let selected = try configuration.validateForActivation(
            availableDevices: outputDevices, selectedOutputUID: output.uid, sampleRate: output.nominalSampleRate)
        if configuration.spatialMode == .stereo {
            guard multiOutputRoutingConfiguration?.enabled != true else {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
        }
        if configuration.spatialMode == .virtualSpeakers {
            let source = try configuration.resolveProgramSource(availableDevices: outputDevices, selectedOutput: selected)
            guard source.supports(sampleRate: output.nominalSampleRate) else {
                throw BinauralHeadphoneTransportError.sampleRateMismatch(
                    source: source.nominalSampleRate, output: output.nominalSampleRate)
            }
            try validateBinauralHeadphoneActivation()
        }
    }

    /// E6 S9d: a headphone profile edit inside one graph-rendered stereo session. The session rebuilds the HEADPHONE
    /// and ear delay stages and republishes; stored state changes only after the graph accepted it.
    private func applyLiveStereoHeadphoneEdit(_ configuration: HeadphoneDeviceProfileConfiguration) throws {
        guard let session = transportSession else {
            throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
        }
        try configuration.validateStructure(sampleRate: session.outputFormat.sampleRate)
        try session.applyLiveHeadphoneProfile(configuration)
        headphoneDeviceProfileConfiguration = configuration
        lastErrorDescription = nil
    }

    /// E6 S9c: a headphone profile edit inside one graph-rendered binaural session. The channel correction (headroom,
    /// gain, polarity, EQ, delay) is laid onto the retained base spec and republished as a posted parameter or a
    /// faded rebuild; stored state changes only after the graph accepted it. A new HRTF asset is prepared off the main
    /// actor and published when ready, the old one rendering meanwhile.
    private func applyLiveHeadphoneEdit(
        _ configuration: HeadphoneDeviceProfileConfiguration, assetChanged: Bool
    ) throws {
        guard let session = binauralHeadphoneTransportSession, let base = session.unifiedGraphBaseSpec else {
            throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
        }
        try configuration.validateStructure(sampleRate: session.outputFormat.sampleRate)
        switch UnifiedGraphTranslator.binauralApplyHeadphone(base: base, profile: configuration) {
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        case .success(let newBase): try republishLiveGraph(currentLiveGraphInputs, headphoneBase: newBase)
        }
        headphoneDeviceProfileConfiguration = configuration
        lastErrorDescription = nil
        if assetChanged { beginHeadphoneAssetSwap(session: session, profile: configuration) }
    }

    private func beginHeadphoneAssetSwap(
        session: CoreAudioBinauralHeadphoneTransportSession, profile: HeadphoneDeviceProfileConfiguration
    ) {
        headphoneAssetGeneration &+= 1
        let generation = headphoneAssetGeneration
        guard let reference = profile.binauralProfile else { return }
        let rate = session.outputFormat.sampleRate
        let store = binauralProfileAssetStore
        let cache = binauralAssetCache
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<UnifiedGraphSpec, Error>
            do {
                let asset = try cache.asset(for: reference, sampleRate: rate, store: store)
                switch UnifiedGraphTranslator.binauralBaseSpec(
                    asset: asset, layout: profile.programLayout, profile: profile, outputChannels: 2,
                    sampleRate: rate, headTracking: profile.headTracking?.enabled == true
                ) {
                case .success(let base): result = .success(base)
                case .failure(let reason): result = .failure(LiveNChannelTransportError.unifiedGraphRejected(reason))
                }
            } catch {
                result = .failure(error)
            }
            await self?.finishHeadphoneAssetSwap(
                generation: generation, reference: reference, session: session, result: result)
        }
    }

    private func finishHeadphoneAssetSwap(
        generation: UInt64,
        reference: BinauralProfileReference,
        session: CoreAudioBinauralHeadphoneTransportSession,
        result: Result<UnifiedGraphSpec, Error>
    ) {
        guard generation == headphoneAssetGeneration,
              binauralHeadphoneTransportSession === session,
              lifecycle.state == .running,
              let profile = headphoneDeviceProfileConfiguration,
              profile.binauralProfile == reference else { return }
        do {
            // Edits made while the asset prepared are already in the configuration: lay them onto the new set.
            let prepared = try result.get()
            let newBase: UnifiedGraphSpec
            switch UnifiedGraphTranslator.binauralApplyHeadphone(base: prepared, profile: profile) {
            case .success(let base): newBase = base
            case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
            }
            try republishLiveGraph(currentLiveGraphInputs, headphoneBase: newBase)
            renderedBinauralProfile = reference
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            if var restored = headphoneDeviceProfileConfiguration, let rendered = renderedBinauralProfile {
                restored.binauralProfile = rendered
                headphoneDeviceProfileConfiguration = restored
            }
        }
    }

    func recenterHeadTracking() {
        headTrackingController?.recenter()
    }

    func importNormalizedBinauralProfile(from url: URL) throws -> BinauralProfileReference {
        let reference = try binauralProfileAssetStore.importNormalizedDocument(from: url)
        lastErrorDescription = nil
        return reference
    }

    func replaceSpeakerDriverProcessingConfiguration(
        _ configuration: SpeakerDriverProcessingConfiguration
    ) throws {
        try configuration.validateStructure()
        guard lifecycle.state == .idle || configuration == speakerDriverProcessingConfiguration else {
            throw SpeakerDriverProcessingError.changesRequireIdle
        }
        speakerDriverProcessingConfiguration = configuration
        lastErrorDescription = nil
    }

    func replaceBassManagementConfiguration(_ configuration: BassManagementConfiguration) throws {
        guard configuration.frequencyHz.isFinite,
              configuration.lowerFrequencyRange.contains(configuration.frequencyHz) else {
            throw BassManagementConfigurationError.invalidFrequency(configuration.frequencyHz)
        }
        guard configuration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(configuration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(configuration.subGainDB)
        }
        guard configuration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(configuration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                configuration.subPhaseAlignmentFrequencyHz
            )
        }
        guard configuration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(configuration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(configuration.subPhaseAlignmentQ)
        }
        if configuration.physicalOutputMode == .triAmp {
            let upper = configuration.upperFrequencyHz ?? .nan
            guard upper.isFinite, BassManagementConfiguration.speakerFrequencyRange.contains(upper),
                  upper > configuration.frequencyHz else {
                throw BassManagementConfigurationError.invalidUpperFrequency(upper)
            }
        }
        if let outputDeviceProfile = outputDeviceProfileConfiguration, outputDeviceProfile.enabled {
            try outputDeviceProfile.validateStructure(bassManagementEnabled: configuration.enabled)
        }
        if immutableSemanticTransportActive, configuration != bassManagementConfiguration {
            // The crossover topology is fixed when the session starts, so toggling bass management restarts.
            // Retuning an enabled N-channel crossover republishes the graph. A graph-rendered binaural
            // session has no bass stage in the graph, so with `enabled` unchanged its bass edits are live
            // state commits. A legacy binaural session still needs a restart for any change.
            let binauralGraphLive = binauralHeadphoneTransportSession?.unifiedGraphActive == true
            if (binauralHeadphoneTransportSession != nil && !binauralGraphLive)
                || configuration.enabled != bassManagementConfiguration.enabled {
                throw LiveNChannelTransportError.configurationChangeRequiresRestart
            }
        }
        if physicalSpeakerBusRoutingActive, lifecycle.state != .idle, configuration != bassManagementConfiguration {
            throw BassManagementConfigurationError.physicalCrossoverChangeRequiresIdle
        }
        if immutableSemanticTransportActive, configuration != bassManagementConfiguration,
           binauralHeadphoneTransportSession == nil {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.bass = configuration
            try republishLiveGraph(inputs)
        }
        if let session = transportSession {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(configuration),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        bassManagementConfiguration = configuration
        lastErrorDescription = nil
    }

    @discardableResult
    func applyDetectedMainsHum(minimumConfidence: Float = 0.55) throws -> Bool {
        guard let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectedFrequencyHz.isFinite,
              diagnostics.mainsDetectionConfidence >= minimumConfidence,
              MainsNotchConfiguration.detectedFrequencyRange.contains(Double(diagnostics.mainsDetectedFrequencyHz)) else {
            return false
        }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = Double(diagnostics.mainsDetectedFrequencyHz)
        try replaceDynamicsConfiguration(updated)
        return true
    }

    func detectMainsHumOnce(minimumConfidence: Float = 0.55) async throws -> Bool {
        guard lifecycle.state == .running else { return false }
        let trackingWasEnabled = dynamicsConfiguration.mainsNotch.continuousTracking
        if !trackingWasEnabled {
            var detecting = dynamicsConfiguration
            detecting.mainsNotch.continuousTracking = true
            try replaceDynamicsConfiguration(detecting)
        }
        defer {
            if !trackingWasEnabled {
                var restored = dynamicsConfiguration
                restored.mainsNotch.continuousTracking = false
                try? replaceDynamicsConfiguration(restored)
            }
        }
        try await Task.sleep(nanoseconds: 1_150_000_000)
        return try applyDetectedMainsHum(minimumConfidence: minimumConfidence)
    }

    func pollMainsHumTracking(minimumConfidence: Float = 0.70) {
        guard dynamicsConfiguration.mainsNotch.continuousTracking,
              let diagnostics = diagnosticsSnapshot().renderKernelDiagnostics,
              diagnostics.mainsDetectionConfidence >= minimumConfidence else { return }
        let detected = Double(diagnostics.mainsDetectedFrequencyHz)
        guard detected.isFinite,
              MainsNotchConfiguration.detectedFrequencyRange.contains(detected),
              abs(detected - dynamicsConfiguration.mainsNotch.fundamentalHz) >= 0.03 else { return }
        var updated = dynamicsConfiguration
        updated.mainsNotch.detectedFundamentalHz = detected
        try? replaceDynamicsConfiguration(updated)
    }

    func applySpectralDenoiserPreset(_ preset: SpectralDenoiserPreset) throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.applyPreset(preset)
        try replaceDynamicsConfiguration(updated)
    }

    func captureSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.requestProfileCapture()
        try replaceDynamicsConfiguration(updated)
    }

    func resetSpectralNoiseProfile() throws {
        var updated = dynamicsConfiguration
        updated.spectralDenoiser.resetProfile()
        try replaceDynamicsConfiguration(updated)
    }

    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {
        let validationRate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.outputFormat.sampleRate
            ?? 48_000
        _ = try configuration.makeSnapshot(sampleRate: validationRate)
        let newProtection = try configuration.makeProtectionSnapshot(sampleRate: validationRate)
        if immutableSemanticTransportActive, configuration != dynamicsConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.dynamics = configuration
            try republishLiveGraph(inputs)
        }
        if let session = transportSession {
            let oldProtection = try dynamicsConfiguration.makeProtectionSnapshot(sampleRate: session.outputFormat.sampleRate)
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: configuration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            let protectionStructureChanged = oldProtection.latencyFrames != newProtection.latencyFrames
                || oldProtection.effectiveFactor != newProtection.effectiveFactor
                || oldProtection.limiterEnabled != newProtection.limiterEnabled
                || dynamicsConfiguration.softClipper.enabled != configuration.softClipper.enabled
            let denoiserStructureChanged = dynamicsConfiguration.spectralDenoiser.enabled != configuration.spectralDenoiser.enabled
                || (configuration.spectralDenoiser.enabled
                    && dynamicsConfiguration.spectralDenoiser.quality != configuration.spectralDenoiser.quality)
            if protectionStructureChanged || denoiserStructureChanged {
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
            } else {
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
            }
        }
        dynamicsConfiguration = configuration
        lastErrorDescription = nil
    }

    func loadRoomCorrectionValidationFilter() throws {
        var updated = roomCorrectionConfiguration
        updated.filter = .validation
        try applyRoomCorrectionConfiguration(updated)
    }

    func setRoomCorrectionEnabled(_ enabled: Bool) throws {
        var updated = roomCorrectionConfiguration
        updated.enabled = enabled
        try applyRoomCorrectionConfiguration(updated)
    }

    func replaceRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        try applyRoomCorrectionConfiguration(configuration)
    }

    func loadSpeakerIRValidationFilter() throws {
        var updated = speakerIRConfiguration
        updated.filter = .validation
        try applySpeakerIRConfiguration(updated)
    }

    func setSpeakerIREnabled(_ enabled: Bool) throws {
        var updated = speakerIRConfiguration
        updated.enabled = enabled
        try applySpeakerIRConfiguration(updated)
    }

    func clearSpeakerIRFilter() throws {
        var updated = speakerIRConfiguration
        updated.enabled = false
        updated.filter = nil
        try applySpeakerIRConfiguration(updated)
    }

    func replaceSpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        try applySpeakerIRConfiguration(configuration)
    }

    func start() throws {
        try start(resetProcessingSessionCounters: true)
    }

    func stop() {
        guard lifecycle.state != .idle else { return }
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        reconfigurationWorkItem = nil
        recoveryWorkItem = nil
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
        tearDownTransport(fadeOut: true, cause: .stop)
        try? setLifecycle(.idle)
        clearStagedAudioUnitRack()
        audioUnitRackRebuildPending = false
        if lowLatencyRestorePending { restoreLowLatencyBuffers() }
    }

    func shutdownForTermination() {
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .idle {
            if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
            tearDownTransport(fadeOut: true, cause: .quit)
            try? setLifecycle(.idle)
        }
        if lifecycle.state == .idle {
            clearStagedAudioUnitRack()
            if lowLatencyOutputProfileActive || lowLatencyRestorePending {
                restoreLowLatencyBuffers()
            }
        }
        masterVolumeController.stopMonitoring()
        globalVolumeKeyMonitor.stop()
        globalVolumeKeyMonitoringState = .stopped
        eventMonitor.stop()
    }

    func setDetailedMeteringDemand(_ enabled: Bool) throws {
        if let session = nChannelTransportSession {
            session.setDetailedMeteringDemand(enabled)
            return
        }
        if let session = binauralHeadphoneTransportSession {
            session.setDetailedMeteringDemand(enabled)
            return
        }
        let previousDemand = N60RealtimeAudioBridgeMeteringDemand()
        guard previousDemand != enabled else { return }

        N60RealtimeAudioBridgeSetMeteringDemand(enabled)
    }

    func setAnalysisDemand(_ demandMask: UInt32) {
        transportSession?.setAnalysisDemand(demandMask)
    }

    func analysisCaptureSnapshot() -> N60AnalysisCaptureSnapshot? {
        transportSession?.analysisCaptureSnapshot()
    }

    var ambientPlaybackReferenceAvailable: Bool {
        transportSession != nil
            && nChannelTransportSession == nil
            && binauralHeadphoneTransportSession == nil
    }

    var ambientPlaybackReferenceSampleRate: Double? {
        guard ambientPlaybackReferenceAvailable else { return nil }
        return transportSession?.ambientReferenceSampleRate
    }

    func setAmbientPlaybackReferenceDemand(_ enabled: Bool) {
        guard ambientPlaybackReferenceAvailable else {
            transportSession?.setAmbientReferenceDemand(false)
            return
        }
        transportSession?.setAmbientReferenceDemand(enabled)
    }

    func ambientPlaybackReferenceSnapshot()
        -> N60AmbientPlaybackReferenceSnapshot? {
        guard ambientPlaybackReferenceAvailable else { return nil }
        return transportSession?.ambientReferenceSnapshot()
    }

    func discardAmbientPlaybackReferenceFrames() {
        transportSession?.discardAmbientReferenceFrames()
    }

    func readAmbientPlaybackReferenceFrames(
        maximumFrames: Int =
            Int(N60_AMBIENT_REFERENCE_CAPACITY_FRAMES)
    ) -> [N60AmbientPlaybackReferenceFrame] {
        guard ambientPlaybackReferenceAvailable else { return [] }
        return transportSession?.readAmbientReferenceFrames(
            maximumFrames: maximumFrames
        ) ?? []
    }

    /// E4 S22b1: records what is written to the speakers for the feed-forward echo model.
    /// Set from `e4.feedforward-live`; while false nothing ever sets the demand.
    var speakerDriveFeatureEnabled = false

    func setSpeakerDriveDemand(_ requested: Bool) {
        let allowed = SpeakerDriveDemandPolicy.demand(
            requested: requested,
            featureEnabled: speakerDriveFeatureEnabled,
            transportAvailable: ambientPlaybackReferenceAvailable
        )
        transportSession?.setSpeakerDriveDemand(allowed)
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot? {
        transportSession?.speakerDriveSnapshot()
    }

    func readSpeakerDriveAnchors() -> [N60SpeakerDriveAnchor] {
        transportSession?.readSpeakerDriveAnchors() ?? []
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        transportSession?.readSpeakerDriveFrames(maximumFrames: maximumFrames) ?? []
    }

    var activeQuietZoneReferenceAvailable: Bool {
        activeQuietZoneStereoSpeakerRuntimeAvailable
    }

    var activeQuietZoneReferenceSampleRate: Double? {
        guard activeQuietZoneReferenceAvailable else {
            return nil
        }
        return transportSession?
            .activeQuietZoneReferenceSampleRate
    }

    func setActiveQuietZoneReferenceDemand(_ enabled: Bool) {
        guard activeQuietZoneReferenceAvailable else {
            transportSession?
                .setActiveQuietZoneReferenceDemand(false)
            return
        }
        transportSession?
            .setActiveQuietZoneReferenceDemand(enabled)
    }

    func activeQuietZoneReferenceSnapshot()
        -> N60ActiveQuietZoneReferenceSnapshot? {
        guard activeQuietZoneReferenceAvailable else {
            return nil
        }
        return transportSession?
            .activeQuietZoneReferenceSnapshot()
    }

    func discardActiveQuietZoneReferenceFrames() {
        transportSession?
            .discardActiveQuietZoneReferenceFrames()
    }

    func readActiveQuietZoneReferenceFrames(
        maximumFrames: Int =
            Int(
                N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES
            )
    ) -> [N60ActiveQuietZoneReferenceFrame] {
        guard activeQuietZoneReferenceAvailable else {
            return []
        }
        return transportSession?
            .readActiveQuietZoneReferenceFrames(
                maximumFrames: maximumFrames
            )
            ?? []
    }

    func productionAnalysisSnapshot() -> ProductionAnalysisSnapshot {
        transportSession?.productionAnalysisSnapshot() ?? .empty
    }

    func resetSpectrumPeakHold() {
        transportSession?.resetSpectrumPeakHold()
    }

    func productionTransportMeterSnapshot() -> ProductionTransportMeterSnapshot? {
        if let session = nChannelTransportSession, var raw = session.bridgeSnapshot() {
            var meter = raw.meter
            let roles = session.routePlan.programLayout.roles
            let programChannels: [ProductionTransportChannelMeter] = roles.enumerated().map { index, role in
                let channel = UInt32(index)
                return ProductionTransportChannelMeter(
                    id: "program-\(role.rawValue)",
                    label: role.displayName,
                    channelIndex: channel,
                    peakLinear: N60LiveNChannelMeterProgramPeak(&meter, channel),
                    rmsLinear: N60LiveNChannelMeterProgramRMS(&meter, channel),
                    overRangeSamples: N60LiveNChannelMeterProgramOverRangeSamples(&meter, channel)
                )
            }

            var mapped: [(UInt32, String, String)] = []
            for (index, role) in roles.enumerated() {
                let physical = session.routePlan.programPhysicalChannels[index]
                guard physical != UInt32.max else { continue }
                mapped.append((physical, role.displayName, "physical-\(role.rawValue)"))
            }
            for sub in 0..<Int(session.routePlan.subwooferCount) {
                let physical = session.routePlan.subwooferPhysicalChannels[sub]
                guard physical != UInt32.max else { continue }
                mapped.append((physical, "Sub \(sub + 1)", "physical-sub-\(sub)"))
            }
            mapped.sort { $0.0 < $1.0 }
            let physicalOutputs = mapped.map { physical, label, id in
                ProductionTransportChannelMeter(
                    id: id,
                    label: label,
                    channelIndex: physical,
                    peakLinear: N60LiveNChannelMeterPhysicalPeak(&meter, physical),
                    rmsLinear: N60LiveNChannelMeterPhysicalRMS(&meter, physical),
                    overRangeSamples: N60LiveNChannelMeterPhysicalOverRangeSamples(&meter, physical)
                )
            }
            return ProductionTransportMeterSnapshot(
                kind: .semanticSpeakers,
                displayName: outputDeviceProfileConfiguration?.systemDisplayName
                    ?? session.routePlan.programLayout.displayName,
                programLayoutName: session.routePlan.programLayout.displayName,
                sampleRate: session.outputFormat.sampleRate,
                latencyFrames: raw.algorithmicLatencyFrames
                    + raw.adaptiveTransportLatencyFrames
                    + raw.roomTreatmentLatencyFrames,
                meteringEnabled: raw.meter.enabled,
                programChannels: programChannels,
                physicalOutputs: physicalOutputs,
                inputTruePeakLinear: nil,
                outputTruePeakLinear: nil,
                roomTreatment: raw.roomTreatmentConfigured
                    ? ProductionRoomTreatmentDiagnostics(
                        authorized: raw.roomTreatment.transition.authorized,
                        armRequested: raw.roomTreatment.transition.armRequested,
                        active: raw.roomTreatment.transition.state
                            == N60MIMOTreatmentStateActive,
                        transitioning:
                            raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateArming
                            || raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateDisarming
                            || raw.roomTreatment.transition.state
                                == N60MIMOTreatmentStateFaultFading,
                        faulted: raw.roomTreatment.transition.fault
                            != N60MIMOTreatmentFaultNone,
                        treatmentMix: raw.roomTreatment.transition.treatmentMix,
                        treatmentSourceCount: raw.roomTreatment.treatmentChannelCount,
                        latencyFrames: raw.roomTreatment.totalLatencyFrames,
                        processedFrames: raw.roomTreatment.processedFrames,
                        protectionClampSamples:
                            raw.roomTreatment.protectionClampSamples,
                        integrationFailures:
                            raw.roomTreatment.integrationFailures
                    )
                    : nil,
                renderFailures: raw.renderFailures,
                outputWriteFailures: raw.outputWriteFailures
            )
        }

        if let session = binauralHeadphoneTransportSession, let raw = session.bridgeSnapshot() {
            let meter = raw.meter
            let outputs = [
                ProductionTransportChannelMeter(
                    id: "headphone-left", label: "Left", channelIndex: 0,
                    peakLinear: meter.peakLeft, rmsLinear: meter.rmsLeft,
                    overRangeSamples: meter.overRangeLeft
                ),
                ProductionTransportChannelMeter(
                    id: "headphone-right", label: "Right", channelIndex: 1,
                    peakLinear: meter.peakRight, rmsLinear: meter.rmsRight,
                    overRangeSamples: meter.overRangeRight
                ),
            ]
            return ProductionTransportMeterSnapshot(
                kind: .virtualSpeakers,
                displayName: "Virtual \(session.programLayout.displayName) → Headphones",
                programLayoutName: session.programLayout.displayName,
                sampleRate: session.outputFormat.sampleRate,
                latencyFrames: raw.algorithmicLatencyFrames,
                meteringEnabled: meter.enabled,
                programChannels: [],
                physicalOutputs: outputs,
                inputTruePeakLinear: raw.protection.inputTruePeakLinear,
                outputTruePeakLinear: raw.protection.outputTruePeakLinear,
                roomTreatment: nil,
                renderFailures: raw.renderFailures,
                outputWriteFailures: raw.outputWriteFailures
            )
        }
        return nil
    }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let selectedDevice = selectedOutputDevice
        let currentCounters = transportSession?.counters()
            ?? nChannelTransportSession?.counters()
            ?? binauralHeadphoneTransportSession?.counters()
            ?? AudioTransportCounters()
        let processingSessionCounters = processingSessionArchivedCounters + currentCounters
        let lifetimeCounters = lifetimeArchivedCounters + currentCounters
        let activeTapSampleRate = transportSession?.tapFormat.sampleRate
            ?? nChannelTransportSession?.tapFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.tapFormat.sampleRate
        let activeOutputSampleRate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? binauralHeadphoneTransportSession?.outputFormat.sampleRate
        let startupGateOpened = transportSession?.startupGateOpened
            ?? nChannelTransportSession?.startupGateOpened
            ?? binauralHeadphoneTransportSession?.startupGateOpened
        let startupGateTargetFrames = transportSession?.startupGateTargetFrames
            ?? nChannelTransportSession?.startupGateTargetFrames
            ?? binauralHeadphoneTransportSession?.startupGateTargetFrames
        let startupGateActivationFrames = transportSession?.startupGateActivationFrames
            ?? nChannelTransportSession?.startupGateActivationFrames
            ?? binauralHeadphoneTransportSession?.startupGateActivationFrames
        let stereoRenderDiagnostics = transportSession?.renderDiagnostics()
        // The stereo overlay already read FINAL_METER into outputMeter unless the bridge VU supplied it.
        let stereoFinalReading: StereoMeterReading? =
            (transportSession?.unifiedGraphReadback != nil && !N60RealtimeAudioBridgeOutputVUMeterDemand())
            ? stereoRenderDiagnostics?.outputMeter : nil
        // S8c: the stereo overlay also took this snapshot's gain-reduction and true-peak readings.
        let stereoDynamicsReading: UnifiedGraphDynamicsReading? = stereoRenderDiagnostics.flatMap { diagnostics in
            transportSession?.unifiedGraphReadback == nil ? nil : UnifiedGraphDynamicsReading(
                compressorGainReductionDB: diagnostics.compressorGainReductionDB,
                limiterGainReductionDB: diagnostics.limiterGainReductionDB,
                inputTruePeakLinear: diagnostics.inputTruePeakLinear,
                outputTruePeakLinear: diagnostics.outputTruePeakLinear,
                truePeakGuardActive: diagnostics.truePeakGuardActive)
        }
        return AudioDiagnosticsSnapshot(
            lifecycleState: lifecycle.state,
            selectedOutputUID: routeConfiguration.selectedOutputUID,
            selectedOutputName: selectedDevice?.name,
            selectedOutputPresent: selectedDevice != nil,
            selectedOutputNominalSampleRate: selectedDevice?.nominalSampleRate,
            discoveredOutputCount: outputDevices.count,
            tapSampleRate: activeTapSampleRate,
            outputSampleRate: activeOutputSampleRate,
            sessionTransportCounters: processingSessionCounters,
            lifetimeTransportCounters: lifetimeCounters,
            renderKernelDiagnostics: stereoRenderDiagnostics,
            startupGateOpened: startupGateOpened,
            startupGateTargetFrames: startupGateTargetFrames,
            startupGateActivationFrames: startupGateActivationFrames,
            sampleRateChangesHandled: sampleRateChangesHandled,
            recoveryAttempts: recoveryAttempts,
            recoverySuccesses: recoverySuccesses,
            recoveryFailures: recoveryFailures,
            lastErrorDescription: lastErrorDescription,
            unifiedGraph: UnifiedGraphDiagnostics(
                host: transportSession?.unifiedGraphReadback
                    ?? nChannelTransportSession?.unifiedGraphReadback
                    ?? binauralHeadphoneTransportSession?.unifiedGraphReadback,
                programChannelCount: nChannelTransportSession.map {
                    $0.routePlan.programLayout.roles.count
                } ?? binauralHeadphoneTransportSession.map {
                    $0.programLayout.roles.count
                } ?? 2,
                fallbackReason: unifiedGraphEnabled
                    ? (transportSession?.unifiedGraphFallbackReason
                        ?? nChannelTransportSession?.unifiedGraphFallbackReason
                        ?? binauralHeadphoneTransportSession?.unifiedGraphFallbackReason)
                    : nil,
                stereoFinalReading: stereoFinalReading,
                stereoDynamicsReading: stereoDynamicsReading
            )
        )
    }

    private func legacyEQConfiguration(from configuration: StereoEQConfiguration) -> EQConfiguration {
        EQConfiguration(
            phaseMode: configuration.phaseMode,
            bypassed: configuration.bypassed,
            bands: configuration.editableBands
        )
    }

    private func processingIsBypassed(_ configuration: PlaybackControlConfiguration) -> Bool {
        FIRUpdatePolicy.isRawBypassed(configuration)
    }

    private func validateStereoEQStorage(_ configuration: StereoEQConfiguration) throws {
        for bands in [configuration.linkedBands, configuration.leftBands, configuration.rightBands, configuration.midBands, configuration.sideBands] {
            guard bands.count <= EQConfiguration.maximumBandCount else {
                throw EQConfigurationError.tooManyBands(bands.count)
            }
            for (index, band) in bands.enumerated() where band.enabled {
                if band.type == .fir {
                    guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
                    try kernel.validateMetadata()
                    if let activeSampleRate = transportSession?.outputFormat.sampleRate {
                        try kernel.validate(for: activeSampleRate)
                    }
                    continue
                }
                guard band.frequencyHz.isFinite,
                      band.frequencyHz > 0,
                      band.gainDB.isFinite,
                      StereoEQConfiguration.bandGainRange.contains(band.gainDB),
                      band.q.isFinite,
                      band.q > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
                if band.type == .linkwitzTransform {
                    guard band.linkwitzTargetHz.isFinite,
                          band.linkwitzTargetHz > 0,
                          band.linkwitzTargetQ.isFinite,
                          band.linkwitzTargetQ > 0 else {
                        throw EQConfigurationError.invalidBand(index: index)
                    }
                }
                if band.dynamic.enabled {
                    guard band.type == .peaking,
                          DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),
                          DynamicEQBandConfiguration.qRange.contains(band.q),
                          band.dynamic.isValid else {
                        throw EQConfigurationError.invalidBand(index: index)
                    }
                }
            }
        }
    }

    private func applyStereoEQConfiguration(_ configuration: StereoEQConfiguration) throws {
        try validateStereoEQStorage(configuration)
        if immutableSemanticTransportActive, configuration != stereoEQConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.stereoEQ = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try configuration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )

            if processingIsBypassed(playbackControlConfiguration) {
                // The raw path is already active. Update state without rotating FIR
                // programs or fading an audibly identical raw graph.
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                activeEQFIRProgram = nil
                linearPhaseDesignInfo = nil
            } else {
                var preparedEQFIRProgram: PreparedEQFIRProgram?
                if configuration.requiresEQFIRProgram && !configuration.bypassed {
                    let prepared = try prepareEQFIRProgram(configuration, for: session)
                    preparedEQFIRProgram = prepared
                    linearPhaseDesignInfo = prepared.designInfo
                    try attachEQFIRProgram(prepared, to: &graph)
                } else {
                    linearPhaseDesignInfo = nil
                }

                try attachActiveRoomCorrectionProgramIfNeeded(
                    to: &graph,
                    playbackConfiguration: playbackControlConfiguration
                )

                let leavingEQFIR = activeEQFIRProgram != nil
                    && (!configuration.requiresEQFIRProgram || configuration.bypassed)
                let enteringOrReplacingEQFIR = preparedEQFIRProgram != nil
                if leavingEQFIR || enteringOrReplacingEQFIR {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                activeEQFIRProgram = preparedEQFIRProgram
            }
        } else {
            activeEQFIRProgram = nil
            linearPhaseDesignInfo = nil
        }

        stereoEQConfiguration = configuration
        eqConfiguration = legacyEQConfiguration(from: configuration)
        lastErrorDescription = nil
    }

    private func applyPlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {
        guard configuration.balance.isFinite,
              PlaybackControlConfiguration.balanceRange.contains(configuration.balance) else {
            throw PlaybackControlConfigurationError.invalidBalance(configuration.balance)
        }
        guard configuration.interChannelDelayMs.isFinite,
              PlaybackControlConfiguration.interChannelDelayRange.contains(configuration.interChannelDelayMs) else {
            throw PlaybackControlConfigurationError.invalidInterChannelDelay(configuration.interChannelDelayMs)
        }
        if immutableSemanticTransportActive, configuration != playbackControlConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.playback = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: configuration,
                masterGainLinear: currentMasterSoftwareGain
            )

            let wasBypassed = processingIsBypassed(playbackControlConfiguration)
            let willBeBypassed = processingIsBypassed(configuration)

            if !willBeBypassed {
                if FIRUpdatePolicy.shouldPrepareEQFIR(
                    stereoEQ: stereoEQConfiguration,
                    playback: configuration
                ) {
                    if activeEQFIRProgram == nil {
                        let prepared = try prepareEQFIRProgram(stereoEQConfiguration, for: session)
                        activeEQFIRProgram = prepared
                        linearPhaseDesignInfo = prepared.designInfo
                    }
                    try attachActiveEQFIRProgramIfNeeded(
                        to: &graph,
                        stereoConfiguration: stereoEQConfiguration,
                        playbackConfiguration: configuration
                    )
                }

                if roomCorrectionConfiguration.enabled {
                    guard let filter = roomCorrectionConfiguration.filter else {
                        throw RoomCorrectionConfigurationError.filterRequired
                    }
                    if activeRoomCorrectionProgram == nil {
                        activeRoomCorrectionProgram = try prepareRoomCorrectionProgram(filter, for: session)
                    }
                    try attachActiveRoomCorrectionProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }

                if speakerIRConfiguration.enabled {
                    guard let filter = speakerIRConfiguration.filter else {
                        throw SpeakerIRConfigurationError.filterRequired
                    }
                    if activeSpeakerIRProgram == nil {
                        activeSpeakerIRProgram = try prepareSpeakerIRProgram(filter, for: session)
                    }
                    try attachActiveSpeakerIRProgramIfNeeded(
                        to: &graph,
                        playbackConfiguration: configuration
                    )
                }
            }

            let auditionModeChanged = playbackControlConfiguration.auditionMode != configuration.auditionMode
            if wasBypassed != willBeBypassed || auditionModeChanged {
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
            } else {
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
            }
        }

        playbackControlConfiguration = configuration
        lastErrorDescription = nil
    }

    private var currentMasterSoftwareGain: Float {
        masterVolumeConfiguration.softwareGain(for: masterVolumeCapabilities)
    }

    private func applyMasterVolumeConfiguration(
        _ configuration: MasterVolumeConfiguration,
        writeDevice: Bool
    ) throws {
        guard configuration.level.isFinite,
              MasterVolumeConfiguration.levelRange.contains(configuration.level) else {
            throw MasterVolumeConfigurationError.invalidLevel(configuration.level)
        }

        if writeDevice, let output = selectedOutputDevice {
            if masterVolumeCapabilities.controlMode == .device {
                try masterVolumeController.setVolume(configuration.level, deviceID: output.deviceID)
            }
            if masterVolumeCapabilities.usesDeviceMute {
                try masterVolumeController.setMuted(configuration.muted, deviceID: output.deviceID)
            }
        }

        let oldSoftwareGain = currentMasterSoftwareGain
        let newSoftwareGain = configuration.softwareGain(for: masterVolumeCapabilities)
        if let session = transportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: newSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(to: &graph, stereoConfiguration: stereoEQConfiguration, playbackConfiguration: playbackControlConfiguration)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try attachActiveSpeakerIRProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        if let session = nChannelTransportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            session.setOutputGain(newSoftwareGain)
        }
        if let session = binauralHeadphoneTransportSession, abs(oldSoftwareGain - newSoftwareGain) > 0.000_001 {
            session.setOutputGain(newSoftwareGain)
        }

        masterVolumeConfiguration = configuration
        persistSoftwareMasterVolumeIfNeeded()
        lastErrorDescription = nil
    }

    private func persistSoftwareMasterVolumeIfNeeded() {
        guard masterVolumeCapabilities.controlMode == .softwareDSP,
              let uid = selectedOutputDevice?.uid,
              uid == masterVolumeSynchronizedOutputUID else { return }
        masterVolumeStore?.storeSoftwareVolume(masterVolumeConfiguration, forOutputUID: uid)
    }

    private func syncMasterVolumeMonitorToSelectedOutput() throws {
        guard let output = selectedOutputDevice else {
            masterVolumeController.stopMonitoring()
            globalVolumeKeyMonitor.stop()
            globalVolumeKeyMonitoringState = .stopped
            masterVolumeCapabilities = .softwareOnly
            return
        }
        try masterVolumeController.monitor(deviceID: output.deviceID)
        try synchronizeMasterVolumeFromSelectedDevice()
        syncGlobalVolumeKeyMonitor()
    }

    private func synchronizeMasterVolumeFromSelectedDevice() throws {
        guard let output = selectedOutputDevice else { return }
        let previousCapabilities = masterVolumeCapabilities
        let snapshot = try masterVolumeController.inspect(deviceID: output.deviceID)
        masterVolumeCapabilities = snapshot.capabilities

        var updated = masterVolumeConfiguration
        let firstSyncForOutput = masterVolumeSynchronizedOutputUID != output.uid
        if snapshot.capabilities.controlMode == .device, let level = snapshot.level {
            updated.level = min(max(level, 0), 1)
        } else if snapshot.capabilities.controlMode == .softwareDSP,
                  firstSyncForOutput,
                  let restored = masterVolumeStore?.restoredSoftwareVolume(forOutputUID: output.uid) {
            updated.level = min(max(restored.level, 0), 1)
            if !snapshot.capabilities.usesDeviceMute {
                updated.muted = restored.muted
            }
        }
        if snapshot.capabilities.usesDeviceMute, let muted = snapshot.muted {
            updated.muted = muted
        }
        masterVolumeSynchronizedOutputUID = output.uid

        let oldGain = masterVolumeConfiguration.softwareGain(for: previousCapabilities)
        let newGain = updated.softwareGain(for: snapshot.capabilities)
        if let session = transportSession, abs(oldGain - newGain) > 0.000_001 {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: newGain
            )
            try attachActiveEQFIRProgramIfNeeded(to: &graph, stereoConfiguration: stereoEQConfiguration, playbackConfiguration: playbackControlConfiguration)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try attachActiveSpeakerIRProgramIfNeeded(to: &graph, playbackConfiguration: playbackControlConfiguration)
            try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
        }
        if let session = nChannelTransportSession, abs(oldGain - newGain) > 0.000_001 {
            session.setOutputGain(newGain)
        }
        if let session = binauralHeadphoneTransportSession, abs(oldGain - newGain) > 0.000_001 {
            session.setOutputGain(newGain)
        }
        masterVolumeConfiguration = updated
    }

    private func handleMasterVolumeDeviceChange() {
        do {
            try synchronizeMasterVolumeFromSelectedDevice()
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func syncGlobalVolumeKeyMonitor() {
        globalVolumeKeyMonitor.stop()
        globalVolumeKeyMonitoringState = .stopped
        guard masterVolumeCapabilities.controlMode == .softwareDSP else { return }
        do {
            try globalVolumeKeyMonitor.start()
            globalVolumeKeyMonitoringState = globalVolumeKeyMonitor.state
        } catch {
            globalVolumeKeyMonitoringState = globalVolumeKeyMonitor.state
            // Input Monitoring is a keyboard-control capability, not an audio-route
            // requirement. Keep the selected output usable and surface permission
            // state independently instead of failing refresh/recovery.
        }
    }

    private func handleGlobalVolumeKey(direction: Double) {
        guard masterVolumeCapabilities.controlMode == .softwareDSP,
              direction == 1.0 || direction == -1.0 else { return }
        let level = softwareVolumeKeyStep.level(
            afterPress: direction,
            from: masterVolumeConfiguration.level
        )
        guard abs(level - masterVolumeConfiguration.level) > 0.000_001 else { return }
        var updated = masterVolumeConfiguration
        updated.level = level
        do {
            try applyMasterVolumeConfiguration(updated, writeDevice: false)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func applyGainConfiguration(_ configuration: DSPGainConfiguration) throws {
        let clampedAmbientTarget =
            ambientTargetClampedToHeadroom(
                ambientCompensationRuntimeTarget,
                gainConfiguration: configuration
            )

        let candidateQuietZone =
            activeQuietZoneTargetAfterHeadroomChange(
                activeQuietZoneRuntimeTarget,
                gainConfiguration: configuration,
                ambientTarget: clampedAmbientTarget
            )

        if immutableSemanticTransportActive,
           configuration != gainConfiguration || clampedAmbientTarget != ambientCompensationRuntimeTarget {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.gain = configuration
            inputs.ambient = clampedAmbientTarget
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: configuration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )
            try applyAudioUnitRackLatency(to: &graph)
            try attachAmbientCompensation(
                clampedAmbientTarget,
                to: &graph
            )
            try attachActiveQuietZone(
                candidateQuietZone,
                to: &graph
            )
            try session.publishDSPGraph(graph)
        }

        gainConfiguration = configuration
        ambientCompensationRuntimeTarget =
            clampedAmbientTarget
        activeQuietZoneRuntimeTarget =
            candidateQuietZone
        lastErrorDescription = nil
    }

    private func applyRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        if configuration.enabled && configuration.filter == nil {
            throw RoomCorrectionConfigurationError.filterRequired
        }
        if immutableSemanticTransportActive, configuration != roomCorrectionConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.room = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveSpeakerIRProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
                if let filter = configuration.filter {
                    try validateRoomCorrectionFilter(
                        filter,
                        outputSampleRate: session.outputFormat.sampleRate
                    )
                }
                // Stay on the untreated path without rotating a stale FIR slot or
                // invoking a fade-through-silence transition.
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                activeRoomCorrectionProgram = nil
            } else if configuration.enabled {
                guard let filter = configuration.filter else {
                    throw RoomCorrectionConfigurationError.filterRequired
                }
                let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
                try attachRoomCorrectionProgram(preparedProgram, to: &graph)
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                activeRoomCorrectionProgram = preparedProgram
            } else {
                if activeRoomCorrectionProgram != nil {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                activeRoomCorrectionProgram = nil
            }
        } else {
            activeRoomCorrectionProgram = nil
        }

        roomCorrectionConfiguration = configuration
        lastErrorDescription = nil
    }

    private func applySpeakerIRConfiguration(_ configuration: SpeakerIRConfiguration) throws {
        if configuration.enabled && configuration.filter == nil {
            throw SpeakerIRConfigurationError.filterRequired
        }
        if immutableSemanticTransportActive, configuration != speakerIRConfiguration {
            try requireLiveGraphEdits()
            var inputs = currentLiveGraphInputs
            inputs.speakerIR = configuration
            try republishLiveGraph(inputs)
        }

        if let session = transportSession {
            var graph = try stereoEQConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: renderBassManagementConfiguration(),
                dynamicsConfiguration: dynamicsConfiguration,
                playbackConfiguration: playbackControlConfiguration,
                masterGainLinear: currentMasterSoftwareGain
            )
            try attachActiveEQFIRProgramIfNeeded(
                to: &graph,
                stereoConfiguration: stereoEQConfiguration,
                playbackConfiguration: playbackControlConfiguration
            )
            try attachActiveRoomCorrectionProgramIfNeeded(
                to: &graph,
                playbackConfiguration: playbackControlConfiguration
            )

            if processingIsBypassed(playbackControlConfiguration) {
                if let filter = configuration.filter {
                    try validateSpeakerIRFilter(
                        filter,
                        outputSampleRate: session.outputFormat.sampleRate
                    )
                }
                try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                activeSpeakerIRProgram = nil
            } else if configuration.enabled {
                guard let filter = configuration.filter else {
                    throw SpeakerIRConfigurationError.filterRequired
                }
                let preparedProgram = try prepareSpeakerIRProgram(filter, for: session)
                try attachSpeakerIRProgram(preparedProgram, to: &graph)
                try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                activeSpeakerIRProgram = preparedProgram
            } else {
                if activeSpeakerIRProgram != nil {
                    try applyAudioUnitRackLatency(to: &graph)
                try session.transitionDSPGraph(graph)
                } else {
                    try applyAudioUnitRackLatency(to: &graph)
            try session.publishDSPGraph(graph)
                }
                activeSpeakerIRProgram = nil
            }
        } else {
            activeSpeakerIRProgram = nil
        }

        speakerIRConfiguration = configuration
        lastErrorDescription = nil
    }

    private func designLinearPhaseTaps(
        _ configuration: StereoEQConfiguration,
        channel: EQEditChannel,
        sampleRate: Double,
        tapCount: Int
    ) throws -> (taps: [Float], info: N60LinearPhaseEQDesignInfo) {
        let bands = try configuration.linearPhaseBands(for: channel, sampleRate: sampleRate)
        var taps = [Float](repeating: 0, count: tapCount)
        var designInfo = N60LinearPhaseEQDesignInfo()
        let designed = taps.withUnsafeMutableBufferPointer { tapBuffer -> Bool in
            if bands.isEmpty {
                return N60LinearPhaseEQDesign(
                    sampleRate,
                    nil,
                    0,
                    tapBuffer.baseAddress!,
                    UInt32(tapBuffer.count),
                    &designInfo
                )
            }
            return bands.withUnsafeBufferPointer { bandBuffer in
                N60LinearPhaseEQDesign(
                    sampleRate,
                    bandBuffer.baseAddress!,
                    UInt32(bandBuffer.count),
                    tapBuffer.baseAddress!,
                    UInt32(tapBuffer.count),
                    &designInfo
                )
            }
        }
        guard designed else { throw EQConfigurationError.linearPhaseDesignFailed }
        return (taps, designInfo)
    }

    private func prepareLaneEQFIRTaps(
        _ configuration: StereoEQConfiguration,
        channel: EQEditChannel,
        sampleRate: Double
    ) throws -> (taps: [Float], declaredLatencyFrames: UInt32, designInfo: N60LinearPhaseEQDesignInfo?) {
        let baseTaps: [Float]
        let declaredLatency: UInt32
        let designInfo: N60LinearPhaseEQDesignInfo?
        if configuration.phaseMode == .linearPhase {
            let tapCount = Int(N60LinearPhaseEQRecommendedTapCount(sampleRate))
            guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let design = try designLinearPhaseTaps(
                configuration,
                channel: channel,
                sampleRate: sampleRate,
                tapCount: tapCount
            )
            baseTaps = design.taps
            declaredLatency = design.info.groupDelayFrames
            designInfo = design.info
        } else {
            baseTaps = [1.0]
            declaredLatency = 0
            designInfo = nil
        }

        let kernels = try configuration.firKernels(for: channel, sampleRate: sampleRate)
        return (
            try EQFIRCompiler.cascade(base: baseTaps, kernels: kernels),
            declaredLatency,
            designInfo
        )
    }

    /// The EQ FIR taps for the configured channel mode (left and optional second channel padded to one length), their
    /// declared latency and the linear-phase design report. Pure: prepares nothing.
    private func eqFIRTaps(
        _ configuration: StereoEQConfiguration,
        sampleRate: Double
    ) throws -> (left: [Float], right: [Float]?, declaredLatencyFrames: UInt32, designInfo: N60LinearPhaseEQDesignInfo?) {
        let primaryChannel: EQEditChannel
        switch configuration.channelMode {
        case .linked: primaryChannel = .linked
        case .independent: primaryChannel = .left
        case .midSide: primaryChannel = .mid
        }
        var primary = try prepareLaneEQFIRTaps(
            configuration,
            channel: primaryChannel,
            sampleRate: sampleRate
        )

        var secondaryTaps: [Float]?
        if configuration.channelMode != .linked {
            let secondaryChannel: EQEditChannel = configuration.channelMode == .midSide ? .side : .right
            var secondary = try prepareLaneEQFIRTaps(
                configuration,
                channel: secondaryChannel,
                sampleRate: sampleRate
            )
            guard secondary.declaredLatencyFrames == primary.declaredLatencyFrames else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let commonCount = max(primary.taps.count, secondary.taps.count)
            if primary.taps.count < commonCount {
                primary.taps.append(contentsOf: repeatElement(0, count: commonCount - primary.taps.count))
            }
            if secondary.taps.count < commonCount {
                secondary.taps.append(contentsOf: repeatElement(0, count: commonCount - secondary.taps.count))
            }
            secondaryTaps = secondary.taps
        }
        return (primary.taps, secondaryTaps, primary.declaredLatencyFrames, primary.designInfo)
    }

    private func prepareEQFIRProgram(
        _ configuration: StereoEQConfiguration,
        for session: CoreAudioTransportSession
    ) throws -> PreparedEQFIRProgram {
        let primary = try eqFIRTaps(configuration, sampleRate: session.outputFormat.sampleRate)
        let secondaryTaps = primary.right

        let slot = nextEQFIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareConvolutionProgram(
                slot: slot,
                leftTaps: primary.left,
                rightTaps: secondaryTaps,
                declaredLatencyFrames: primary.declaredLatencyFrames
            )
        } catch {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        nextEQFIRProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedEQFIRProgram(
            slot: slot,
            programInfo: programInfo,
            designInfo: primary.designInfo
        )
    }

    private func rateAdaptedRoomCorrectionFilter(
        _ filter: RoomCorrectionFilter,
        sampleRate: Double
    ) -> RoomCorrectionFilter {
        guard let designRate = filter.sampleRate,
              abs(designRate - sampleRate) >= 0.5 else { return filter }
        if let cached = adaptedRoomCorrectionFilter,
           abs(cached.sampleRate - sampleRate) < 0.5,
           cached.source == filter {
            return cached.filter
        }
        guard let adapted = roomCorrectionFilterAdapter?(filter, sampleRate),
              let adaptedRate = adapted.sampleRate,
              abs(adaptedRate - sampleRate) < 0.5 else {
            return filter
        }
        adaptedRoomCorrectionFilter = (filter, sampleRate, adapted)
        return adapted
    }

    private func validateRoomCorrectionFilter(
        _ deployedFilter: RoomCorrectionFilter,
        outputSampleRate: Double
    ) throws {
        let filter = rateAdaptedRoomCorrectionFilter(deployedFilter, sampleRate: outputSampleRate)
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw RoomCorrectionConfigurationError.invalidTapCount(tapCount)
        }
        if let rightTaps = filter.rightTaps, rightTaps.count != tapCount {
            throw RoomCorrectionConfigurationError.mismatchedStereoTapCount(left: tapCount, right: rightTaps.count)
        }
        guard filter.leftTaps.allSatisfy(\.isFinite),
              filter.rightTaps?.allSatisfy(\.isFinite) ?? true else {
            throw RoomCorrectionConfigurationError.nonFiniteTap
        }
        try filter.validateSampleRate(forOutputSampleRate: outputSampleRate)
        guard filter.declaredLatencyFrames < UInt32(tapCount) else {
            throw RoomCorrectionConfigurationError.invalidDeclaredLatency(filter.declaredLatencyFrames)
        }
    }

    private func prepareRoomCorrectionProgram(
        _ deployedFilter: RoomCorrectionFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedRoomCorrectionProgram {
        try validateRoomCorrectionFilter(deployedFilter, outputSampleRate: session.outputFormat.sampleRate)
        let filter = rateAdaptedRoomCorrectionFilter(
            deployedFilter,
            sampleRate: session.outputFormat.sampleRate
        )

        let slot = nextRoomCorrectionProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareRoomCorrectionProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        nextRoomCorrectionProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedRoomCorrectionProgram(slot: slot, programInfo: programInfo)
    }

    private func validateSpeakerIRFilter(
        _ filter: SpeakerIRFilter,
        outputSampleRate: Double
    ) throws {
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw SpeakerIRConfigurationError.invalidTapCount(tapCount)
        }
        if let rightTaps = filter.rightTaps, rightTaps.count != tapCount {
            throw SpeakerIRConfigurationError.mismatchedStereoTapCount(left: tapCount, right: rightTaps.count)
        }
        guard filter.leftTaps.allSatisfy(\.isFinite),
              filter.rightTaps?.allSatisfy(\.isFinite) ?? true else {
            throw SpeakerIRConfigurationError.nonFiniteTap
        }
        try filter.validateSampleRate(forOutputSampleRate: outputSampleRate)
        guard filter.declaredLatencyFrames < UInt32(tapCount) else {
            throw SpeakerIRConfigurationError.invalidDeclaredLatency(filter.declaredLatencyFrames)
        }
    }

    private func prepareSpeakerIRProgram(
        _ filter: SpeakerIRFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedSpeakerIRProgram {
        try validateSpeakerIRFilter(filter, outputSampleRate: session.outputFormat.sampleRate)

        let slot = nextSpeakerIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareSpeakerIRProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        nextSpeakerIRProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedSpeakerIRProgram(slot: slot, programInfo: programInfo)
    }

    /// E6 S9a: the stereo-class DSP (EQ, dynamics, FIR, room, Speaker IR, image, protection) the active configuration
    /// would apply, ready to map onto an N-channel or Virtual Speakers graph. Nil when the flag is off, when global
    /// bypass or reference audition removes the program DSP (the lane calibration, bass management, binaural
    /// rendering and protection stay), or when nothing is active. Throws when the configuration is unusable
    /// (missing filter, rate mismatch) or when the graph cannot reproduce it, so activation never silently drops it.
    func makeUnifiedProgramDSP(
        sampleRate: Double,
        shape: UnifiedGraphLayoutShape,
        virtualSpeakers: Bool,
        inputs candidate: LiveGraphInputs? = nil
    ) throws -> UnifiedGraphProgramDSP? {
        guard unifiedGraphEnabled else { return nil }
        let inputs = candidate ?? currentLiveGraphInputs
        let playback = inputs.playback
        if FIRUpdatePolicy.isRawBypassed(playback) || playback.auditionMode == .reference { return nil }
        if playback.auditionMode == .delta {
            throw LiveNChannelTransportError.unsupportedActiveDSP("delta audition")
        }
        var snapshot = try inputs.stereoEQ.makeGraphSnapshot(
            sampleRate: sampleRate,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            dynamicsConfiguration: inputs.dynamics,
            playbackConfiguration: playback,
            masterGainLinear: 1
        )
        // The ambient live target rides in the snapshot like the stereo path (E6 S9b); the stereo engine only
        // runs it on speakers, so Virtual Speakers keeps it off.
        if !virtualSpeakers {
            try attachAmbientCompensation(
                ambientTargetClampedToHeadroom(inputs.ambient, gainConfiguration: inputs.gain), to: &snapshot)
        }
        // The graph never reads the kernel's convolver slots; it takes the taps by generation. Generations here are
        // local to this one translation (1 EQ FIR, 2 room correction, 3 Speaker IR).
        var retained: [UInt64: UnifiedGraphFIRProgram] = [:]
        func info(_ generation: UInt64, _ left: [Float], _ declared: UInt32) -> N60ConvolutionProgramInfo {
            N60ConvolutionProgramInfo(
                prepared: true,
                generation: generation,
                tapCount: UInt32(left.count),
                partitionCount: N60ConvolutionPartitionCountForTapCount(UInt32(left.count)),
                engineLatencyFrames: N60_CONVOLUTION_PARTITION_FRAMES,
                declaredLatencyFrames: declared
            )
        }
        if FIRUpdatePolicy.shouldPrepareEQFIR(stereoEQ: inputs.stereoEQ, playback: playback) {
            let taps = try eqFIRTaps(inputs.stereoEQ, sampleRate: sampleRate)
            retained[1] = UnifiedGraphFIRProgram(
                generation: 1, left: taps.left, right: taps.right, declaredLatencyFrames: taps.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetConvolutionProgram(
                &snapshot, 0, info(1, taps.left, taps.declaredLatencyFrames), true) else {
                throw EQConfigurationError.convolutionProgramUnavailable
            }
        }
        if inputs.room.enabled {
            guard let filter = inputs.room.filter else {
                throw RoomCorrectionConfigurationError.filterRequired
            }
            try validateRoomCorrectionFilter(filter, outputSampleRate: sampleRate)
            let adapted = rateAdaptedRoomCorrectionFilter(filter, sampleRate: sampleRate)
            retained[2] = UnifiedGraphFIRProgram(
                generation: 2, left: adapted.leftTaps, right: adapted.rightTaps,
                declaredLatencyFrames: adapted.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetRoomCorrectionProgram(
                &snapshot, 1, info(2, adapted.leftTaps, adapted.declaredLatencyFrames), true) else {
                throw RoomCorrectionConfigurationError.graphAttachmentFailed
            }
        }
        if inputs.speakerIR.enabled {
            guard let filter = inputs.speakerIR.filter else {
                throw SpeakerIRConfigurationError.filterRequired
            }
            try validateSpeakerIRFilter(filter, outputSampleRate: sampleRate)
            retained[3] = UnifiedGraphFIRProgram(
                generation: 3, left: filter.leftTaps, right: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames)
            guard N60DSPGraphSnapshotSetSpeakerIRProgram(
                &snapshot, 2, info(3, filter.leftTaps, filter.declaredLatencyFrames), true) else {
                throw SpeakerIRConfigurationError.graphAttachmentFailed
            }
        }
        let programs = retained
        let stereo: UnifiedGraphConfiguration
        switch UnifiedGraphTranslator.stereoEligibility(
            snapshot: &snapshot, sampleRate: sampleRate, programs: { _, generation in programs[generation] }
        ) {
        case .success(let configuration): stereo = configuration
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        }
        // Bypassed EQ covers every lane (the other program stages follow the lane set of the EQ mode).
        let mode: UnifiedGraphProgramDSP.EQMode
        switch inputs.stereoEQ.bypassed ? .linked : inputs.stereoEQ.channelMode {
        case .linked: mode = .linked
        case .independent: mode = .independent
        case .midSide: mode = .midSide
        }
        let program = UnifiedGraphProgramDSP(
            stereo: stereo, shape: shape, eqMode: mode, virtualSpeakers: virtualSpeakers)
        return program.isNeutral ? nil : program
    }

    // MARK: E6 S9b live edits on a graph-rendered N-channel or binaural session

    /// Every engine setting that shapes an N-channel or binaural graph, so a setter can build the graph for the
    /// candidate value and publish it before it commits the value.
    struct LiveGraphInputs {
        var stereoEQ: StereoEQConfiguration
        var dynamics: DynamicsConfiguration
        var playback: PlaybackControlConfiguration
        var gain: DSPGainConfiguration
        var bass: BassManagementConfiguration
        var room: RoomCorrectionConfiguration
        var speakerIR: SpeakerIRConfiguration
        var ambient: AmbientCompensationTarget
        /// E12 S4a: the guided-setup Level step's noise. nil (the default) means no generator stage. Any hand-built
        /// inputs must carry this forward or a later edit drops the noise.
        var generator: LiveGenerator?
    }

    /// A generator the engine keeps playing across live graph edits.
    struct LiveGenerator: Equatable {
        var settings: SignalGeneratorSettings
        var selection: SignalGeneratorLaneSelection
    }

    /// E12 S4a: the generator currently published to the live graph, or nil when none is playing. Never persisted:
    /// a session restart, stop or output change clears it.
    private(set) var liveGenerator: LiveGenerator?

    /// Plays (or, with nil, stops) the E11 generator on the running graph through the normal republish path:
    /// N-channel graphs through `republishLiveGraph`, the stereo graph through its transport session. Throws and
    /// leaves the playing state as it was when the running session cannot take the edit (kernel render, binaural,
    /// flag off), the selection matches no lane, or the settings cannot form a stage at the output rate.
    func setLiveGenerator(_ settings: SignalGeneratorSettings?, selection: SignalGeneratorLaneSelection = .allProgram(includeLFE: false)) throws {
        if let session = nChannelTransportSession, liveGraphEditsAvailable {
            var wanted: LiveGenerator?
            if let settings {
                guard let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles),
                      selection.mask(laneCount: shape.laneCount, lfeLane: shape.lfeLane) != nil,
                      settings.stageParams(active: true, sampleRate: session.outputFormat.sampleRate) != nil else {
                    throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
                }
                wanted = LiveGenerator(settings: settings, selection: selection)
            }
            var inputs = currentLiveGraphInputs
            inputs.generator = wanted
            try republishLiveGraph(inputs)
            liveGenerator = wanted
        } else if let session = transportSession {
            var mask: UInt64?
            if settings != nil {
                guard let resolved = selection.mask(laneCount: 2, lfeLane: nil) else {
                    throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
                }
                mask = resolved
            }
            try session.setLiveGenerator(settings, laneMask: mask)
            liveGenerator = settings.map { LiveGenerator(settings: $0, selection: selection) }
        } else if nChannelTransportSession != nil || binauralHeadphoneTransportSession != nil {
            // A graph that cannot take the edit may still hold a generator, so never report it stopped.
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        } else if settings == nil {
            liveGenerator = nil
        } else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
    }

    /// E12 S4a: the lanes the Level step can play noise on, for the running session (stereo L/R when the stereo
    /// transport runs or nothing runs yet).
    var generatorLaneChoices: [(index: Int, name: String, isLFE: Bool)] {
        if let session = nChannelTransportSession {
            return session.routePlan.programLayout.roles.enumerated().map {
                ($0.offset, $0.element.displayName, $0.element == .lowFrequencyEffects)
            }
        }
        return [(0, OutputProgramRole.frontLeft.displayName, false), (1, OutputProgramRole.frontRight.displayName, false)]
    }

    var currentLiveGraphInputs: LiveGraphInputs {
        LiveGraphInputs(
            stereoEQ: stereoEQConfiguration, dynamics: dynamicsConfiguration,
            playback: playbackControlConfiguration, gain: gainConfiguration,
            bass: bassManagementConfiguration, room: roomCorrectionConfiguration,
            speakerIR: speakerIRConfiguration, ambient: ambientCompensationRuntimeTarget,
            generator: liveGenerator)
    }

    /// True when the flag is on and the running N-channel or binaural session is rendered by the graph, so the
    /// setters can republish it instead of asking for a restart. A session that started on the legacy path (or any
    /// session with the flag off) keeps `configurationChangeRequiresRestart`.
    var liveGraphEditsAvailable: Bool {
        guard unifiedGraphEnabled else { return false }
        if let session = nChannelTransportSession { return session.unifiedGraphActive }
        if let session = binauralHeadphoneTransportSession { return session.unifiedGraphActive }
        return false
    }

    /// E6 decision 8: independent (left/right) stereo EQ applies no EQ to a layout's unpaired lanes (centre, centre
    /// surround, ...). Non-nil text for the equaliser view when the running N-channel layout has such lanes.
    var unpairedEQLaneNote: String? {
        guard stereoEQConfiguration.channelMode == .independent,
              let session = nChannelTransportSession,
              let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles) else { return nil }
        var covered = Set(shape.pairs.flatMap { [$0.a, $0.b] })
        if let lfe = shape.lfeLane { covered.insert(lfe) }
        guard covered.count < shape.laneCount else { return nil }
        return "Independent mode applies the left and right curves to channel pairs only. Unpaired channels "
            + "(such as centre) get no stereo EQ; use Linked or Mid/Side to include them."
    }

    /// Call where a setter used to throw for a changed value: it still throws `configurationChangeRequiresRestart`
    /// unless the session's graph can take the edit.
    private func requireLiveGraphEdits() throws {
        guard liveGraphEditsAvailable else { throw LiveNChannelTransportError.configurationChangeRequiresRestart }
    }

    /// Builds the graph for `inputs` and moves the running graph to it. Throws (a named reason) and leaves the
    /// running graph untouched when the graph cannot take the edit; call it as the last step before committing state.
    private func republishLiveGraph(
        _ inputs: LiveGraphInputs, headphoneBase: UnifiedGraphSpec? = nil, routing: SpeakerRoutingConfiguration? = nil
    ) throws {
        if let session = nChannelTransportSession {
            let rate = session.outputFormat.sampleRate
            guard let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles) else {
                throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
            }
            let program = try makeUnifiedProgramDSP(
                sampleRate: rate, shape: shape, virtualSpeakers: false, inputs: inputs)
            var configuration: UnifiedGraphConfiguration
            if session.routePlan.isRouted {
                guard let activeRouting = routing ?? speakerRoutingConfiguration, activeRouting.enabled else {
                    throw LiveNChannelTransportError.routingRefused("the session is routed but no routing is set.")
                }
                configuration = try makeRoutedGraphConfiguration(
                    routing: activeRouting, routePlan: session.routePlan, sampleRate: rate, inputs: inputs)
            } else {
                switch UnifiedGraphTranslator.nChannelEligibility(
                    routePlan: session.routePlan, sampleRate: rate, gainConfiguration: inputs.gain,
                    bassManagementConfiguration: renderBassManagementConfiguration(inputs.bass), programDSP: program
                ) {
                case .success(let built): configuration = built
                case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
                }
            }
            if let generator = inputs.generator {
                guard let mask = generator.selection.mask(laneCount: shape.laneCount, lfeLane: shape.lfeLane),
                      let params = generator.settings.stageParams(active: true, sampleRate: rate) else {
                    throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected)
                }
                configuration.generatorParams = params
                configuration.generatorLaneMask = mask
            }
            try session.republishGraph(configuration)
        } else if let session = binauralHeadphoneTransportSession {
            guard let base = headphoneBase ?? session.unifiedGraphBaseSpec,
                  let shape = UnifiedGraphLayoutShape(roles: session.programLayout.roles) else {
                throw LiveNChannelTransportError.configurationChangeRequiresRestart
            }
            let program = try makeUnifiedProgramDSP(
                sampleRate: session.outputFormat.sampleRate, shape: shape, virtualSpeakers: true, inputs: inputs)
            let combinedDB = inputs.gain.inputPreampDB + inputs.gain.headroomAttenuationDB + inputs.gain.outputGainDB
            switch UnifiedGraphTranslator.binauralApplyProgram(
                base: base, programDSP: program, programGain: Float(DSPGainConfiguration.linearGain(forDB: combinedDB))
            ) {
            case .success(let spec):
                try session.republishGraph(spec)
                if let headphoneBase { session.commitUnifiedGraphBaseSpec(headphoneBase) }
            case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
            }
        } else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
    }

    private func attachEQFIRProgram(
        _ program: PreparedEQFIRProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetConvolutionProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw EQConfigurationError.linearPhaseDesignFailed
        }
    }

    private func attachActiveEQFIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        stereoConfiguration: StereoEQConfiguration,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              stereoConfiguration.requiresEQFIRProgram,
              !stereoConfiguration.bypassed else { return }
        guard let activeEQFIRProgram else {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        try attachEQFIRProgram(activeEQFIRProgram, to: &graph)
    }

    private func attachRoomCorrectionProgram(
        _ program: PreparedRoomCorrectionProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetRoomCorrectionProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw RoomCorrectionConfigurationError.graphAttachmentFailed
        }
    }

    private func attachActiveRoomCorrectionProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              roomCorrectionConfiguration.enabled else { return }
        guard let activeRoomCorrectionProgram else {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        try attachRoomCorrectionProgram(activeRoomCorrectionProgram, to: &graph)
    }

    private func attachAmbientCompensation(
        _ target: AmbientCompensationTarget,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        let enabled = abs(target.levelDB) > 0.000_1
            || abs(target.lowSupportDB) > 0.000_1
            || abs(target.presenceSupportDB) > 0.000_1
            || abs(target.detailSupportDB) > 0.000_1
        guard N60DSPGraphSnapshotSetActiveAcousticsAdaptation(
            &graph,
            target.levelDB,
            target.lowSupportDB,
            target.presenceSupportDB,
            target.detailSupportDB,
            enabled
        ) else {
            throw AmbientCompensationError.invalidConfiguration
        }
    }

    private func attachAmbientCompensation(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachAmbientCompensation(
            ambientCompensationRuntimeTarget,
            to: &graph
        )
    }

    private func ambientTargetClampedToHeadroom(
        _ target: AmbientCompensationTarget,
        gainConfiguration: DSPGainConfiguration
    ) -> AmbientCompensationTarget {
        var clamped = target
        let available = max(
            -gainConfiguration.headroomAttenuationDB,
            0
        )
        if target.levelDB > 0 {
            clamped.levelDB = min(
                target.levelDB,
                available,
                AmbientCompensationConfiguration
                    .hardMaximumLevelCompensationDB
            )
        } else {
            clamped.levelDB = max(target.levelDB, -6.0)
        }
        return clamped
    }

    private func attachActiveQuietZone(
        _ target: ActiveQuietZoneRuntimeTarget,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        let resolved =
            processingIsBypassed(
                playbackControlConfiguration
            )
            ? ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds:
                    target.transitionMilliseconds
            )
            : target
        let transitionFramesDouble =
            graph.sampleRate
            * resolved.transitionMilliseconds
            / 1_000
        guard transitionFramesDouble.isFinite,
              transitionFramesDouble >= 1,
              transitionFramesDouble
                <= Double(UInt32.max) else {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        let transitionFrames =
            UInt32(transitionFramesDouble.rounded())

        var tones = resolved.tones.map { tone in
            var value =
                N60ActiveQuietZoneToneSnapshot()
            value.frequencyHz = tone.frequencyHz
            value.leftReal =
                Float(tone.leftOutput.real)
            value.leftImaginary =
                Float(tone.leftOutput.imaginary)
            value.rightReal =
                Float(tone.rightOutput.real)
            value.rightImaginary =
                Float(tone.rightOutput.imaginary)
            return value
        }

        let attached: Bool
        if tones.isEmpty {
            attached =
                N60DSPGraphSnapshotSetActiveQuietZone(
                    &graph,
                    nil,
                    0,
                    transitionFrames,
                    false
                )
        } else {
            attached =
                tones.withUnsafeMutableBufferPointer {
                    N60DSPGraphSnapshotSetActiveQuietZone(
                        &graph,
                        $0.baseAddress,
                        UInt32($0.count),
                        transitionFrames,
                        true
                    )
                }
        }
        if attached, adaptiveTonalMailboxEnabled, !tones.isEmpty, let generation = resolved.armGeneration,
           !N60DSPGraphSnapshotSetActiveQuietZoneArmGeneration(&graph, generation &+ 1) {
            throw ActiveQuietZoneError.invalidConfiguration
        }
        let toneCaps: [Float] = excursionCapCurve.map { curve in
            tones.map { curve.trackedCapLinear(atHz: Double($0.frequencyHz)) }
        } ?? []
        let earnedInitial = earnedCapInitialLinear
        let snapshotCapDBFS = earnedInitial > 0
            ? LiveTreatmentSafeguards.hardMaximumPeakCapDBFS
            : LiveTreatmentSafeguards.defaultPeakCapDBFS
        guard attached,
              N60DSPGraphSnapshotSetActiveQuietZonePeakCap(
                &graph,
                Float(LiveTreatmentSafeguards.linearPeak(dbfs: snapshotCapDBFS))
              ),
              N60DSPGraphSnapshotSetActiveQuietZoneInitialCap(&graph, tones.isEmpty ? 0 : earnedInitial),
              toneCaps.withUnsafeBufferPointer({
                  N60DSPGraphSnapshotSetActiveQuietZoneToneCaps(&graph, $0.baseAddress, UInt32($0.count))
              }) else {
            throw ActiveQuietZoneError
                .invalidConfiguration
        }
    }

    private func attachActiveQuietZone(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachActiveQuietZone(
            activeQuietZoneRuntimeTarget,
            to: &graph
        )
    }

    private func activeQuietZoneTargetAfterHeadroomChange(
        _ target: ActiveQuietZoneRuntimeTarget,
        gainConfiguration: DSPGainConfiguration,
        ambientTarget: AmbientCompensationTarget
    ) -> ActiveQuietZoneRuntimeTarget {
        guard target.active else { return target }
        let available = LiveTreatmentSafeguards.limitedInjectionPeak(
            (
                try? ActiveQuietZonePlanner()
                    .availableInjectionPeak(
                        headroomAttenuationDB:
                            gainConfiguration
                                .headroomAttenuationDB,
                        ambientLevelRecoveryDB:
                            max(ambientTarget.levelDB, 0),
                        configuration:
                            ActiveQuietZoneConfiguration()
                    )
            )
            ?? 0
        )
        guard target.maximumSourceMagnitude
                <= available + 1.0e-7 else {
            // Never rescale solved phasors behind the controller's back.
            return ActiveQuietZoneRuntimeTarget(
                tones: [],
                transitionMilliseconds: 100
            )
        }
        return target
    }

    private func applyAudioUnitRackLatency(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        try attachAmbientCompensation(to: &graph)
        try attachActiveQuietZone(to: &graph)
        guard let stagedAudioUnitRack else { return }
        let combinedLatency =
            UInt64(graph.latencyFrames)
            + UInt64(max(stagedAudioUnitRack.latencyFrames, 0))
        guard combinedLatency <= UInt64(UInt32.max) else {
            throw CoreAudioTransportError.audioUnitRackConfigurationFailed
        }
        if graph.auditionMode != N60AuditionModeProcessed,
           combinedLatency >= UInt64(N60_MAX_AUDITION_DELAY_FRAMES) {
            throw CoreAudioTransportError.audioUnitRackConfigurationFailed
        }
        graph.latencyFrames = UInt32(combinedLatency)
    }

    private func attachSpeakerIRProgram(
        _ program: PreparedSpeakerIRProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetSpeakerIRProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw SpeakerIRConfigurationError.graphAttachmentFailed
        }
    }

    private func attachActiveSpeakerIRProgramIfNeeded(
        to graph: inout N60DSPGraphSnapshot,
        playbackConfiguration: PlaybackControlConfiguration
    ) throws {
        guard !processingIsBypassed(playbackConfiguration),
              speakerIRConfiguration.enabled else { return }
        guard let activeSpeakerIRProgram else {
            throw SpeakerIRConfigurationError.convolutionProgramUnavailable
        }
        try attachSpeakerIRProgram(activeSpeakerIRProgram, to: &graph)
    }

    private func start(resetProcessingSessionCounters: Bool) throws {
        guard lifecycle.state == .idle else { return }
        try refreshOutputDevices()
        guard let output = selectedOutputDevice else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: routeConfiguration.selectedOutputUID ?? "No output selected")
            lastErrorDescription = error.localizedDescription
            throw error
        }

        if resetProcessingSessionCounters {
            processingSessionArchivedCounters = AudioTransportCounters()
        }

        do {
            try setLifecycle(.requestingPermission)
            try setLifecycle(.creatingTap)
            try buildTransport(output: output)
            try setLifecycle(.creatingAggregate)
            try setLifecycle(.openingOutput)
            try setLifecycle(.starting)
            try setLifecycle(.running)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            try syncMasterVolumeMonitorToSelectedOutput()
            lastErrorDescription = nil
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            throw error
        }
    }

    private func setLifecycle(_ nextState: AudioLifecycleState) throws {
        try lifecycle.transition(to: nextState)
        lifecycleState = lifecycle.state
    }

    private func buildTransport(output: AudioOutputDevice) throws {
        applyLowLatencyOutputProfile(to: output)
        if let headphone = headphoneDeviceProfileConfiguration, headphone.enabled {
            if outputDeviceProfileConfiguration?.enabled == true {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
            if headphone.spatialMode == .virtualSpeakers {
                try buildBinauralHeadphoneTransport(output: output, profile: headphone)
            } else {
                try buildStereoTransport(output: output)
            }
            return
        }
        if let routing = speakerRoutingConfiguration, routing.enabled {
            try buildRoutedTransport(output: output, routing: routing)
            return
        }
        if outputDeviceProfileConfiguration?.enabled == true {
            try buildNChannelTransport(output: output)
            return
        }
        try buildStereoTransport(output: output)
    }

    /// E8 S4: the graph configuration of a routed session: the program lanes and sub lanes the N-channel path
    /// builds, with the routing compiled onto them (ROUTE, XOVER, delay alignment, per-output protection).
    func makeRoutedGraphConfiguration(
        routing: SpeakerRoutingConfiguration,
        routePlan: LiveNChannelOutputRoutePlan,
        sampleRate: Double,
        inputs: LiveGraphInputs
    ) throws -> UnifiedGraphConfiguration {
        guard let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles) else {
            throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
        }
        let program = try makeUnifiedProgramDSP(sampleRate: sampleRate, shape: shape, virtualSpeakers: false, inputs: inputs)
        // The routing's sub sources decide the sub lanes; bass management supplies their crossover and trims.
        var bass = renderBassManagementConfiguration(inputs.bass)
        bass.enabled = routePlan.subwooferCount > 0
        switch UnifiedGraphTranslator.nChannelEligibility(
            routePlan: routePlan, sampleRate: sampleRate, gainConfiguration: inputs.gain,
            bassManagementConfiguration: bass, programDSP: program
        ) {
        case .success(var base):
            // The user's protection moves from the program lanes to every output lane (the compiler gives each
            // output its own PROTECTION stage, aligned in latency); a program-lane limiter would run on cleared lanes.
            if base.protection == nil, let moved = base.programDSP?.protection { base.protection = moved }
            base.programDSP?.protection = nil
            // The bridge reads the output lanes as the last `routedOutputPhysicalChannels.count` graph lanes, so the
            // compiled routing must have exactly that many (it does by construction; this keeps it so).
            guard routing.outputEndpoints.count == routePlan.routedOutputPhysicalChannels.count else {
                throw LiveNChannelTransportError.routingRefused("the routing outputs do not match the output plan.")
            }
            do { return try SpeakerRoutingCompiler.compile(routing, onto: base) } catch SpeakerRoutingCompileError.invalid(let errors) {
                throw LiveNChannelTransportError.routingRefused("the routing is not valid (\(errors.map { "\($0)" }.joined(separator: ", "))).")
            }
        case .failure(let reason): throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        }
    }

    /// Checks that apply to any enabled routing, whether it is being set or started.
    private func validateSpeakerRoutingActivation(_ routing: SpeakerRoutingConfiguration) throws {
        guard unifiedGraphEnabled else {
            throw LiveNChannelTransportError.routingRefused("it needs the unified graph, and the legacy render kernel is selected.")
        }
        if headphoneDeviceProfileConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.speakerProfileConflict
        }
        if multiOutputRoutingConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        let subs = routing.subwooferSourceCount
        if subs > UnifiedGraphConfiguration.maxSubwoofers {
            throw LiveNChannelTransportError.routingRefused("it reads \(subs) subwoofer sources and the limit is \(UnifiedGraphConfiguration.maxSubwoofers).")
        }
        if subs > 0, !bassManagementConfiguration.enabled {
            throw LiveNChannelTransportError.routingRefused("it reads subwoofer sources, so bass management must be on.")
        }
        if subs == 0, bassManagementConfiguration.enabled {
            throw LiveNChannelTransportError.routingRefused("bass management is on but no speaker reads a subwoofer source.")
        }
    }

    /// E8 S4: sets (or, with nil, clears) the speaker routing. Idle, it just stores it. Running, an edit that keeps
    /// the same outputs and subwoofer sources (crossover corners, gains, trims, delays, EQ) is republished to the
    /// graph, which posts gain changes over 5 ms and fades a family or order change; any other change is a
    /// session-kind change and reconfigures with the shutdown fade. Throws, leaving the routing and the running
    /// session as they were, when the routing cannot run.
    func replaceSpeakerRoutingConfiguration(_ configuration: SpeakerRoutingConfiguration?) throws {
        let active = configuration?.enabled == true
        if let configuration, active { try validateSpeakerRoutingActivation(configuration) }
        guard configuration != speakerRoutingConfiguration else { return }
        let wasActive = speakerRoutingConfiguration?.enabled == true
        guard lifecycle.state != .idle, active || wasActive else {
            speakerRoutingConfiguration = configuration
            lastErrorDescription = nil
            return
        }
        if let configuration, active, let current = speakerRoutingConfiguration, wasActive,
           let session = nChannelTransportSession, session.routePlan.isRouted, liveGraphEditsAvailable,
           current.outputEndpoints == configuration.outputEndpoints,
           current.subwooferSourceCount == configuration.subwooferSourceCount {
            try republishLiveGraph(currentLiveGraphInputs, routing: configuration)
            speakerRoutingConfiguration = configuration
            lastErrorDescription = nil
            return
        }
        speakerRoutingConfiguration = configuration
        lastErrorDescription = nil
        scheduleSampleRateReconfiguration(countsAsSampleRateChange: false, fadeOut: true, settleDelay: 0.03)
    }

    private func buildRoutedTransport(output: AudioOutputDevice, routing: SpeakerRoutingConfiguration) throws {
        try validateSpeakerRoutingActivation(routing)
        try validateLiveNChannelActivation()
        if stagedRoomTreatment != nil {
            throw LiveNChannelTransportError.routingRefused("room treatment cannot run with the routing matrix.")
        }
        // The program layout comes from an enabled Output Device Profile (5.1 and so on), else stereo. The routing
        // owns every physical output, so the profile's speaker and subwoofer assignments are not used.
        let layout = outputDeviceProfileConfiguration?.enabled == true
            ? (outputDeviceProfileConfiguration?.programLayout ?? .stereo) : .stereo
        let routePlan = try routing.makeLivePlan(
            programLayout: layout,
            availableDevices: outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: output.uid,
            bassManagementEnabled: routing.subwooferSourceCount > 0
        )
        let renderGraph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: routePlan,
            sampleRate: output.nominalSampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        )
        let configuration = try makeRoutedGraphConfiguration(
            routing: routing, routePlan: routePlan, sampleRate: output.nominalSampleRate,
            inputs: currentLiveGraphInputs)
        let session = try CoreAudioNChannelTransportSession(
            selectedOutput: output,
            routePlan: routePlan,
            renderGraph: renderGraph,
            outputGain: currentMasterSoftwareGain,
            roomTreatment: nil,
            audioUnitRack: stagedAudioUnitRack,
            unifiedGraphConfiguration: configuration,
            unifiedGraphIneligibility: nil,
            unifiedGraphRequired: true
        )
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
        linearPhaseDesignInfo = nil
        nChannelTransportSession = session
    }

    private func validateLiveNChannelActivation() throws {
        if multiOutputRoutingConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if !speakerDriverProcessingConfiguration.isNeutral {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy per-driver speaker processing")
        }
        // E6 S9a: with the unified graph the stereo-class DSP is mapped onto the program lanes (or the activation
        // throws the graph's reason); without it every restriction below stays.
        if !unifiedGraphEnabled {
            if !stereoEQConfiguration.bypassed {
                if stereoEQConfiguration.channelMode != .linked
                    || stereoEQConfiguration.phaseMode != .minimumPhase
                    || stereoEQConfiguration.enabledBandCount != 0 {
                    throw LiveNChannelTransportError.unsupportedActiveDSP("stereo EQ")
                }
            }
            // Gate on what would actually process audio. Disabled processors keep
            // their edited parameters and must not block activation.
            if playbackControlConfiguration.globalBypassed {
                throw LiveNChannelTransportError.globalBypassUnsupported
            }
            if playbackControlConfiguration.hasActiveImageProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo playback/image controls")
            }
            if dynamicsConfiguration.hasActiveProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo dynamics/protection")
            }
            if roomCorrectionConfiguration.enabled {
                throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo room correction")
            }
            if speakerIRConfiguration.enabled {
                throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo Speaker IR")
            }
        }
        if bassManagementConfiguration.physicalOutputMode != nil {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy physical crossover routing")
        }
        if bassManagementConfiguration.subPhaseAlignmentEnabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy single-sub phase alignment")
        }
        if bassManagementConfiguration.monitorMode != .recombined {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo crossover monitor audition")
        }
    }

    private func buildNChannelTransport(output: AudioOutputDevice) throws {
        guard let profile = outputDeviceProfileConfiguration, profile.enabled else {
            throw OutputDeviceProfileError.profileDisabled
        }
        try validateLiveNChannelActivation()
        let routePlan = try profile.makeLivePlan(
            availableDevices: outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: output.uid,
            bassManagementEnabled: bassManagementConfiguration.enabled
        )
        if let stagedRoomTreatment {
            guard stagedRoomTreatment.acceptedProfile == profile,
                  stagedRoomTreatment.acceptedSelectedOutputUID == output.uid else {
                throw LiveNChannelTransportError.roomTreatmentPermitMismatch
            }
        }
        // E8 A3: the legacy kernel drives at most 4 subs; refuse by name rather than truncate. The graph path below
        // takes 5 to 8 and must then be required (checked after eligibility).
        if bassManagementConfiguration.enabled,
           Int(routePlan.subwooferCount) > SubwooferLimit.legacyKernel,
           !unifiedGraphEnabled {
            throw LiveNChannelTransportError.tooManySubwoofersForLegacyKernel(Int(routePlan.subwooferCount))
        }
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: routePlan,
            sampleRate: output.nominalSampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        )
        var graphConfiguration: UnifiedGraphConfiguration?
        var graphIneligibility: UnifiedGraphFallbackReason?
        var programDSP: UnifiedGraphProgramDSP?
        if unifiedGraphEnabled {
            // E6 S9a: stereo-class DSP runs on the graph or activation throws; it is never dropped.
            guard let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles) else {
                throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
            }
            programDSP = try makeUnifiedProgramDSP(
                sampleRate: output.nominalSampleRate, shape: shape, virtualSpeakers: false)
            switch UnifiedGraphTranslator.nChannelEligibility(
                routePlan: routePlan,
                sampleRate: output.nominalSampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: bassManagementConfiguration,
                programDSP: programDSP
            ) {
            case .success(let configuration): graphConfiguration = configuration
            case .failure(let reason): graphIneligibility = reason
            }
        }
        // E8 A3: a graph that cannot take the setup would fall back to the legacy kernel; with 5 to 8 subs that is
        // a refusal, not a truncation.
        let needsGraphForSubs = bassManagementConfiguration.enabled
            && Int(routePlan.subwooferCount) > SubwooferLimit.legacyKernel
        if needsGraphForSubs, graphConfiguration == nil {
            throw LiveNChannelTransportError.tooManySubwoofersForLegacyKernel(Int(routePlan.subwooferCount))
        }
        let session = try CoreAudioNChannelTransportSession(
            selectedOutput: output,
            routePlan: routePlan,
            renderGraph: graph,
            outputGain: currentMasterSoftwareGain,
            roomTreatment: stagedRoomTreatment,
            audioUnitRack: stagedAudioUnitRack,
            unifiedGraphConfiguration: graphConfiguration,
            unifiedGraphIneligibility: graphIneligibility,
            unifiedGraphRequired: programDSP != nil || needsGraphForSubs
        )
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
        linearPhaseDesignInfo = nil
        nChannelTransportSession = session
    }

    private func validateBinauralHeadphoneActivation() throws {
        if multiOutputRoutingConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if outputDeviceProfileConfiguration?.enabled == true {
            throw HeadphoneDeviceProfileError.speakerProfileConflict
        }
        if !speakerDriverProcessingConfiguration.isNeutral {
            throw LiveNChannelTransportError.unsupportedActiveDSP("per-driver speaker processing")
        }
        if !unifiedGraphEnabled {
            if !stereoEQConfiguration.bypassed {
                if stereoEQConfiguration.channelMode != .linked
                    || stereoEQConfiguration.phaseMode != .minimumPhase
                    || stereoEQConfiguration.enabledBandCount != 0 {
                    throw LiveNChannelTransportError.unsupportedActiveDSP("stereo EQ in Virtual Speakers mode")
                }
            }
            if playbackControlConfiguration.globalBypassed {
                throw LiveNChannelTransportError.globalBypassUnsupported
            }
            if playbackControlConfiguration.hasActiveImageProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo playback/image controls in Virtual Speakers mode")
            }
            if dynamicsConfiguration.hasActiveProcessing {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo dynamics in Virtual Speakers mode")
            }
        }
        if bassManagementConfiguration.enabled
            || bassManagementConfiguration.physicalOutputMode != nil
            || bassManagementConfiguration.subPhaseAlignmentEnabled
            || bassManagementConfiguration.monitorMode != .recombined {
            throw LiveNChannelTransportError.unsupportedActiveDSP("speaker bass management in Virtual Speakers mode")
        }
        if roomCorrectionConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("speaker room correction in Virtual Speakers mode")
        }
        if speakerIRConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("Speaker IR in Virtual Speakers mode")
        }
    }

    private func buildBinauralHeadphoneTransport(
        output: AudioOutputDevice,
        profile: HeadphoneDeviceProfileConfiguration
    ) throws {
        try validateBinauralHeadphoneActivation()
        let selected = try profile.validateForActivation(
            availableDevices: outputDevices,
            selectedOutputUID: output.uid,
            sampleRate: output.nominalSampleRate
        )
        let source = try profile.resolveProgramSource(
            availableDevices: outputDevices,
            selectedOutput: selected
        )
        guard source.supports(sampleRate: output.nominalSampleRate) else {
            throw BinauralHeadphoneTransportError.sampleRateMismatch(
                source: source.nominalSampleRate, output: output.nominalSampleRate
            )
        }
        guard let reference = profile.binauralProfile else {
            throw HeadphoneDeviceProfileError.binauralProfileRequired
        }
        // HRIRs measured at another rate are converted off the realtime path
        // rather than refusing to start after a nominal-rate change.
        let asset = try binauralAssetCache.asset(
            for: reference, sampleRate: output.nominalSampleRate, store: binauralProfileAssetStore)
        renderedBinauralProfile = reference
        let prepared = try asset.prepare(for: profile.programLayout)
        let headphoneSnapshot = try profile.makeRealtimeSnapshot(
            sampleRate: output.nominalSampleRate
        )
        let combinedGainDB = gainConfiguration.inputPreampDB
            + gainConfiguration.headroomAttenuationDB
            + gainConfiguration.outputGainDB
        let programGain = DSPGainConfiguration.linearGain(forDB: combinedGainDB)
        guard programGain.isFinite, programGain > 0, programGain <= 16 else {
            throw BinauralHeadphoneTransportError.bridgeAllocationFailed
        }
        // E6 S8b2d: with the flag on, the core renders binaural, headphone DSP and protection when
        // the setup is one it reproduces; otherwise the legacy pipeline stays and the reason shows
        // in diagnostics.
        var graphSpec: UnifiedGraphSpec?
        var graphBaseSpec: UnifiedGraphSpec?
        var graphIneligibility: UnifiedGraphFallbackReason?
        var programDSP: UnifiedGraphProgramDSP?
        if unifiedGraphEnabled {
            guard let shape = UnifiedGraphLayoutShape(roles: profile.programLayout.roles) else {
                throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
            }
            programDSP = try makeUnifiedProgramDSP(
                sampleRate: output.nominalSampleRate, shape: shape, virtualSpeakers: true)
            switch UnifiedGraphTranslator.binauralBaseSpec(
                asset: asset,
                layout: profile.programLayout,
                profile: profile,
                outputChannels: UInt32(output.outputChannelCount),
                sampleRate: output.nominalSampleRate,
                headTracking: profile.headTracking?.enabled == true,
                programGain: Float(programGain)
            ) {
            case .success(let base):
                switch UnifiedGraphTranslator.binauralApplyProgram(
                    base: base, programDSP: programDSP, programGain: Float(programGain)
                ) {
                case .success(let spec):
                    graphBaseSpec = base
                    graphSpec = spec
                case .failure(let reason): graphIneligibility = reason
                }
            case .failure(let reason): graphIneligibility = reason
            }
        }
        let session = try CoreAudioBinauralHeadphoneTransportSession(
            selectedOutput: output,
            programSource: source,
            programLayout: profile.programLayout,
            preparedProfile: prepared,
            headphoneSnapshot: headphoneSnapshot,
            programGain: programGain,
            outputGain: currentMasterSoftwareGain,
            audioUnitRack: stagedAudioUnitRack,
            unifiedGraphSpec: graphSpec,
            unifiedGraphBaseSpec: graphBaseSpec,
            unifiedGraphIneligibility: graphIneligibility,
            unifiedGraphRequired: programDSP != nil
        )
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
        linearPhaseDesignInfo = nil
        binauralHeadphoneTransportSession = session

        if let tracking = profile.headTracking, tracking.enabled {
            let controller = SpatialHeadTrackingController(
                configuration: tracking,
                asset: asset,
                layout: profile.programLayout,
                session: session
            ) { [weak self] status in
                Task { @MainActor [weak self] in
                    self?.headTrackingRuntimeStatus = status
                }
            }
            headTrackingController = controller
            try controller.start()
        } else {
            headTrackingController = nil
            headTrackingRuntimeStatus = .disabled
        }
    }

    private func buildStereoTransport(output: AudioOutputDevice) throws {
        var headphoneSnapshot: N60HeadphoneDSPSnapshot?
        if let headphone = headphoneDeviceProfileConfiguration, headphone.enabled {
            _ = try headphone.validateForActivation(
                availableDevices: outputDevices,
                selectedOutputUID: output.uid,
                sampleRate: output.nominalSampleRate
            )
            guard headphone.spatialMode == .stereo else {
                throw HeadphoneDeviceProfileError.binauralRuntimeUnavailable
            }
            guard multiOutputRoutingConfiguration?.enabled != true else {
                throw HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict
            }
            guard outputDeviceProfileConfiguration?.enabled != true else {
                throw HeadphoneDeviceProfileError.speakerProfileConflict
            }
            guard speakerDriverProcessingConfiguration.isNeutral else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("per-driver speaker processing")
            }
            guard !bassManagementConfiguration.enabled else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker bass management")
            }
            guard !roomCorrectionConfiguration.enabled else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("speaker room correction")
            }
            guard !speakerIRConfiguration.enabled else {
                throw HeadphoneDeviceProfileError.speakerProcessingConflict("Speaker IR")
            }
            headphoneSnapshot = try headphone.makeRealtimeSnapshot(sampleRate: output.nominalSampleRate)
        }

        let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?
        let aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan?
        if let routing = multiOutputRoutingConfiguration, routing.enabled {
            if routing.usesMultiplePhysicalDevices {
                let plan = try routing.makeAggregateDevicePlan(
                    availableDevices: outputDevices,
                    sampleRate: output.nominalSampleRate
                )
                try plan.validateForC3LiveTransport(selectedOutputUID: output.uid)
                aggregateDeviceOutputPlan = plan
                sameDeviceOutputPlan = nil
            } else {
                let plan = try routing.makeSameDevicePlan(
                    availableDevices: outputDevices,
                    sampleRate: output.nominalSampleRate
                )
                try plan.validateForC2bLiveTransport(selectedOutputUID: output.uid)
                sameDeviceOutputPlan = plan
                aggregateDeviceOutputPlan = nil
            }
        } else {
            sameDeviceOutputPlan = nil
            aggregateDeviceOutputPlan = nil
        }
        let speakerCrossoverMode: SpeakerCrossoverMode?
        let speakerBusSplitterSnapshot: N60SpeakerBusSplitterSnapshot?
        if physicalSpeakerBusRoutingActive {
            speakerCrossoverMode = bassManagementConfiguration.physicalOutputMode
            speakerBusSplitterSnapshot = try bassManagementConfiguration.makeSpeakerBusSplitterSnapshot(
                sampleRate: output.nominalSampleRate
            )
        } else {
            speakerCrossoverMode = nil
            speakerBusSplitterSnapshot = nil
        }
        if let plan = sameDeviceOutputPlan {
            try plan.validateForC4LiveTransport(
                selectedOutputUID: output.uid,
                crossoverMode: speakerCrossoverMode
            )
        }
        if let plan = aggregateDeviceOutputPlan {
            try plan.validateForC4LiveTransport(
                selectedOutputUID: output.uid,
                crossoverMode: speakerCrossoverMode
            )
        }
        let speakerDriverProcessingSnapshot = try speakerDriverProcessingConfiguration
            .makeRealtimeSnapshot(sampleRate: output.nominalSampleRate)
        let session = try CoreAudioTransportSession(
            selectedOutput: output,
            sameDeviceOutputPlan: sameDeviceOutputPlan,
            aggregateDeviceOutputPlan: aggregateDeviceOutputPlan,
            speakerCrossoverMode: speakerCrossoverMode,
            speakerBusSplitterSnapshot: speakerBusSplitterSnapshot,
            speakerDriverProcessingSnapshot: speakerDriverProcessingSnapshot,
            audioUnitRack: stagedAudioUnitRack
        )
        session.unifiedGraphEnabled = unifiedGraphEnabled
        try session.configureHeadphoneDSP(
            headphoneSnapshot, profile: headphoneSnapshot == nil ? nil : headphoneDeviceProfileConfiguration)
        activeEQFIRProgram = nil
        nextEQFIRProgramSlot = 0
        activeRoomCorrectionProgram = nil
        nextRoomCorrectionProgramSlot = 0
        activeSpeakerIRProgram = nil
        nextSpeakerIRProgramSlot = 0
        var graph = try stereoTransportStartGraph(sampleRate: session.outputFormat.sampleRate)

        if FIRUpdatePolicy.shouldPrepareEQFIR(
            stereoEQ: stereoEQConfiguration,
            playback: playbackControlConfiguration
        ) {
            let preparedProgram = try prepareEQFIRProgram(stereoEQConfiguration, for: session)
            activeEQFIRProgram = preparedProgram
            linearPhaseDesignInfo = preparedProgram.designInfo
            try attachEQFIRProgram(preparedProgram, to: &graph)
        } else {
            linearPhaseDesignInfo = nil
        }

        if roomCorrectionConfiguration.enabled {
            guard let filter = roomCorrectionConfiguration.filter else {
                throw RoomCorrectionConfigurationError.filterRequired
            }
            try validateRoomCorrectionFilter(filter, outputSampleRate: session.outputFormat.sampleRate)
            if FIRUpdatePolicy.shouldPrepareRoomCorrection(
                roomCorrection: roomCorrectionConfiguration,
                playback: playbackControlConfiguration
            ) {
                let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
                activeRoomCorrectionProgram = preparedProgram
                try attachRoomCorrectionProgram(preparedProgram, to: &graph)
            }
        }

        if speakerIRConfiguration.enabled {
            guard let filter = speakerIRConfiguration.filter else {
                throw SpeakerIRConfigurationError.filterRequired
            }
            try validateSpeakerIRFilter(filter, outputSampleRate: session.outputFormat.sampleRate)
            if FIRUpdatePolicy.shouldPrepareSpeakerIR(
                speakerIR: speakerIRConfiguration,
                playback: playbackControlConfiguration
            ) {
                let preparedProgram = try prepareSpeakerIRProgram(filter, for: session)
                activeSpeakerIRProgram = preparedProgram
                try attachSpeakerIRProgram(preparedProgram, to: &graph)
            }
        }

        try applyAudioUnitRackLatency(to: &graph)
        try session.publishDSPGraph(graph)
        transportSession = session
    }

    /// Base graph for a newly built stereo transport (start, rate change,
    /// recovery, wake). It must carry the current software master gain and
    /// mute; the realtime kernel otherwise starts at unity until the next
    /// volume change republishes the graph.
    func stereoTransportStartGraph(sampleRate: Double) throws -> N60DSPGraphSnapshot {
        try stereoEQConfiguration.makeGraphSnapshot(
            sampleRate: sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: renderBassManagementConfiguration(),
            dynamicsConfiguration: dynamicsConfiguration,
            playbackConfiguration: playbackControlConfiguration,
            masterGainLinear: currentMasterSoftwareGain
        )
    }

    private func tearDownTransport(fadeOut: Bool, cause: TransportTeardownCause = .other) {
        liveGenerator = nil
        if let controller = headTrackingController {
            controller.stop()
            headTrackingController = nil
        }
        if headphoneDeviceProfileConfiguration?.enabled == true,
           headphoneDeviceProfileConfiguration?.spatialMode == .virtualSpeakers,
           headphoneDeviceProfileConfiguration?.headTracking?.enabled == true {
            headTrackingRuntimeStatus = .configuredStopped
        } else {
            headTrackingRuntimeStatus = .disabled
        }

        if let session = transportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            transportSession = nil
        }
        if let session = nChannelTransportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            nChannelTransportSession = nil
        }
        if let session = binauralHeadphoneTransportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            binauralHeadphoneTransportSession = nil
        }
        activeEQFIRProgram = nil
        activeRoomCorrectionProgram = nil
        activeSpeakerIRProgram = nil
        syncActiveQuietZoneLease(active: false)
        // The app's own profile switch happens while arming and keeps the arm (see `disarmReason`).
        if cause != .plannedProfileChange { liveTreatmentGeneration &+= 1 }
        for observer in transportTeardownObservers { observer.handler(cause) }
    }

    private func forceFailedState(_ error: Error) {
        lastErrorDescription = error.localizedDescription
        if AudioLifecycleStateMachine.canTransition(from: lifecycle.state, to: .failed) {
            try? lifecycle.transition(to: .failed)
            lifecycleState = lifecycle.state
        }
    }

    private func handleDeviceListChanged() {
        do { try refreshOutputDevices() } catch { return }
        guard let selectedUID = routeConfiguration.selectedOutputUID else { return }
        let selectedIsPresent = outputDevices.contains { $0.uid == selectedUID }
        let spatialSourceUID = headphoneDeviceProfileConfiguration?.spatialMode == .virtualSpeakers
            ? (headphoneDeviceProfileConfiguration?.programSourceDeviceUID ?? selectedUID)
            : selectedUID
        let spatialSourceIsPresent = outputDevices.contains { $0.uid == spatialSourceUID }

        if !selectedIsPresent {
            masterVolumeController.stopMonitoring()
            masterVolumeCapabilities = .softwareOnly
        } else {
            try? syncMasterVolumeMonitorToSelectedOutput()
        }

        if (!selectedIsPresent || !spatialSourceIsPresent)
            && (lifecycle.state == .running || lifecycle.state == .reconfiguring) {
            beginOutputRecovery()
            return
        }

        // Fast-path only while waiting for an absent output. After a failed build
        // the backoff schedule owns retries; our own tap/aggregate teardown also
        // posts device-list changes and must not turn backoff into a tight loop.
        if selectedIsPresent,
           lifecycle.state == .recoveringOutput,
           recoveryConsecutiveBuildFailures == 0 {
            scheduleRecoveryAttempt(generation: recoveryGeneration, delay: 0)
        }
    }

    /// E4 S7: switches the lowest-latency output buffer on or off. The buffer
    /// size is read when a transport is built, so a running transport is
    /// rebuilt through the reconfigure path (one short dropout). Off restores
    /// the size each device had before.
    func setLowLatencyOutputProfile(_ enabled: Bool) {
        guard enabled != lowLatencyOutputProfileActive else { return }
        lowLatencyOutputProfileActive = enabled
        if enabled {
            lowLatencyRestorePending = false
            lowLatencyBufferProfile.activate()
        } else {
            lowLatencyOutputBufferFrames = nil
            if lifecycle.state == .running {
                lowLatencyRestorePending = true
            } else {
                restoreLowLatencyBuffers()
            }
        }
        scheduleSampleRateReconfiguration(
            countsAsSampleRateChange: false,
            cause: .plannedProfileChange
        )
    }

    /// Puts back the buffer sizes the profile replaced. Only while no
    /// transport is open.
    private func restoreLowLatencyBuffers() {
        lowLatencyRestorePending = false
        let devices = outputDevices
        let result = lowLatencyBufferProfile.deactivate { uid in
            devices.first { $0.uid == uid }?.deviceID
        }
        if let failure = result.failures.first {
            lastErrorDescription = failure.localizedDescription
        }
    }

    private func applyLowLatencyOutputProfile(to output: AudioOutputDevice) {
        guard lowLatencyOutputProfileActive else { return }
        do {
            lowLatencyOutputBufferFrames = try lowLatencyBufferProfile.apply(
                to: output.deviceID,
                uid: output.uid,
                sampleRate: output.nominalSampleRate
            )
        } catch {
            // Best effort: the transport opens at the device's current size.
            lowLatencyOutputBufferFrames = nil
            lastErrorDescription = error.localizedDescription
        }
    }

    /// `fadeOut` ramps the live session to silence before teardown (about 20 ms, bridge-owned) so a
    /// user-initiated session rebuild never steps the output; device-driven rebuilds cannot fade
    /// because the device is already changing. `settleDelay` is the wait before the rebuild.
    private func scheduleSampleRateReconfiguration(
        countsAsSampleRateChange: Bool = true,
        fadeOut: Bool = false,
        settleDelay: TimeInterval = 0.15,
        cause: TransportTeardownCause = .reconfiguration
    ) {
        guard lifecycle.state == .running else { return }

        reconfigurationWorkItem?.cancel()
        do {
            try setLifecycle(.reconfiguring)
            eventMonitor.removeSelectedOutputSampleRateMonitor()
            tearDownTransport(fadeOut: fadeOut, cause: cause)
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.performSampleRateReconfiguration(countsAsSampleRateChange: countsAsSampleRateChange)
        }
        reconfigurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: workItem)
    }

    private func performSampleRateReconfiguration(countsAsSampleRateChange: Bool) {
        guard lifecycle.state == .reconfiguring else { return }
        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                beginOutputRecovery()
                return
            }
            detachAudioUnitRackIfIncompatible(with: output)
            if lowLatencyRestorePending { restoreLowLatencyBuffers() }
            try buildTransport(output: output)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            try syncMasterVolumeMonitorToSelectedOutput()
            if countsAsSampleRateChange { sampleRateChangesHandled &+= 1 }
            reconfigurationWorkItem = nil
            try setLifecycle(.running)
            lastErrorDescription = nil
            requestAudioUnitRackRebuildIfPending()
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
        }
    }

    private func beginOutputRecovery() {
        guard lifecycle.state == .running || lifecycle.state == .reconfiguring else { return }
        recoveryGeneration &+= 1
        recoveryConsecutiveBuildFailures = 0
        let generation = recoveryGeneration
        try? setLifecycle(.recoveringOutput)
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        tearDownTransport(fadeOut: false, cause: .outputLost)
        scheduleRecoveryAttempt(
            generation: generation,
            delay: OutputRecoveryRetryPolicy.absentOutputPollInterval
        )
    }

    private func scheduleRecoveryAttempt(generation: UInt64, delay: TimeInterval) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.performRecoveryAttempt(generation: generation) }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performRecoveryAttempt(generation: UInt64) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryAttempts &+= 1

        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                lastErrorDescription = "Waiting for selected output to return."
                scheduleRecoveryAttempt(
                    generation: generation,
                    delay: OutputRecoveryRetryPolicy.absentOutputPollInterval
                )
                return
            }

            do {
                detachAudioUnitRackIfIncompatible(with: output)
                try buildTransport(output: output)
                try eventMonitor.monitorSampleRate(of: output.deviceID)
                try syncMasterVolumeMonitorToSelectedOutput()
                recoverySuccesses &+= 1
                recoveryConsecutiveBuildFailures = 0
                try setLifecycle(.running)
                lastErrorDescription = nil
                recoveryWorkItem = nil
                requestAudioUnitRackRebuildIfPending()
                return
            } catch {
                recoveryFailures &+= 1
                recoveryConsecutiveBuildFailures += 1
                tearDownTransport(fadeOut: false)
                if OutputRecoveryRetryPolicy.shouldFail(
                    afterConsecutiveFailures: recoveryConsecutiveBuildFailures
                ) {
                    recoveryWorkItem = nil
                    forceFailedState(error)
                    return
                }
                lastErrorDescription = "Selected output is present but not ready yet: \(error.localizedDescription)"
                scheduleRecoveryAttempt(
                    generation: generation,
                    delay: OutputRecoveryRetryPolicy.buildRetryDelay(
                        afterConsecutiveFailures: recoveryConsecutiveBuildFailures
                    )
                )
                return
            }
        } catch {
            lastErrorDescription = error.localizedDescription
        }

        scheduleRecoveryAttempt(
            generation: generation,
            delay: OutputRecoveryRetryPolicy.absentOutputPollInterval
        )
    }

    private func handleWillSleep() {
        guard lifecycle.state == .running else {
            resumeAfterWake = false
            return
        }
        resumeAfterWake = true
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        masterVolumeController.stopMonitoring()
        try? setLifecycle(.stopping)
        tearDownTransport(fadeOut: true, cause: .sleep)
        try? setLifecycle(.idle)
    }

    private func handleDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        guard lifecycle.state == .idle else { return }
        // USB and Thunderbolt outputs often re-enumerate after didWake. Wait for
        // the same output UID through the recovery loop instead of making one
        // start attempt that leaves processing stopped if the device is late.
        recoveryGeneration &+= 1
        recoveryConsecutiveBuildFailures = 0
        do {
            try setLifecycle(.recoveringOutput)
        } catch {
            lastErrorDescription = error.localizedDescription
            return
        }
        scheduleRecoveryAttempt(generation: recoveryGeneration, delay: 0)
    }
}
