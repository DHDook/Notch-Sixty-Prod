import CoreMotion
import Foundation

enum HeadTrackingSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case appleHeadphones

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleHeadphones: return "Apple Headphone Motion"
        }
    }
}

struct HeadTrackingConfiguration: Codable, Equatable, Sendable {
    var enabled = false
    var source: HeadTrackingSourceKind = .appleHeadphones
    var fallbackToStaticSpatial = true
    var smoothingFactor = 0.35
    var predictionMilliseconds = 15.0
    var angularUpdateThresholdDegrees = 1.5
    var maximumUpdateRateHz = 20.0
    var generationWarmupMilliseconds = 30.0
    var crossfadeMilliseconds = 20.0

    func validate() throws {
        guard smoothingFactor.isFinite, (0.05...1.0).contains(smoothingFactor),
              predictionMilliseconds.isFinite, (0.0...50.0).contains(predictionMilliseconds),
              angularUpdateThresholdDegrees.isFinite, (0.25...15.0).contains(angularUpdateThresholdDegrees),
              maximumUpdateRateHz.isFinite, (1.0...60.0).contains(maximumUpdateRateHz),
              generationWarmupMilliseconds.isFinite, (0.0...100.0).contains(generationWarmupMilliseconds),
              crossfadeMilliseconds.isFinite, (2.0...100.0).contains(crossfadeMilliseconds) else {
            throw HeadTrackingError.invalidConfiguration
        }
    }
}

enum HeadTrackingRuntimeStatus: Equatable, Sendable {
    case disabled
    case configuredStopped
    case starting
    case active
    case staticFallback(String)
    case failed(String)

    var displayName: String {
        switch self {
        case .disabled: return "Off"
        case .configuredStopped: return "Configured · stopped"
        case .starting: return "Starting…"
        case .active: return "Tracking"
        case .staticFallback: return "Static fallback"
        case .failed: return "Unavailable"
        }
    }

    var detail: String? {
        switch self {
        case .staticFallback(let reason), .failed(let reason): return reason
        default: return nil
        }
    }

    var isActivelyTracking: Bool {
        if case .active = self { return true }
        return false
    }
}

enum HeadTrackingError: Error, Equatable, LocalizedError {
    case invalidConfiguration
    case motionPermissionDenied
    case motionSourceUnavailable
    case generationPreparationFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Head-tracking smoothing, prediction, update-rate, warmup, or crossfade settings are invalid."
        case .motionPermissionDenied:
            return "Headphone motion permission is denied or restricted in macOS Privacy settings."
        case .motionSourceUnavailable:
            return "No compatible motion-capable Apple headphones are currently available."
        case .generationPreparationFailed:
            return "Unable to prepare a head-relative HRTF/BRIR renderer generation."
        }
    }
}

struct HeadPoseSample: Sendable {
    let pose: N60HeadPose
    let timestamp: TimeInterval
}

protocol HeadPoseSource: AnyObject {
    var onPose: ((HeadPoseSample) -> Void)? { get set }
    var onFailure: ((Error) -> Void)? { get set }
    func start() throws
    func stop()
    func recenter()
}

/// Apple-compatible implementation of the vendor-neutral HeadPoseSource boundary.
/// Core Motion callbacks stay entirely on a private serial OperationQueue.
final class AppleHeadphoneMotionSource: NSObject, HeadPoseSource {
    var onPose: ((HeadPoseSample) -> Void)?
    var onFailure: ((Error) -> Void)?

    private let manager = CMHeadphoneMotionManager()
    private let motionQueue: OperationQueue
    private var referencePose: N60HeadPose?

    override init() {
        let queue = OperationQueue()
        queue.name = "com.dhdook.NotchSixty.headphone-motion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        motionQueue = queue
        super.init()
    }

    func start() throws {
        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if authorization == .denied || authorization == .restricted {
            throw HeadTrackingError.motionPermissionDenied
        }
        guard manager.isDeviceMotionAvailable else {
            throw HeadTrackingError.motionSourceUnavailable
        }
        referencePose = nil
        manager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.onFailure?(error)
                return
            }
            guard let motion else { return }
            let radiansToDegrees = 180.0 / Double.pi
            let raw = N60HeadPose(
                yawDegrees: motion.attitude.yaw * radiansToDegrees,
                pitchDegrees: motion.attitude.pitch * radiansToDegrees,
                rollDegrees: motion.attitude.roll * radiansToDegrees
            )
            guard N60HeadPoseIsValid(raw) else { return }
            if self.referencePose == nil {
                self.referencePose = raw
            }
            guard let reference = self.referencePose else { return }
            let relative = N60HeadPose(
                yawDegrees: N60HeadPoseWrap180(raw.yawDegrees - reference.yawDegrees),
                pitchDegrees: max(-90.0, min(90.0, raw.pitchDegrees - reference.pitchDegrees)),
                rollDegrees: N60HeadPoseWrap180(raw.rollDegrees - reference.rollDegrees)
            )
            guard N60HeadPoseIsValid(relative) else { return }
            self.onPose?(HeadPoseSample(pose: relative, timestamp: motion.timestamp))
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        motionQueue.cancelAllOperations()
    }

    func recenter() {
        motionQueue.addOperation { [weak self] in
            self?.referencePose = nil
        }
    }
}

/// Non-realtime coordinator. Sensor smoothing, prediction, angular hysteresis,
/// HRTF direction lookup and PR57 kernel preparation all happen here, never in
/// the Core Audio callbacks.
final class SpatialHeadTrackingController {
    private let configuration: HeadTrackingConfiguration
    private let asset: BinauralProfileAsset
    private let layout: OutputProgramLayout
    private let session: CoreAudioBinauralHeadphoneTransportSession
    private let source: any HeadPoseSource
    private let preparationQueue = DispatchQueue(
        label: "com.dhdook.NotchSixty.head-tracking-preparation",
        qos: .userInitiated
    )
    private let onStatus: @Sendable (HeadTrackingRuntimeStatus) -> Void

    private var running = false
    private var smoothedPose: N60HeadPose?
    private var previousSmoothedPose: N60HeadPose?
    private var previousTimestamp: TimeInterval?
    private var lastPreparedPose: N60HeadPose?
    private var lastPreparedTimestamp: TimeInterval?

    init(
        configuration: HeadTrackingConfiguration,
        asset: BinauralProfileAsset,
        layout: OutputProgramLayout,
        session: CoreAudioBinauralHeadphoneTransportSession,
        source: (any HeadPoseSource)? = nil,
        onStatus: @escaping @Sendable (HeadTrackingRuntimeStatus) -> Void
    ) {
        self.configuration = configuration
        self.asset = asset
        self.layout = layout
        self.session = session
        self.source = source ?? AppleHeadphoneMotionSource()
        self.onStatus = onStatus
    }

    func start() throws {
        try configuration.validate()
        guard configuration.enabled else {
            onStatus(.disabled)
            return
        }
        preparationQueue.sync { running = true }
        source.onPose = { [weak self] sample in
            guard let self else { return }
            self.preparationQueue.async { [weak self] in
                self?.handle(sample)
            }
        }
        source.onFailure = { [weak self] error in
            self?.handleSourceFailure(error)
        }
        onStatus(.starting)
        do {
            try source.start()
        } catch {
            preparationQueue.sync { running = false }
            if configuration.fallbackToStaticSpatial {
                onStatus(.staticFallback(error.localizedDescription))
                return
            }
            onStatus(.failed(error.localizedDescription))
            throw error
        }
    }

    func stop() {
        preparationQueue.sync { running = false }
        source.stop()
        preparationQueue.sync {}
        onStatus(configuration.enabled ? .configuredStopped : .disabled)
    }

    func recenter() {
        source.recenter()
        preparationQueue.async { [weak self] in
            guard let self else { return }
            self.smoothedPose = nil
            self.previousSmoothedPose = nil
            self.previousTimestamp = nil
            self.lastPreparedPose = nil
            self.lastPreparedTimestamp = nil
        }
    }

    private func handleSourceFailure(_ error: Error) {
        preparationQueue.async { [weak self] in
            guard let self, self.running else { return }
            if self.configuration.fallbackToStaticSpatial {
                self.running = false
                self.source.stop()
                self.onStatus(.staticFallback(error.localizedDescription))
            } else {
                self.running = false
                self.source.stop()
                self.onStatus(.failed(error.localizedDescription))
            }
        }
    }

    private func handle(_ sample: HeadPoseSample) {
        guard running, N60HeadPoseIsValid(sample.pose) else { return }
        let smoothed = smooth(sample.pose)
        let predicted = predict(smoothed, timestamp: sample.timestamp)
        let minimumInterval = 1.0 / configuration.maximumUpdateRateHz
        if let lastPreparedTimestamp,
           sample.timestamp - lastPreparedTimestamp < minimumInterval {
            remember(smoothed, timestamp: sample.timestamp)
            return
        }
        if let lastPreparedPose,
           N60HeadPoseAngularDeltaDegrees(lastPreparedPose, predicted)
                < configuration.angularUpdateThresholdDegrees {
            remember(smoothed, timestamp: sample.timestamp)
            return
        }

        do {
            let prepared = try asset.prepare(for: layout, headPose: predicted)
            let sampleRate = prepared.descriptor.sampleRate
            let requestedWarmup = UInt32(max(
                0,
                min(
                    Double(UInt32.max),
                    (configuration.generationWarmupMilliseconds * sampleRate / 1_000.0).rounded()
                )
            ))
            let warmupFrames = min(requestedWarmup, UInt32(prepared.descriptor.tapCount))
            let crossfadeFrames = UInt32(max(
                1,
                min(
                    Double(UInt32.max),
                    (configuration.crossfadeMilliseconds * sampleRate / 1_000.0).rounded()
                )
            ))
            let accepted = try session.prepareHeadTrackedGeneration(
                preparedProfile: prepared,
                pose: predicted,
                warmupFrames: warmupFrames,
                crossfadeFrames: crossfadeFrames
            )
            if accepted {
                lastPreparedPose = predicted
                lastPreparedTimestamp = sample.timestamp
                onStatus(.active)
            }
        } catch {
            if configuration.fallbackToStaticSpatial {
                running = false
                source.stop()
                onStatus(.staticFallback(error.localizedDescription))
            } else {
                running = false
                source.stop()
                onStatus(.failed(error.localizedDescription))
            }
        }
        remember(smoothed, timestamp: sample.timestamp)
    }

    private func smooth(_ pose: N60HeadPose) -> N60HeadPose {
        guard let previous = smoothedPose else {
            smoothedPose = pose
            return pose
        }
        let alpha = configuration.smoothingFactor
        let result = N60HeadPose(
            yawDegrees: N60HeadPoseWrap180(
                previous.yawDegrees
                    + N60HeadPoseWrap180(pose.yawDegrees - previous.yawDegrees) * alpha
            ),
            pitchDegrees: max(-90.0, min(
                90.0,
                previous.pitchDegrees + (pose.pitchDegrees - previous.pitchDegrees) * alpha
            )),
            rollDegrees: N60HeadPoseWrap180(
                previous.rollDegrees
                    + N60HeadPoseWrap180(pose.rollDegrees - previous.rollDegrees) * alpha
            )
        )
        smoothedPose = result
        return result
    }

    private func predict(_ pose: N60HeadPose, timestamp: TimeInterval) -> N60HeadPose {
        guard configuration.predictionMilliseconds > 0,
              let previous = previousSmoothedPose,
              let previousTimestamp,
              timestamp > previousTimestamp else {
            return pose
        }
        let dt = timestamp - previousTimestamp
        guard dt > 0.001, dt < 0.5 else { return pose }
        let lead = configuration.predictionMilliseconds / 1_000.0
        func boundedVelocity(_ delta: Double) -> Double {
            max(-720.0, min(720.0, delta / dt))
        }
        let yawVelocity = boundedVelocity(N60HeadPoseWrap180(pose.yawDegrees - previous.yawDegrees))
        let pitchVelocity = boundedVelocity(pose.pitchDegrees - previous.pitchDegrees)
        let rollVelocity = boundedVelocity(N60HeadPoseWrap180(pose.rollDegrees - previous.rollDegrees))
        return N60HeadPose(
            yawDegrees: N60HeadPoseWrap180(pose.yawDegrees + yawVelocity * lead),
            pitchDegrees: max(-90.0, min(90.0, pose.pitchDegrees + pitchVelocity * lead)),
            rollDegrees: N60HeadPoseWrap180(pose.rollDegrees + rollVelocity * lead)
        )
    }

    private func remember(_ pose: N60HeadPose, timestamp: TimeInterval) {
        previousSmoothedPose = pose
        previousTimestamp = timestamp
    }
}
