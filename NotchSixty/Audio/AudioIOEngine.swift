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
    private let deviceCatalog: any OutputDeviceCataloging
    private let eventMonitor: AudioHardwareEventMonitor
    private let masterVolumeController: any MasterVolumeDeviceControlling
    private let globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring
    private let binauralProfileAssetStore: BinauralProfileAssetStore
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
    private(set) var softwareVolumeKeyStepDenominator: Int = 16
    @Published private(set) var gainConfiguration = DSPGainConfiguration()
    @Published private(set) var bassManagementConfiguration = BassManagementConfiguration()
    @Published private(set) var multiOutputRoutingConfiguration: MultiOutputRoutingConfiguration?
    @Published private(set) var outputDeviceProfileConfiguration: OutputDeviceProfileConfiguration?
    @Published private(set) var headphoneDeviceProfileConfiguration: HeadphoneDeviceProfileConfiguration?
    @Published private(set) var speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()
    @Published private(set) var dynamicsConfiguration = DynamicsConfiguration()
    @Published private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()
    @Published private(set) var speakerIRConfiguration = SpeakerIRConfiguration()
    @Published private(set) var linearPhaseDesignInfo: N60LinearPhaseEQDesignInfo?
    @Published private(set) var headTrackingRuntimeStatus = HeadTrackingRuntimeStatus.disabled
    @Published private(set) var lastErrorDescription: String?
    @Published private(set) var lifecycleState: AudioLifecycleState

    init(
        deviceCatalog: any OutputDeviceCataloging = CoreAudioOutputDeviceCatalog(),
        initialRouteConfiguration: AudioRouteConfiguration = AudioRouteConfiguration(),
        eventMonitor: AudioHardwareEventMonitor = AudioHardwareEventMonitor(),
        masterVolumeController: any MasterVolumeDeviceControlling = CoreAudioMasterVolumeController(),
        globalVolumeKeyMonitor: any GlobalVolumeKeyMonitoring = CoreGraphicsGlobalVolumeKeyMonitor(),
        binauralProfileAssetStore: BinauralProfileAssetStore = BinauralProfileAssetStore()
    ) {
        self.deviceCatalog = deviceCatalog
        self.routeConfiguration = initialRouteConfiguration
        self.eventMonitor = eventMonitor
        self.masterVolumeController = masterVolumeController
        self.globalVolumeKeyMonitor = globalVolumeKeyMonitor
        self.binauralProfileAssetStore = binauralProfileAssetStore
        let lifecycle = AudioLifecycleStateMachine()
        self.lifecycle = lifecycle
        self.lifecycleState = lifecycle.state

        eventMonitor.onDeviceListChanged = { [weak self] in self?.handleDeviceListChanged() }
        eventMonitor.onSelectedOutputSampleRateChanged = { [weak self] in self?.scheduleSampleRateReconfiguration() }
        eventMonitor.onWillSleep = { [weak self] in self?.handleWillSleep() }
        eventMonitor.onDidWake = { [weak self] in self?.handleDidWake() }
        masterVolumeController.onExternalChange = { [weak self] in self?.handleMasterVolumeDeviceChange() }
        globalVolumeKeyMonitor.onVolumeIncrement = { [weak self] in self?.handleGlobalVolumeKey(direction: 1.0) }
        globalVolumeKeyMonitor.onVolumeDecrement = { [weak self] in self?.handleGlobalVolumeKey(direction: -1.0) }
    }

    var physicalSpeakerBusRoutingActive: Bool {
        guard let routing = multiOutputRoutingConfiguration, routing.enabled else { return false }
        return routing.enabledRoutes.contains { !$0.bus.isFullRangeBus }
    }

    var liveNChannelActive: Bool { nChannelTransportSession != nil }
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

        let channelCount: Int
        if let headphone = headphoneDeviceProfileConfiguration,
           headphone.enabled,
           headphone.spatialMode == .virtualSpeakers {
            channelCount = headphone.programLayout.roles.count
        } else if let profile = outputDeviceProfileConfiguration,
                  profile.enabled {
            channelCount = profile.programLayout.roles.count
        } else {
            channelCount = 2
        }

        let format = AudioUnitRackProcessingFormat(
            sampleRate: output.nominalSampleRate,
            channelCount: channelCount,
            maximumFramesPerSlice: 4_096
        )
        try format.validate()
        return format
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
            let channelCount: Int
            if let headphone = headphoneDeviceProfileConfiguration,
               headphone.enabled,
               headphone.spatialMode == .virtualSpeakers {
                channelCount = headphone.programLayout.roles.count
            } else if let profile = outputDeviceProfileConfiguration,
                      profile.enabled {
                channelCount = profile.programLayout.roles.count
            } else {
                channelCount = 2
            }
            let format = AudioUnitRackProcessingFormat(
                sampleRate: output.nominalSampleRate,
                channelCount: channelCount,
                maximumFramesPerSlice: 4_096
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

    func setSoftwareVolumeKeyStepDenominator(_ denominator: Int) {
        guard denominator == 16 || denominator == 32 || denominator == 64 else { return }
        softwareVolumeKeyStepDenominator = denominator
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

    func setInputPreampDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.inputPreampRange.contains(value) else {
            throw DSPGainConfigurationError.invalidInputPreamp(value)
        }
        var updated = gainConfiguration
        updated.inputPreampDB = value
        try applyGainConfiguration(updated)
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
        guard lifecycle.state == .idle || configuration == headphoneDeviceProfileConfiguration else {
            throw HeadphoneDeviceProfileError.configurationChangeRequiresRestart
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
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        if physicalSpeakerBusRoutingActive, lifecycle.state != .idle, configuration != bassManagementConfiguration {
            throw BassManagementConfigurationError.physicalCrossoverChangeRequiresIdle
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
        if immutableSemanticTransportActive, configuration != dynamicsConfiguration {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        let validationRate = transportSession?.outputFormat.sampleRate
            ?? nChannelTransportSession?.outputFormat.sampleRate
            ?? 48_000
        _ = try configuration.makeSnapshot(sampleRate: validationRate)
        let newProtection = try configuration.makeProtectionSnapshot(sampleRate: validationRate)
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
        tearDownTransport(fadeOut: true)
        try? setLifecycle(.idle)
        clearStagedAudioUnitRack()
    }

    func shutdownForTermination() {
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .idle {
            if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
            tearDownTransport(fadeOut: true)
            try? setLifecycle(.idle)
        }
        if lifecycle.state == .idle {
            clearStagedAudioUnitRack()
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
            renderKernelDiagnostics: transportSession?.renderDiagnostics(),
            startupGateOpened: startupGateOpened,
            startupGateTargetFrames: startupGateTargetFrames,
            startupGateActivationFrames: startupGateActivationFrames,
            sampleRateChangesHandled: sampleRateChangesHandled,
            recoveryAttempts: recoveryAttempts,
            recoverySuccesses: recoverySuccesses,
            recoveryFailures: recoveryFailures,
            lastErrorDescription: lastErrorDescription
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
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
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
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
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
        lastErrorDescription = nil
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
        if snapshot.capabilities.controlMode == .device, let level = snapshot.level {
            updated.level = min(max(level, 0), 1)
        }
        if snapshot.capabilities.usesDeviceMute, let muted = snapshot.muted {
            updated.muted = muted
        }

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
        let delta = direction / Double(softwareVolumeKeyStepDenominator)
        let level = min(
            max(masterVolumeConfiguration.level + delta, MasterVolumeConfiguration.levelRange.lowerBound),
            MasterVolumeConfiguration.levelRange.upperBound
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
        if immutableSemanticTransportActive, configuration != gainConfiguration {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
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
            try session.publishDSPGraph(graph)
        }
        gainConfiguration = configuration
        lastErrorDescription = nil
    }

    private func applyRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        if immutableSemanticTransportActive, configuration != roomCorrectionConfiguration {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        if configuration.enabled && configuration.filter == nil {
            throw RoomCorrectionConfigurationError.filterRequired
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
        if immutableSemanticTransportActive, configuration != speakerIRConfiguration {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        if configuration.enabled && configuration.filter == nil {
            throw SpeakerIRConfigurationError.filterRequired
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

    private func prepareEQFIRProgram(
        _ configuration: StereoEQConfiguration,
        for session: CoreAudioTransportSession
    ) throws -> PreparedEQFIRProgram {
        let sampleRate = session.outputFormat.sampleRate
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

        let slot = nextEQFIRProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareConvolutionProgram(
                slot: slot,
                leftTaps: primary.taps,
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

    private func validateRoomCorrectionFilter(
        _ filter: RoomCorrectionFilter,
        outputSampleRate: Double
    ) throws {
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
        _ filter: RoomCorrectionFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedRoomCorrectionProgram {
        try validateRoomCorrectionFilter(filter, outputSampleRate: session.outputFormat.sampleRate)

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

    private func applyAudioUnitRackLatency(
        to graph: inout N60DSPGraphSnapshot
    ) throws {
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
        if outputDeviceProfileConfiguration?.enabled == true {
            try buildNChannelTransport(output: output)
            return
        }
        try buildStereoTransport(output: output)
    }

    private func validateLiveNChannelActivation() throws {
        if multiOutputRoutingConfiguration?.enabled == true {
            throw OutputDeviceProfileError.legacyPhysicalRoutingConflict
        }
        if !speakerDriverProcessingConfiguration.isNeutral {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy per-driver speaker processing")
        }
        if !stereoEQConfiguration.bypassed {
            if stereoEQConfiguration.channelMode != .linked
                || stereoEQConfiguration.phaseMode != .minimumPhase
                || stereoEQConfiguration.enabledBandCount != 0 {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo EQ")
            }
        }
        if playbackControlConfiguration != PlaybackControlConfiguration() {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo playback/image controls")
        }
        if dynamicsConfiguration != DynamicsConfiguration() {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo dynamics/protection")
        }
        if roomCorrectionConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo room correction")
        }
        if speakerIRConfiguration.enabled {
            throw LiveNChannelTransportError.unsupportedActiveDSP("legacy stereo Speaker IR")
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
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: routePlan,
            sampleRate: output.nominalSampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        )
        let session = try CoreAudioNChannelTransportSession(
            selectedOutput: output,
            routePlan: routePlan,
            renderGraph: graph,
            outputGain: currentMasterSoftwareGain,
            roomTreatment: stagedRoomTreatment,
            audioUnitRack: stagedAudioUnitRack
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
        if !stereoEQConfiguration.bypassed {
            if stereoEQConfiguration.channelMode != .linked
                || stereoEQConfiguration.phaseMode != .minimumPhase
                || stereoEQConfiguration.enabledBandCount != 0 {
                throw LiveNChannelTransportError.unsupportedActiveDSP("stereo EQ in Virtual Speakers mode")
            }
        }
        if playbackControlConfiguration != PlaybackControlConfiguration() {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo playback/image controls in Virtual Speakers mode")
        }
        if dynamicsConfiguration != DynamicsConfiguration() {
            throw LiveNChannelTransportError.unsupportedActiveDSP("stereo dynamics in Virtual Speakers mode")
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
        let asset = try binauralProfileAssetStore.load(id: reference.assetID)
        guard asset.id == reference.assetID,
              abs(asset.sampleRate - reference.sampleRate) < 0.5,
              asset.tapCount == reference.tapCount else {
            throw HeadphoneDeviceProfileError.invalidBinauralProfileReference
        }
        let prepared = try asset.prepare(for: profile.programLayout)
        let headphoneSnapshot = try profile.makeRealtimeSnapshot(
            sampleRate: output.nominalSampleRate
        )
        let combinedGainDB = gainConfiguration.inputPreampDB
            + gainConfiguration.headroomAttenuationDB
            + gainConfiguration.outputGainDB
        let programGain = DSPGainConfiguration.linearGain(forDB: combinedGainDB)
        guard programGain.isFinite, programGain >= 0, programGain <= 16 else {
            throw BinauralHeadphoneTransportError.bridgeAllocationFailed
        }
        let session = try CoreAudioBinauralHeadphoneTransportSession(
            selectedOutput: output,
            programSource: source,
            programLayout: profile.programLayout,
            preparedProfile: prepared,
            headphoneSnapshot: headphoneSnapshot,
            programGain: programGain,
            outputGain: currentMasterSoftwareGain,
            audioUnitRack: stagedAudioUnitRack
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
        try session.configureHeadphoneDSP(headphoneSnapshot)
        activeEQFIRProgram = nil
        nextEQFIRProgramSlot = 0
        activeRoomCorrectionProgram = nil
        nextRoomCorrectionProgramSlot = 0
        activeSpeakerIRProgram = nil
        nextSpeakerIRProgramSlot = 0
        var graph = try stereoEQConfiguration.makeGraphSnapshot(
            sampleRate: session.outputFormat.sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: renderBassManagementConfiguration(),
            dynamicsConfiguration: dynamicsConfiguration,
            playbackConfiguration: playbackControlConfiguration
        )

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

    private func tearDownTransport(fadeOut: Bool) {
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

        if selectedIsPresent && lifecycle.state == .recoveringOutput {
            scheduleRecoveryAttempt(generation: recoveryGeneration, delay: 0)
        }
    }

    private func scheduleSampleRateReconfiguration() {
        guard lifecycle.state == .running else { return }

        reconfigurationWorkItem?.cancel()
        do {
            try setLifecycle(.reconfiguring)
            eventMonitor.removeSelectedOutputSampleRateMonitor()
            tearDownTransport(fadeOut: false)
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in self?.performSampleRateReconfiguration() }
        reconfigurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func performSampleRateReconfiguration() {
        guard lifecycle.state == .reconfiguring else { return }
        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                beginOutputRecovery()
                return
            }
            try buildTransport(output: output)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            try syncMasterVolumeMonitorToSelectedOutput()
            sampleRateChangesHandled &+= 1
            reconfigurationWorkItem = nil
            try setLifecycle(.running)
            lastErrorDescription = nil
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
        }
    }

    private func beginOutputRecovery() {
        guard lifecycle.state == .running || lifecycle.state == .reconfiguring else { return }
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        try? setLifecycle(.recoveringOutput)
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        tearDownTransport(fadeOut: false)
        scheduleRecoveryAttempt(generation: generation, delay: 0.5)
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
                scheduleRecoveryAttempt(generation: generation, delay: 0.5)
                return
            }

            do {
                try buildTransport(output: output)
                try eventMonitor.monitorSampleRate(of: output.deviceID)
                try syncMasterVolumeMonitorToSelectedOutput()
                recoverySuccesses &+= 1
                try setLifecycle(.running)
                lastErrorDescription = nil
                recoveryWorkItem = nil
                return
            } catch {
                recoveryFailures &+= 1
                lastErrorDescription = "Selected output is present but not ready yet: \(error.localizedDescription)"
                tearDownTransport(fadeOut: false)
            }
        } catch {
            lastErrorDescription = error.localizedDescription
        }

        scheduleRecoveryAttempt(generation: generation, delay: 0.5)
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
        tearDownTransport(fadeOut: true)
        try? setLifecycle(.idle)
    }

    private func handleDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        do {
            try start(resetProcessingSessionCounters: false)
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
