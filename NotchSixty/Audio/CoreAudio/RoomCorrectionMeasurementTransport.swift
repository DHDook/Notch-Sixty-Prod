import CoreAudio
import Foundation

enum RoomCorrectionMeasurementError: Error, LocalizedError, Equatable {
    case invalidSampleRate(Double)
    case invalidFrequencyRange(start: Double, end: Double, sampleRate: Double)
    case invalidDuration(Double)
    case invalidLevel(Double)
    case invalidTiming
    case invalidFade(Double)
    case frameCountOverflow
    case invalidTransition(from: RoomCorrectionCalibrationState, to: RoomCorrectionCalibrationState)
    case invalidPassSequence

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let value):
            return "Room measurement sample rate \(value) Hz is invalid."
        case .invalidFrequencyRange(let start, let end, let sampleRate):
            return "Room measurement sweep \(start)...\(end) Hz is invalid at \(sampleRate) Hz."
        case .invalidDuration(let value):
            return "Room measurement sweep duration \(value) seconds is invalid."
        case .invalidLevel(let value):
            return "Room measurement sweep level \(value) dBFS is invalid."
        case .invalidTiming:
            return "Room measurement lead-in/tail timing is invalid."
        case .invalidFade(let value):
            return "Room measurement fade duration \(value) seconds is invalid."
        case .frameCountOverflow:
            return "Room measurement frame count exceeds the supported integer range."
        case .invalidTransition(let from, let to):
            return "Room measurement calibration cannot transition from \(from.rawValue) to \(to.rawValue)."
        case .invalidPassSequence:
            return "Room measurement left/right pass sequence is invalid."
        }
    }
}

enum RoomCorrectionMeasurementPass: String, Codable, CaseIterable, Sendable {
    case left
    case right
}

struct RoomCorrectionSweepProgram: Equatable, Sendable {
    let settings: RoomCorrectionSweepSettings
    let leadInFrames: Int
    let sweepFrames: Int
    let tailFrames: Int
    let sweepSamples: [Float]
    let inverseFilter: [Float]

    var captureFrameCount: Int { leadInFrames + sweepFrames + tailFrames }
    var sweepStartFrame: Int { leadInFrames }
    var sweepEndFrame: Int { leadInFrames + sweepFrames }

    init(settings: RoomCorrectionSweepSettings) throws {
        guard settings.sampleRate.isFinite, settings.sampleRate > 0 else {
            throw RoomCorrectionMeasurementError.invalidSampleRate(settings.sampleRate)
        }
        let nyquistSafetyLimit = settings.sampleRate * 0.49
        guard settings.startFrequencyHz.isFinite,
              settings.startFrequencyHz > 0,
              settings.endFrequencyHz.isFinite,
              settings.endFrequencyHz > settings.startFrequencyHz,
              settings.endFrequencyHz <= nyquistSafetyLimit else {
            throw RoomCorrectionMeasurementError.invalidFrequencyRange(
                start: settings.startFrequencyHz,
                end: settings.endFrequencyHz,
                sampleRate: settings.sampleRate
            )
        }
        guard settings.durationSeconds.isFinite, settings.durationSeconds > 0 else {
            throw RoomCorrectionMeasurementError.invalidDuration(settings.durationSeconds)
        }
        guard settings.levelDBFS.isFinite, settings.levelDBFS <= 0 else {
            throw RoomCorrectionMeasurementError.invalidLevel(settings.levelDBFS)
        }
        guard settings.leadInSeconds.isFinite,
              settings.leadInSeconds >= 0,
              settings.tailSeconds.isFinite,
              settings.tailSeconds >= 0 else {
            throw RoomCorrectionMeasurementError.invalidTiming
        }
        guard settings.fadeSeconds.isFinite,
              settings.fadeSeconds >= 0,
              settings.fadeSeconds * 2 <= settings.durationSeconds else {
            throw RoomCorrectionMeasurementError.invalidFade(settings.fadeSeconds)
        }

        func checkedFrameCount(_ seconds: Double) throws -> Int {
            let frames = seconds * settings.sampleRate
            guard frames.isFinite,
                  frames >= 0,
                  frames <= Double(Int.max) else {
                throw RoomCorrectionMeasurementError.frameCountOverflow
            }
            return Int(frames.rounded())
        }

        let leadInFrames = try checkedFrameCount(settings.leadInSeconds)
        let sweepFrames = try checkedFrameCount(settings.durationSeconds)
        let tailFrames = try checkedFrameCount(settings.tailSeconds)
        guard sweepFrames >= 2,
              leadInFrames <= Int.max - sweepFrames,
              leadInFrames + sweepFrames <= Int.max - tailFrames else {
            throw RoomCorrectionMeasurementError.frameCountOverflow
        }

        let amplitude = pow(10.0, settings.levelDBFS / 20.0)
        let duration = Double(sweepFrames) / settings.sampleRate
        let ratio = settings.endFrequencyHz / settings.startFrequencyHz
        let logRatio = log(ratio)
        let timeConstant = duration / logRatio
        let angularScale = 2.0 * Double.pi * settings.startFrequencyHz * timeConstant
        let fadeFrames = min(try checkedFrameCount(settings.fadeSeconds), sweepFrames / 2)

        var sweep = [Float](repeating: 0, count: sweepFrames)
        for frame in 0..<sweepFrames {
            let time = Double(frame) / settings.sampleRate
            let phase = angularScale * (exp(time / timeConstant) - 1.0)
            var envelope = 1.0
            if fadeFrames > 0 {
                if frame < fadeFrames {
                    let normalized = Double(frame + 1) / Double(fadeFrames)
                    envelope *= 0.5 - 0.5 * cos(Double.pi * normalized)
                }
                let framesFromEnd = sweepFrames - frame
                if framesFromEnd <= fadeFrames {
                    let normalized = Double(framesFromEnd) / Double(fadeFrames)
                    envelope *= 0.5 - 0.5 * cos(Double.pi * normalized)
                }
            }
            sweep[frame] = Float(amplitude * envelope * sin(phase))
        }

        // An ESS inverse is the time-reversed excitation with an exponential
        // amplitude correction. This compensates the sweep's logarithmic energy
        // distribution while keeping the implementation independent of the
        // realtime callback. A later analysis slice normalizes the recovered IR.
        var inverse = [Float](repeating: 0, count: sweepFrames)
        for frame in 0..<sweepFrames {
            let reverseIndex = sweepFrames - 1 - frame
            let time = Double(frame) / settings.sampleRate
            let compensation = exp(-time / timeConstant)
            inverse[frame] = Float(Double(sweep[reverseIndex]) * compensation)
        }

        self.settings = settings
        self.leadInFrames = leadInFrames
        self.sweepFrames = sweepFrames
        self.tailFrames = tailFrames
        self.sweepSamples = sweep
        self.inverseFilter = inverse
    }

    func excitationSample(atCaptureFrame frame: Int) -> Float {
        let sweepIndex = frame - leadInFrames
        guard sweepIndex >= 0, sweepIndex < sweepSamples.count else { return 0 }
        return sweepSamples[sweepIndex]
    }

    /// Writes a bounded slice into already-allocated stereo output buffers.
    /// The non-selected channel is always zeroed. No allocation occurs here.
    @discardableResult
    func writeOutput(
        pass: RoomCorrectionMeasurementPass,
        startCaptureFrame: Int,
        left: UnsafeMutableBufferPointer<Float>,
        right: UnsafeMutableBufferPointer<Float>
    ) -> Int {
        let count = min(left.count, right.count)
        guard count > 0 else { return 0 }
        var written = 0
        for offset in 0..<count {
            let frame = startCaptureFrame + offset
            guard frame >= 0, frame < captureFrameCount else {
                left[offset] = 0
                right[offset] = 0
                continue
            }
            let sample = excitationSample(atCaptureFrame: frame)
            switch pass {
            case .left:
                left[offset] = sample
                right[offset] = 0
            case .right:
                left[offset] = 0
                right[offset] = sample
            }
            written += 1
        }
        return written
    }
}

/// Fixed-capacity single-writer buffer for the calibration IOProc.
/// Allocate/reset on the control plane; write only from the calibration callback;
/// materialize only after the callback has stopped writing.
final class RoomCorrectionCaptureBuffer: @unchecked Sendable {
    let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private(set) var writtenFrames: Int = 0

    init(capacityFrames: Int) throws {
        guard capacityFrames > 0 else {
            throw RoomCorrectionMeasurementError.frameCountOverflow
        }
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
    }

    deinit {
        storage.deinitialize(count: capacityFrames)
        storage.deallocate()
    }

    var remainingFrames: Int { capacityFrames - writtenFrames }
    var isComplete: Bool { writtenFrames == capacityFrames }

    func reset() {
        storage.update(repeating: 0, count: capacityFrames)
        writtenFrames = 0
    }

    @discardableResult
    func write(from source: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0, writtenFrames < capacityFrames else { return 0 }
        let count = min(frameCount, remainingFrames)
        storage.advanced(by: writtenFrames).update(from: source, count: count)
        writtenFrames += count
        return count
    }

    func materialize() -> [Float] {
        Array(UnsafeBufferPointer(start: storage, count: writtenFrames))
    }
}

enum RoomCorrectionCalibrationState: String, Codable, Sendable {
    case idle
    case requestingPermission
    case enumeratingInputs
    case ready
    case arming
    case measuring
    case analyzing
    case reviewing
    case designing
    case deploying
    case failed
}

struct RoomCorrectionCalibrationStateMachine: Sendable {
    private(set) var state: RoomCorrectionCalibrationState = .idle

    mutating func transition(to next: RoomCorrectionCalibrationState) throws {
        guard Self.canTransition(from: state, to: next) else {
            throw RoomCorrectionMeasurementError.invalidTransition(from: state, to: next)
        }
        state = next
    }

    mutating func cancelToIdle() {
        state = .idle
    }

    mutating func fail() {
        state = .failed
    }

    static func canTransition(
        from: RoomCorrectionCalibrationState,
        to: RoomCorrectionCalibrationState
    ) -> Bool {
        if to == .failed { return from != .idle && from != .failed }
        switch (from, to) {
        case (.idle, .requestingPermission),
             (.idle, .enumeratingInputs),
             (.idle, .ready),
             (.requestingPermission, .enumeratingInputs),
             (.requestingPermission, .ready),
             (.enumeratingInputs, .ready),
             (.ready, .arming),
             (.arming, .measuring),
             (.measuring, .analyzing),
             (.analyzing, .reviewing),
             (.reviewing, .arming),
             (.reviewing, .designing),
             (.designing, .reviewing),
             (.designing, .deploying),
             (.deploying, .reviewing),
             (.failed, .idle):
            return true
        default:
            return false
        }
    }
}

struct RoomCorrectionMeasurementRunState: Equatable, Sendable {
    private(set) var activePass: RoomCorrectionMeasurementPass?
    private(set) var completedPasses: [RoomCorrectionMeasurementPass] = []

    mutating func begin(_ pass: RoomCorrectionMeasurementPass) throws {
        guard activePass == nil else { throw RoomCorrectionMeasurementError.invalidPassSequence }
        switch pass {
        case .left:
            guard completedPasses.isEmpty else {
                throw RoomCorrectionMeasurementError.invalidPassSequence
            }
        case .right:
            guard completedPasses == [.left] else {
                throw RoomCorrectionMeasurementError.invalidPassSequence
            }
        }
        activePass = pass
    }

    mutating func completeActivePass() throws {
        guard let activePass else { throw RoomCorrectionMeasurementError.invalidPassSequence }
        completedPasses.append(activePass)
        self.activePass = nil
    }

    mutating func reset() {
        activePass = nil
        completedPasses.removeAll(keepingCapacity: true)
    }

    var isComplete: Bool { activePass == nil && completedPasses == [.left, .right] }
}

enum RoomCorrectionCalibrationTopology: Equatable, Sendable {
    case direct(deviceID: AudioDeviceID)
    case aggregate(outputDeviceID: AudioDeviceID, inputDeviceID: AudioDeviceID, driftCompensateInput: Bool)
}

enum RoomCorrectionCalibrationTopologyPlanner {
    static func topology(
        output: AudioOutputDevice,
        input: AudioInputDevice
    ) -> RoomCorrectionCalibrationTopology {
        if output.deviceID == input.deviceID {
            return .direct(deviceID: output.deviceID)
        }
        return .aggregate(
            outputDeviceID: output.deviceID,
            inputDeviceID: input.deviceID,
            driftCompensateInput: true
        )
    }
}
