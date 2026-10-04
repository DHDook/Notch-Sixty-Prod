import Foundation

struct OutputCalibrationEQBand: Codable, Equatable, Sendable {
    static let gainRangeDB = -18.0...0.0
    static let qRange = 0.25...10.0

    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    func validate(sampleRate: Double? = nil) throws {
        guard frequencyHz.isFinite,
              frequencyHz > 0,
              gainDB.isFinite,
              Self.gainRangeDB.contains(gainDB),
              q.isFinite,
              Self.qRange.contains(q) else {
            throw OutputDeviceCalibrationError.invalidEQBand
        }
        if let sampleRate {
            guard sampleRate.isFinite,
                  sampleRate > 0,
                  frequencyHz < sampleRate * 0.5 else {
                throw OutputDeviceCalibrationError.invalidEQBand
            }
        }
    }
}

struct SemanticSpeakerCalibration: Codable, Equatable, Sendable {
    static let trimRangeDB = -24.0...0.0
    static let delayRangeMilliseconds = 0.0...300.0
    static let maximumEQBandCount = Int(N60_SPEAKER_CORRECTION_MAX_BANDS)

    var trimDB: Double = 0
    var delayMilliseconds: Double = 0
    var polarityInverted = false
    var eqBands: [OutputCalibrationEQBand] = []

    func validate(sampleRate: Double? = nil) throws {
        guard trimDB.isFinite,
              Self.trimRangeDB.contains(trimDB),
              delayMilliseconds.isFinite,
              Self.delayRangeMilliseconds.contains(delayMilliseconds),
              eqBands.count <= Self.maximumEQBandCount else {
            throw OutputDeviceCalibrationError.invalidSpeakerCalibration
        }
        for band in eqBands { try band.validate(sampleRate: sampleRate) }
        if let sampleRate {
            let frames = delayMilliseconds * sampleRate / 1_000.0
            guard frames.isFinite,
                  frames <= Double(N60_PROGRAM_LANE_MAX_DELAY_FRAMES) else {
                throw OutputDeviceCalibrationError.invalidSpeakerCalibration
            }
        }
    }
}

struct PhysicalSubwooferCalibration: Codable, Equatable, Sendable {
    static let gainRangeDB = -24.0...0.0
    static let delayRangeMilliseconds = 0.0...300.0
    static let maximumEQBandCount = Int(N60_SUBWOOFER_USER_EQ_SECTIONS)

    var gainDB: Double = 0
    var delayMilliseconds: Double = 0
    var polarityInverted = false
    var eqBands: [OutputCalibrationEQBand] = []

    func validate(sampleRate: Double? = nil) throws {
        guard gainDB.isFinite,
              Self.gainRangeDB.contains(gainDB),
              delayMilliseconds.isFinite,
              Self.delayRangeMilliseconds.contains(delayMilliseconds),
              eqBands.count <= Self.maximumEQBandCount else {
            throw OutputDeviceCalibrationError.invalidSubwooferCalibration
        }
        for band in eqBands { try band.validate(sampleRate: sampleRate) }
        if let sampleRate {
            let frames = delayMilliseconds * sampleRate / 1_000.0
            guard frames.isFinite,
                  frames <= Double(N60_SUBWOOFER_MAX_DELAY_FRAMES) else {
                throw OutputDeviceCalibrationError.invalidSubwooferCalibration
            }
        }
    }
}

struct MultichannelCalibrationDeploymentSummary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var measuredAt: Date
    var deployedAt: Date
    var seatCount: Int
    var speakerCount: Int
    var subwooferCount: Int
    var targetName: String
    var sampleRate: Double
    var maximumSpeakerErrorBeforeDB: Double?
    var maximumSpeakerErrorAfterDB: Double?
    var multiSubObjective: Double?

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              seatCount > 0,
              seatCount <= Int(N60_CALIBRATION_MAX_SEATS),
              speakerCount > 0,
              speakerCount <= Int(N60_MAX_PROGRAM_CHANNELS),
              subwooferCount >= 0,
              subwooferCount <= Int(N60_MAX_SUBWOOFER_OUTPUTS),
              !targetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sampleRate.isFinite,
              sampleRate > 0,
              maximumSpeakerErrorBeforeDB.map({ $0.isFinite && $0 >= 0 }) ?? true,
              maximumSpeakerErrorAfterDB.map({ $0.isFinite && $0 >= 0 }) ?? true,
              multiSubObjective.map({ $0.isFinite && $0 >= 0 }) ?? true else {
            throw OutputDeviceCalibrationError.invalidDeploymentSummary
        }
    }
}

enum OutputDeviceCalibrationError: Error, Equatable, LocalizedError {
    case invalidEQBand
    case invalidSpeakerCalibration
    case invalidSubwooferCalibration
    case invalidDeploymentSummary
    case speakerAssignmentUnavailable(OutputProgramRole)
    case subwooferAssignmentUnavailable(UInt32)
    case profileRequired
    case sampleRateMismatch(expected: Double, actual: Double)
    case designFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEQBand:
            return "Calibration EQ contains an invalid frequency, cut, or Q value."
        case .invalidSpeakerCalibration:
            return "Speaker calibration trim, delay, polarity, or EQ is outside the supported deployment range."
        case .invalidSubwooferCalibration:
            return "Subwoofer calibration gain, delay, polarity, or EQ is outside the supported deployment range."
        case .invalidDeploymentSummary:
            return "Multichannel calibration deployment metadata is invalid."
        case .speakerAssignmentUnavailable(let role):
            return "The Output Device Profile has no physical assignment for \(role.displayName)."
        case .subwooferAssignmentUnavailable(let index):
            return "The Output Device Profile has no physical assignment for Sub \(index + 1)."
        case .profileRequired:
            return "Enable an Output Device Profile before running multichannel calibration."
        case .sampleRateMismatch(let expected, let actual):
            return "Calibration was designed at \(expected) Hz, but the selected output is currently at \(actual) Hz."
        case .designFailed(let reason):
            return "Multichannel calibration design failed: \(reason)"
        }
    }
}
