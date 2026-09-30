import CoreAudio

struct AudioSampleRateRange: Equatable, Hashable, Sendable {
    let minimum: Double
    let maximum: Double

    init(minimum: Double, maximum: Double) {
        self.minimum = Swift.min(minimum, maximum)
        self.maximum = Swift.max(minimum, maximum)
    }

    func contains(_ sampleRate: Double) -> Bool {
        sampleRate >= minimum && sampleRate <= maximum
    }
}

struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    typealias ID = String

    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let nominalSampleRate: Double
    let availableSampleRateRanges: [AudioSampleRateRange]

    var id: String { uid }

    func supports(sampleRate: Double) -> Bool {
        availableSampleRateRanges.contains { $0.contains(sampleRate) }
    }
}

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    typealias ID = String

    let deviceID: AudioDeviceID
    let uid: String
    let name: String
    let nominalSampleRate: Double
    let availableSampleRateRanges: [AudioSampleRateRange]

    var id: String { uid }

    func supports(sampleRate: Double) -> Bool {
        availableSampleRateRanges.contains { $0.contains(sampleRate) }
    }
}

// MARK: - Room Correction Calibration Session

enum RoomCorrectionCalibrationState: String, Codable, Equatable, Sendable {
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

enum RoomCorrectionCalibrationSessionError: Error, Equatable, LocalizedError {
    case invalidTransition(from: RoomCorrectionCalibrationState, to: RoomCorrectionCalibrationState)
    case invalidCaptureCapacity(Int)
    case captureNotComplete

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "Room correction calibration cannot transition from \(from.rawValue) to \(to.rawValue)."
        case .invalidCaptureCapacity(let capacity):
            return "Room correction capture capacity \(capacity) frames is invalid."
        case .captureNotComplete:
            return "Room correction capture is not complete yet."
        }
    }
}

struct RoomCorrectionCalibrationStateMachine: Sendable {
    private(set) var state: RoomCorrectionCalibrationState = .idle

    mutating func transition(to next: RoomCorrectionCalibrationState) throws {
        guard Self.canTransition(from: state, to: next) else {
            throw RoomCorrectionCalibrationSessionError.invalidTransition(from: state, to: next)
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
        if to == .failed {
            return from != .idle && from != .failed
        }
        switch (from, to) {
        case (.idle, .requestingPermission),
             (.idle, .enumeratingInputs),
             (.idle, .ready),
             (.requestingPermission, .enumeratingInputs),
             (.requestingPermission, .ready),
             (.enumeratingInputs, .ready),
             (.ready, .arming),
             (.ready, .designing),
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

enum RoomCorrectionCalibrationTopology: Equatable, Sendable {
    case direct(deviceID: AudioDeviceID)
    case privateAggregate(
        outputDeviceID: AudioDeviceID,
        inputDeviceID: AudioDeviceID,
        driftCompensateInput: Bool
    )
}

enum RoomCorrectionCalibrationTopologyPlanner {
    static func topology(
        output: AudioOutputDevice,
        input: AudioInputDevice
    ) -> RoomCorrectionCalibrationTopology {
        if output.deviceID == input.deviceID {
            return .direct(deviceID: output.deviceID)
        }
        return .privateAggregate(
            outputDeviceID: output.deviceID,
            inputDeviceID: input.deviceID,
            driftCompensateInput: true
        )
    }
}

/// Preallocated single-writer storage for one microphone capture pass.
/// The calibration IOProc is the only writer. Control-plane materialization is
/// allowed only after measurement has stopped, so the realtime path needs no
/// lock, allocation, or copy-on-write mutation.
final class RoomCorrectionCaptureBuffer: @unchecked Sendable {
    let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private(set) var writtenFrames = 0

    init(capacityFrames: Int) throws {
        guard capacityFrames > 0 else {
            throw RoomCorrectionCalibrationSessionError.invalidCaptureCapacity(capacityFrames)
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

    func write(_ sample: Float, at frame: Int) {
        guard frame >= 0, frame < capacityFrames else { return }
        storage[frame] = sample
        if frame >= writtenFrames {
            writtenFrames = frame + 1
        }
    }

    func materialize(requireComplete: Bool = true) throws -> [Float] {
        if requireComplete, !isComplete {
            throw RoomCorrectionCalibrationSessionError.captureNotComplete
        }
        return Array(UnsafeBufferPointer(start: storage, count: writtenFrames))
    }
}

/// Allocation-free sample-domain executor for one paired L/R listening-position
/// measurement. It consumes the immutable plan prepared on the control plane,
/// writes only to caller-owned output buffers, and captures microphone samples
/// into two fixed-capacity buffers.
final class RoomCorrectionMeasurementRealtimeSession: @unchecked Sendable {
    let plan: RoomCorrectionMeasurementPlan
    let leftCapture: RoomCorrectionCaptureBuffer
    let rightCapture: RoomCorrectionCaptureBuffer
    private(set) var frameCursor = 0

    init(plan: RoomCorrectionMeasurementPlan) throws {
        self.plan = plan
        leftCapture = try RoomCorrectionCaptureBuffer(capacityFrames: plan.leftPass.captureFrameCount)
        rightCapture = try RoomCorrectionCaptureBuffer(capacityFrames: plan.rightPass.captureFrameCount)
    }

    var isComplete: Bool {
        frameCursor >= plan.totalFrameCount && leftCapture.isComplete && rightCapture.isComplete
    }

    func reset() {
        frameCursor = 0
        leftCapture.reset()
        rightCapture.reset()
    }

    /// Processes one synchronous input/output callback quantum.
    /// Returns the number of timeline frames consumed from the plan. Any output
    /// frames beyond completion are explicitly zeroed.
    @discardableResult
    func process(
        microphone: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Int {
        guard frameCount > 0 else { return 0 }

        let remaining = max(plan.totalFrameCount - frameCursor, 0)
        let consumed = min(frameCount, remaining)

        for offset in 0..<consumed {
            let timelineFrame = frameCursor + offset
            let output = plan.outputFrame(at: timelineFrame)
            outputLeft[offset] = output.left
            outputRight[offset] = output.right

            if let destination = plan.captureDestination(at: timelineFrame) {
                switch destination.pass {
                case .left:
                    leftCapture.write(microphone[offset], at: destination.frameIndex)
                case .right:
                    rightCapture.write(microphone[offset], at: destination.frameIndex)
                }
            }
        }

        if consumed < frameCount {
            for offset in consumed..<frameCount {
                outputLeft[offset] = 0
                outputRight[offset] = 0
            }
        }

        frameCursor += consumed
        return consumed
    }
}
