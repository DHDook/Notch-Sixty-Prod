import CoreAudio
import Foundation

/// A source clock/launch witness supplied by a separately calibrated physical
/// source controller. Ordinary playback commands, UI tap time or a phone timer
/// do not constitute this evidence. The source controller must establish that
/// this host timestamp represents ACOUSTIC emission (not merely enqueue time).
struct QuietZoneInstrumentedSourceLaunch: Sendable {
    var launchID: String
    var sourceFixtureID: String
    var synchronizedClockID: String
    var physicalSourceID: String
    var routeLeaseID: String
    var sampleRate: Double
    var emissionHostSeconds: Double
    var oneSigmaTimingUncertaintySeconds: Double
    var physicalClockCalibrationVerified: Bool
    var emittedProbe: [Float]
}

enum QuietZoneInstrumentedProbeError: Error, Equatable, LocalizedError {
    case incompatibleSource
    case uncalibratedTrigger
    case missingPreRoll
    case incompleteCapture
    case invalidInput
    case discontinuousInput
    case clockMismatch
    case excessiveCapture
    case unusableAudio
    case callbackFault
    case staleRoute
    case alreadyFinished
    case replayedLaunch

    var errorDescription: String? {
        switch self {
        case .incompatibleSource: return "The controlled external source, route or clock identity changed."
        case .uncalibratedTrigger: return "A cross-calibrated physical acoustic emission timestamp is required."
        case .missingPreRoll: return "Begin microphone capture before the external source emits the probe."
        case .incompleteCapture: return "The synchronized probe capture needs sufficient pre- and post-event audio."
        case .invalidInput: return "The microphone capture contained invalid timestamps or samples."
        case .discontinuousInput: return "The microphone sample clock jumped or skipped input frames."
        case .clockMismatch: return "The input and source event timestamps disagree with the calibrated clock."
        case .excessiveCapture: return "The bounded probe capture exceeded its maximum recording length."
        case .unusableAudio: return "The recording is clipped or contains unusable probe audio."
        case .callbackFault: return "The reference input reported dropped frames or a callback fault."
        case .staleRoute: return "The selected physical output session changed during the measurement."
        case .alreadyFinished: return "This probe run was already stopped."
        case .replayedLaunch: return "Each listening position needs a fresh, independent physical source launch."
        }
    }
}

/// Owns only bounded, temporary, non-realtime audio and an exact input sample
/// timeline. The output is a PR96 probe capture, NOT an ANC activation permit.
/// Any source-specific clock attestation is supplied by physical hardware,
/// never synthesized from the microphone recording itself.
struct QuietZoneInstrumentedProbeCollector: Sendable {
    static let maximumFrames = 65_536
    static let minimumFrames = 1_024
    static let minimumPreRollFrames = 96
    static let maximumHostResidualSeconds = 0.002

    let position: QuietZoneFeedForwardPosition
    let microphoneID: String
    let microphoneChannel: Int
    let sourceFixtureID: String
    let synchronizedClockID: String
    let physicalSourceID: String
    let routeLeaseID: String
    let sampleRate: Double

    private(set) var samples: [Float] = []
    private var firstSampleTime: Double?
    private var lastSampleTime: Double?
    private var firstHostSeconds: Double?
    private var lastHostSeconds: Double?

    init(
        position: QuietZoneFeedForwardPosition,
        microphoneID: String, microphoneChannel: Int,
        sourceFixtureID: String, synchronizedClockID: String,
        physicalSourceID: String, routeLeaseID: String,
        sampleRate: Double
    ) throws {
        guard !microphoneID.isEmpty, microphoneChannel >= 0,
              !sourceFixtureID.isEmpty, !synchronizedClockID.isEmpty,
              !physicalSourceID.isEmpty, !routeLeaseID.isEmpty,
              sampleRate.isFinite, (8_000...192_000).contains(sampleRate)
        else { throw QuietZoneInstrumentedProbeError.incompatibleSource }
        self.position = position
        self.microphoneID = microphoneID
        self.microphoneChannel = microphoneChannel
        self.sourceFixtureID = sourceFixtureID
        self.synchronizedClockID = synchronizedClockID
        self.physicalSourceID = physicalSourceID
        self.routeLeaseID = routeLeaseID
        self.sampleRate = sampleRate
        samples.reserveCapacity(Self.maximumFrames)
    }

    /// Off the HAL realtime callback. Reject skipped frames instead of
    /// extrapolating or silently padding them with synthetic samples.
    mutating func append(_ frames: [N60FeedForwardReferenceFrame]) throws {
        guard frames.count <= Self.maximumFrames - samples.count else {
            throw QuietZoneInstrumentedProbeError.excessiveCapture
        }
        for frame in frames {
            let frameNumber = frame.firstFrameSampleTime + Double(frame.frameOffset)
            guard frame.firstFrameHostTime > 0,
                  frameNumber.isFinite, frameNumber >= 0,
                  frame.sample.isFinite else {
                throw QuietZoneInstrumentedProbeError.invalidInput
            }
            guard abs(frame.sample) < 0.99 else {
                throw QuietZoneInstrumentedProbeError.unusableAudio
            }
            let callbackHost = Double(
                AudioConvertHostTimeToNanos(frame.firstFrameHostTime)
            ) * 1.0e-9
            let frameHost = callbackHost
                + Double(frame.frameOffset) / sampleRate
            guard frameHost.isFinite, frameHost > 0 else {
                throw QuietZoneInstrumentedProbeError.invalidInput
            }
            if let previousFrame = lastSampleTime,
               let previousHost = lastHostSeconds {
                guard abs(frameNumber - previousFrame - 1) < 0.01 else {
                    throw QuietZoneInstrumentedProbeError.discontinuousInput
                }
                guard abs(frameHost - previousHost - 1 / sampleRate)
                    <= Self.maximumHostResidualSeconds else {
                    throw QuietZoneInstrumentedProbeError.clockMismatch
                }
            }
            if firstSampleTime == nil {
                firstSampleTime = frameNumber
                firstHostSeconds = frameHost
            }
            samples.append(frame.sample)
            lastSampleTime = frameNumber
            lastHostSeconds = frameHost
        }
    }

    func finish(
        launch: QuietZoneInstrumentedSourceLaunch
    ) throws -> QuietZoneFeedForwardProbeCapture {
        guard launch.sourceFixtureID == sourceFixtureID,
              launch.synchronizedClockID == synchronizedClockID,
              launch.physicalSourceID == physicalSourceID,
              launch.routeLeaseID == routeLeaseID,
              launch.sampleRate.isFinite,
              abs(launch.sampleRate - sampleRate) < 0.5,
              !launch.launchID.isEmpty else {
            throw QuietZoneInstrumentedProbeError.incompatibleSource
        }
        guard launch.physicalClockCalibrationVerified,
              launch.emissionHostSeconds.isFinite,
              launch.emissionHostSeconds > 0,
              launch.oneSigmaTimingUncertaintySeconds.isFinite,
              (0...0.0005).contains(launch.oneSigmaTimingUncertaintySeconds)
        else { throw QuietZoneInstrumentedProbeError.uncalibratedTrigger }
        guard (64...2_048).contains(launch.emittedProbe.count),
              launch.emittedProbe.allSatisfy({
                  $0.isFinite && abs($0) < 0.99
              }) else {
            throw QuietZoneInstrumentedProbeError.unusableAudio
        }
        guard samples.count >= Self.minimumFrames,
              let start = firstHostSeconds, let end = lastHostSeconds else {
            throw QuietZoneInstrumentedProbeError.incompleteCapture
        }
        let preRoll = (launch.emissionHostSeconds - start) * sampleRate
        guard preRoll >= Double(Self.minimumPreRollFrames) else {
            throw QuietZoneInstrumentedProbeError.missingPreRoll
        }
        // Require a complete probe plus room for the detector's pre/post noise
        // discrimination; ordinary late UI timestamps cannot pass.
        guard (end - launch.emissionHostSeconds) * sampleRate
                >= Double(launch.emittedProbe.count + 96) else {
            throw QuietZoneInstrumentedProbeError.incompleteCapture
        }
        // PR96 probe detector measures onset after this timestamp. Its
        // uncertainty is inherited from the independently qualified source.
        return QuietZoneFeedForwardProbeCapture(
            position: position,
            emittedProbe: launch.emittedProbe,
            recordedSamples: samples,
            sampleRate: sampleRate,
            firstInputFrameAfterTriggerSeconds:
                start - launch.emissionHostSeconds,
            triggerClockUncertaintySeconds:
                launch.oneSigmaTimingUncertaintySeconds,
            sourceTriggerID: sourceFixtureID,
            synchronizedClockID: synchronizedClockID,
            microphoneDeviceID: microphoneID,
            microphoneChannel: microphoneChannel,
            routeFingerprint: routeLeaseID
        )
    }
}

/// Hardware microphone input only. The external source controller supplies
/// an independently witnessed emission event to finish(); this object cannot
/// start a loudspeaker, schedule playback or arm feed-forward ANC.
@MainActor
final class QuietZoneInstrumentedProbeAcquisition {
    typealias Route = QuietZoneHardwareHALClockAcquisition.Route

    private let reference: FeedForwardReferenceTransport
    private let expectedLease: QuietZoneHardwareClockRouteLease
    private let currentRoute: () -> Route?
    private var collector: QuietZoneInstrumentedProbeCollector
    private var started = false
    private var finished = false

    init(
        reference: FeedForwardReferenceTransport,
        collector: QuietZoneInstrumentedProbeCollector,
        currentRoute: @escaping () -> Route?
    ) throws {
        guard reference.microphone.uid == collector.microphoneID,
              reference.inputChannelIndex == collector.microphoneChannel,
              abs(reference.sampleRate - collector.sampleRate) < 0.5 else {
            throw QuietZoneInstrumentedProbeError.incompatibleSource
        }
        self.reference = reference
        self.collector = collector
        self.currentRoute = currentRoute
        // The recorder is pinned to the exact output session lease; a
        // preexisting device UID alone cannot authorize timing evidence.
        guard let route = currentRoute(), !route.outputID.isEmpty,
              route.routeID == collector.routeLeaseID,
              route.sampleRate.isFinite,
              abs(route.sampleRate - collector.sampleRate) < 0.5 else {
            throw QuietZoneInstrumentedProbeError.staleRoute
        }
        self.expectedLease = .init(
            outputID: route.outputID, routeID: route.routeID,
            sampleRate: route.sampleRate
        )
    }

    private func requireRoute() throws {
        guard let route = currentRoute(), expectedLease.permits(
            outputID: route.outputID, routeID: route.routeID,
            sampleRate: route.sampleRate
        ) else { throw QuietZoneInstrumentedProbeError.staleRoute }
    }

    func start() throws {
        guard !started, !finished else {
            throw QuietZoneInstrumentedProbeError.alreadyFinished
        }
        try requireRoute()
        try reference.start()
        started = true
    }

    func poll() throws {
        guard started, !finished else {
            throw QuietZoneInstrumentedProbeError.alreadyFinished
        }
        do {
            try requireRoute()
            guard let snapshot = reference.snapshot(),
                  snapshot.droppedFrames == 0,
                  snapshot.invalidTimestamps == 0,
                  snapshot.unsupportedBufferLayouts == 0 else {
                throw QuietZoneInstrumentedProbeError.callbackFault
            }
            let frames = try reference.read(maximumFrames: 4_096)
            try collector.append(frames)
        } catch {
            reference.stop()
            started = false
            finished = true
            throw error
        }
    }

    func finish(
        launch: QuietZoneInstrumentedSourceLaunch
    ) throws -> QuietZoneFeedForwardProbeCapture {
        guard started, !finished else {
            throw QuietZoneInstrumentedProbeError.alreadyFinished
        }
        defer {
            reference.stop()
            started = false
            finished = true
        }
        try poll()
        try requireRoute()
        return try collector.finish(launch: launch)
    }

    func cancel() {
        if started { reference.stop() }
        started = false
        finished = true
    }
}
