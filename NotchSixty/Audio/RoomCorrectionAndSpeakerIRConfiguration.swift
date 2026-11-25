import Observation
import CoreAudio
import Foundation

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
    /// E24 S3b: a rate-independent lane-plan correction for the speaker profile's lanes. Exactly one of `filter` and
    /// `lanes` is set when enabled. Absent in older stored profiles, which decode with nil.
    var lanes: RoomCorrectionLaneInstall?
}

enum RoomCorrectionConfigurationError: Error, LocalizedError, Equatable {
    case filterRequired
    case filterAndLanes
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
        case .filterAndLanes:
            return "Room correction carries either a stereo filter or a lane plan, not both."
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
