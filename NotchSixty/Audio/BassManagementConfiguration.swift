import Observation
import CoreAudio
import Foundation

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
