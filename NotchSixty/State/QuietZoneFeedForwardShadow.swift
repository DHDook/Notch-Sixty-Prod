import Combine
import CoreAudio
import Foundation

/// What the feed-forward shadow runs on: the seat microphone's device with
/// both channels, and the survey (S9b) that seeds it.
struct QuietZoneFeedForwardShadowInputs: Equatable, Sendable {
    var device: AudioInputDevice
    var referenceChannel: Int
    var errorChannel: Int
    /// Assembled survey bands (coherent only).
    var bands: [QuietZoneVirtualSeatBand]
    var design: QuietZoneVirtualSeatDesign?
    var budget: QuietZoneFeedForwardBudget
    var position: RoomCorrectionMeasurementPosition
    /// E4 S22b2: the speakers' leakage into the reference microphone, for echo removal.
    var echoModel: FeedForwardEchoModel?
}

typealias QuietZoneFeedForwardShadowCaptureFactory = (
    QuietZoneFeedForwardShadowInputs
) throws -> QuietZoneFeedForwardPairCapturing

/// The device's current nominal rate, or nil if it cannot be read.
typealias QuietZoneFeedForwardShadowRateReader = @Sendable (AudioInputDevice) -> Double?

enum QuietZoneFeedForwardShadowDevice {
    static let nominalSampleRate: QuietZoneFeedForwardShadowRateReader = { device in
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(device.deviceID, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }
}

/// "Would have tripped" for the unplayed shadow, from the core's status at
/// each poll. The fail-to-mute guard (`N60AncGuard`) cannot run here: the
/// core keeps its output internal and adapts at fd (about 4 kHz), below the
/// guard's 8 kHz floor. Checks:
/// - a model reset (non-finite weights);
/// - either output's mean square above a -6 dBFS sine's (the guard's ceiling);
/// - growth: the larger output's mean square rising by at least 3 dB on three
///   polls in a row, above -60 dBFS.
/// It arms after three seconds of adaptation since the last restart. A trip
/// latches until a gap, which re-arms it (a new shadow starts a new watch).
struct QuietZoneFeedForwardShadowWatch: Equatable, Sendable {
    static let armSeconds = 3.0
    static let ceilingMeanSquare: Float = 0.125
    static let growthDB = 3.0
    static let growthPolls = 3
    static let activityFloorDB = -60.0

    private var gaps: UInt64?
    private var modelResets: UInt64?
    private var lastPowerDB: Double?
    private var rising = 0
    private(set) var trip: String?

    mutating func observe(_ status: N60FeedForwardShadowStatus) -> AdaptiveQuietZoneShadowStatus.Guard {
        if gaps != status.gaps {
            trip = nil
            lastPowerDB = nil
            rising = 0
        }
        defer {
            gaps = status.gaps
            modelResets = status.modelResets
        }
        if trip == nil, let previous = modelResets, status.modelResets > previous {
            trip = "non-finite weights"
        }
        let armed = Double(status.samplesSinceRestart) >= Self.armSeconds * status.decimatedRate
        guard armed else {
            lastPowerDB = nil
            rising = 0
            return trip.map { .wouldHaveTripped($0) } ?? .arming
        }
        let (left, right) = status.outputPower
        if trip == nil, !left.isFinite || !right.isFinite {
            trip = "non-finite output"
        }
        let power = left.isFinite && right.isFinite ? max(left, right) : 0
        if trip == nil, power > Self.ceilingMeanSquare {
            trip = "over ceiling"
        }
        let db = 10 * log10(max(Double(power), 1.0e-30))
        if let last = lastPowerDB, db > Self.activityFloorDB, db - last >= Self.growthDB {
            rising += 1
        } else {
            rising = 0
        }
        if trip == nil, rising >= Self.growthPolls { trip = "growth" }
        lastPowerDB = db
        return trip.map { .wouldHaveTripped($0) } ?? .clear
    }
}

/// The shadow core, fed from a two-channel capture on one serial queue. Its
/// output stays inside the core: this type holds no engine or render handle,
/// so nothing it computes can reach the device.
///
/// Realtime behaviour: never on the audio callback. The capture's IOProc only
/// writes its ring; every call here runs on `queue`. Allocation: the core is
/// created in `init`, and each pump allocates the read buffers (worker side).
/// Synchronisation: one serial queue; the core is used from nowhere else.
/// Latency: none (nothing plays). Sample rate: the capture's native rate,
/// 8 kHz to 768 kHz, fixed per engine; a change needs a new engine.
/// Channels: two inputs of one device (reference, error), sample-aligned.
/// Reset: a jump in sample time marks a gap; a device, rate, channel or
/// survey change makes a new engine.
final class QuietZoneFeedForwardShadowEngine: @unchecked Sendable {
    struct Snapshot: Sendable {
        var status: N60FeedForwardShadowStatus
        var left: [Float]
        var right: [Float]
        /// Why echo removal is not subtracting, or nil while it is aligned.
        var alignmentNote: String?
        var driftPPM: Double?
    }

    typealias HostSeconds = @Sendable (UInt64) -> Double
    static let machHostSeconds: HostSeconds = { Double(AudioConvertHostTimeToNanos($0)) * 1.0e-9 }

    /// At most one second of capture per pump.
    static let readFrames = 16_384

    let plan: QuietZoneFeedForwardShadowPlan
    let sampleRate: Double
    private let taps: Int
    private let queue = DispatchQueue(label: "notchsixty.feed-forward.shadow", qos: .userInitiated)
    private let core: OpaquePointer
    private let capture: QuietZoneFeedForwardPairCapturing
    private var nextSampleTime: Double?
    private var reference: [Float] = []
    private var error: [Float] = []
    // E4 S22b2 echo removal. `aligner` is nil when there is no echo model or drive.
    private let hostSeconds: HostSeconds
    private var aligner: FeedForwardDriveAligner?
    private var micFramesAppended: UInt64 = 0
    private var nextDriveFrame: UInt64?
    private var lastDropped: (UInt64, UInt64)?
    private var alignmentNote: String? = "waiting for the speaker drive"
    private var driftPPM: Double?
    /// Fixed at init, so the main actor can read it without the worker queue.
    let echoActive: Bool

    init?(
        plan: QuietZoneFeedForwardShadowPlan, capture: QuietZoneFeedForwardPairCapturing,
        echo: FeedForwardEchoModel? = nil, driveSampleRate: Double? = nil,
        hostSeconds: @escaping HostSeconds = QuietZoneFeedForwardShadowEngine.machHostSeconds
    ) {
        guard capture.sampleRate == plan.nativeSampleRate else { return nil }
        self.hostSeconds = hostSeconds
        var config = N60FeedForwardShadowConfigDefault(plan.nativeSampleRate)
        if let echo, let driveSampleRate, echo.nativeSampleRate == plan.nativeSampleRate {
            config.driveSampleRate = driveSampleRate
        }
        guard let core = N60FeedForwardShadowCreate(&config) else { return nil }
        let count = UInt32(min(plan.seedLeft.count, plan.seedRight.count))
        guard N60FeedForwardShadowSetPath(
                  core, 0, UInt32(plan.leftPath.bulkDelay), plan.leftPath.taps, UInt32(plan.leftPath.taps.count)
              ),
              N60FeedForwardShadowSetPath(
                  core, 1, UInt32(plan.rightPath.bulkDelay), plan.rightPath.taps, UInt32(plan.rightPath.taps.count)
              ),
              N60FeedForwardShadowSetSeed(core, plan.seedLeft, plan.seedRight, count)
        else {
            N60FeedForwardShadowDestroy(core)
            return nil
        }
        if config.driveSampleRate > 0, let echo {
            guard N60FeedForwardShadowSetEcho(
                      core, 0, UInt32(echo.left.bulkDelay), echo.left.taps, UInt32(echo.left.taps.count)
                  ),
                  N60FeedForwardShadowSetEcho(
                      core, 1, UInt32(echo.right.bulkDelay), echo.right.taps, UInt32(echo.right.taps.count)
                  )
            else {
                N60FeedForwardShadowDestroy(core)
                return nil
            }
            aligner = FeedForwardDriveAligner(micRate: plan.nativeSampleRate, driveRate: config.driveSampleRate)
        }
        self.plan = plan
        self.capture = capture
        self.core = core
        echoActive = aligner != nil
        sampleRate = plan.nativeSampleRate
        taps = Int(config.taps)
    }

    deinit { N60FeedForwardShadowDestroy(core) }

    func start() throws { try queue.sync { try capture.start() } }

    /// Drains the capture (up to one second). A jump in sample time (a lost
    /// callback) marks a gap. A capture fault throws.
    func pump(drive: FeedForwardDriveChunk? = nil) throws -> Snapshot {
        try queue.sync {
            applyDrive(drive)
            var remaining = max(Int(sampleRate), Self.readFrames)
            while remaining > 0 {
                let chunk = try capture.readPair(maximumFrames: min(Self.readFrames, remaining))
                if chunk.reference.isEmpty { break }
                ingest(chunk.reference, chunk.error)
                remaining -= chunk.reference.count
            }
            var left = [Float](repeating: 0, count: taps)
            var right = [Float](repeating: 0, count: taps)
            N60FeedForwardShadowCopyWeights(core, 0, &left, UInt32(taps))
            N60FeedForwardShadowCopyWeights(core, 1, &right, UInt32(taps))
            return Snapshot(
                status: N60FeedForwardShadowReadStatus(core), left: left, right: right,
                alignmentNote: aligner == nil ? nil : alignmentNote, driftPPM: driftPPM
            )
        }
    }

    /// Pushes the speaker drive ahead of the microphone frames that follow it. Any break in the
    /// drive's index sequence or in the render path's drop counters restarts the drive and its fit.
    private func applyDrive(_ chunk: FeedForwardDriveChunk?) {
        guard aligner != nil else { return }
        guard let chunk else {
            alignmentNote = "no speaker drive from the engine"
            return
        }
        let dropped = (chunk.droppedFrames, chunk.droppedAnchors)
        if nextDriveFrame != chunk.firstFrame || lastDropped.map({ $0 != dropped }) ?? true {
            N60FeedForwardShadowRestartDrive(core, chunk.firstFrame)
            aligner?.resetDrive()
            nextDriveFrame = chunk.firstFrame
        }
        lastDropped = dropped
        for anchor in chunk.anchors where anchor.outputHostTime != 0 {
            aligner?.addDrive(frame: anchor.firstFrameIndex, hostSeconds: hostSeconds(anchor.outputHostTime))
        }
        if !chunk.left.isEmpty {
            N60FeedForwardShadowPushDrive(core, chunk.left, chunk.right, UInt32(chunk.left.count))
            nextDriveFrame = chunk.firstFrame &+ UInt64(chunk.left.count)
        }
    }

    /// Sets the drive position that matches the first microphone frame of the batch about to run.
    private func applyTiming(micFrame: UInt64) {
        guard let current = aligner else { return }
        switch current.evaluate(micFrame: micFrame) {
        case .aligning:
            break
        case .stopped(let reason):
            alignmentNote = reason
            driftPPM = nil
            if let next = nextDriveFrame { N60FeedForwardShadowRestartDrive(core, next) }
            aligner?.resetDrive()
        case .aligned(let driveFrame, let ratio, let drift):
            if N60FeedForwardShadowSetDriveTiming(core, micFrame, driveFrame, ratio) {
                alignmentNote = nil
                driftPPM = drift
            }
        }
    }

    /// Closes the capture after any pump in flight, without waiting for it.
    func close() { queue.async { [self] in capture.close() } }

    /// Waits for queued work (tests).
    func waitForQueue() { queue.sync {} }

    /// Sample times jump only between callbacks, so they are checked at the
    /// first frame of each callback and of each chunk.
    private func ingest(_ frames: [N60FeedForwardReferenceFrame], _ samples: [Float]) {
        guard let last = frames.last else { return }
        reference.removeAll(keepingCapacity: true)
        error.removeAll(keepingCapacity: true)
        reference.reserveCapacity(frames.count)
        error.reserveCapacity(frames.count)
        for i in frames.indices {
            let frame = frames[i]
            if i == 0 || frame.frameOffset == 0 {
                let expected = i == 0
                    ? nextSampleTime
                    : frames[i - 1].firstFrameSampleTime + Double(frames[i - 1].frameOffset) + 1
                let time = frame.firstFrameSampleTime + Double(frame.frameOffset)
                if let expected, abs(time - expected) > 0.5 {
                    flush()
                    N60FeedForwardShadowMarkDiscontinuity(core)
                    aligner?.resetAll()
                    alignmentNote = "gap in the microphone stream"
                }
                if frame.frameOffset == 0, frame.firstFrameHostTime != 0 {
                    aligner?.addMic(frame: micFramesAppended, hostSeconds: hostSeconds(frame.firstFrameHostTime))
                }
            }
            micFramesAppended &+= 1
            reference.append(frame.sample)
            error.append(samples[i])
        }
        nextSampleTime = last.firstFrameSampleTime + Double(last.frameOffset) + 1
        flush()
    }

    private func flush() {
        guard !reference.isEmpty else { return }
        applyTiming(micFrame: micFramesAppended &- UInt64(reference.count))
        N60FeedForwardShadowProcess(core, reference, error, UInt32(reference.count))
        reference.removeAll(keepingCapacity: true)
        error.removeAll(keepingCapacity: true)
    }
}

struct QuietZoneFeedForwardShadowStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case inactive
        case waiting(String)
        case adapting
        case fault(String)

        var displayName: String {
            switch self {
            case .inactive: return "Off"
            case .waiting: return "Waiting"
            case .adapting: return "Adapting (shadow)"
            case .fault: return "Restarting"
            }
        }
    }

    var state: State
    var sampleRate: Double?
    var decimatedRate: Double?
    var seedSource: QuietZoneFeedForwardShadowPlan.SeedSource?
    var comparison = QuietZoneFeedForwardShadowComparison(bands: [])
    var guardState: AdaptiveQuietZoneShadowStatus.Guard = .arming
    /// Band-limited error microphone and virtual error, dBFS mean square.
    var measuredDBFS: Double?
    var predictedDBFS: Double?
    /// sum |W| per channel, dB.
    var weightGainDB: [Double] = []
    var adaptedSeconds: Double = 0
    var gaps: UInt64 = 0
    var modelResets: UInt64 = 0
    var gainLimited: UInt64 = 0
    /// E4 S22b2: echo removal (the speakers' own programme taken out of the reference).
    var echo = QuietZoneFeedForwardEchoReadout.off

    static let inactive = QuietZoneFeedForwardShadowStatus(state: .inactive)
}

/// E4 S22b2: what the card shows about echo removal.
struct QuietZoneFeedForwardEchoReadout: Equatable, Sendable {
    enum Alignment: Equatable, Sendable {
        case off(String)
        case waiting(String)
        case searching
        case locked
    }

    var alignment: Alignment
    /// Reference level before over after removal, dB; nil unless locked.
    var removalDB: Double?
    var offsetSamples: Int = 0
    var driftPPM: Double?
    var stability: FeedForwardLeakageStabilityCheck.Verdict = .notChecked("not checked: measure leakage again")
    /// Removal stayed under 10 dB for 10 s of programme: the model no longer fits the room.
    var measureAgain = false

    static let off = QuietZoneFeedForwardEchoReadout(alignment: .off("Echo removal is off."))
}

/// Removal under 10 dB while locked on programme for 10 s means the leakage model is stale.
struct FeedForwardRemovalWatch: Equatable, Sendable {
    static let minimumRemovalDB = 10.0
    static let seconds = 10.0
    static let programmeFloor: Float = 1.0e-5  // -50 dBFS mean square

    private var weak = 0.0
    private(set) var stale = false

    mutating func observe(locked: Bool, removalDB: Double?, drivePower: Float, dt: Double) {
        guard locked, let removalDB, drivePower >= Self.programmeFloor else { return }
        if removalDB >= Self.minimumRemovalDB { weak = 0; return }
        weak += dt
        if weak >= Self.seconds { stale = true }
    }
}

/// E4 S9c: the feed-forward canceller in shadow mode.
/// It captures the reference and seat microphones on one device, seeds from
/// the survey (S9b), adapts on the virtual error, and compares its predicted
/// reduction per third-octave band with the offline design's. It never plays:
/// `AdaptiveTonalOutputGate` stays the only route to output.
///
/// Opening, starting, pumping and closing the capture all run off the main
/// actor. Polls come every 100 ms, well inside the capture ring's 0.25 s.
@MainActor
final class QuietZoneFeedForwardShadow: ObservableObject {
    @Published private(set) var status = QuietZoneFeedForwardShadowStatus.inactive

    static let pollNanoseconds: UInt64 = 100_000_000
    /// Polls to wait after the capture could not be created or faulted.
    static let retryPolls = 10
    /// At most 0.7 s of drive at 384 kHz per poll; the ring holds 262,144 frames.
    static let driveReadFrames = 262_144

    private(set) var isActive = false
    /// Shadows created so far (each rate, device or survey change makes one).
    private(set) var enginesCreated = 0
    private var inputs: QuietZoneFeedForwardShadowInputs?
    private var waitingReason = "Measure the feed-forward design first."
    private var engine: QuietZoneFeedForwardShadowEngine?
    private var closing: QuietZoneFeedForwardShadowEngine?
    private var watch = QuietZoneFeedForwardShadowWatch()
    private var removalWatch = FeedForwardRemovalWatch()
    /// Set by the app when `e4.feedforward-live` is on; nil means no drive is ever requested.
    var driveSource: (any FeedForwardDriveSource)?
    private var demandSet = false
    private var retryCountdown = 0
    /// Bumped whenever the engine is dropped, so late results are ignored.
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var observation: AnyCancellable?
    private let captureFactory: QuietZoneFeedForwardShadowCaptureFactory
    private let deviceRate: QuietZoneFeedForwardShadowRateReader
    private let pollsAutomatically: Bool

    var hasEngine: Bool { engine != nil }

    init(
        captureFactory: @escaping QuietZoneFeedForwardShadowCaptureFactory = { inputs in
            try FeedForwardReferenceTransport(
                microphone: inputs.device, inputChannelIndex: inputs.referenceChannel,
                errorChannelIndex: inputs.errorChannel
            )
        },
        deviceRate: @escaping QuietZoneFeedForwardShadowRateReader = QuietZoneFeedForwardShadowDevice.nominalSampleRate,
        pollsAutomatically: Bool = true
    ) {
        self.captureFactory = captureFactory
        self.deviceRate = deviceRate
        self.pollsAutomatically = pollsAutomatically
    }

    deinit { loop?.cancel() }

    /// Follows the survey: its bands, design, channels and activity (the
    /// shadow pauses while a measurement runs).
    func observe(_ survey: QuietZoneFeedForwardSurveyController) {
        observation = Publishers.MergeMany(
            survey.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            survey.quietZone.$feedForwardBudget.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak survey] _ in
            guard let self, let survey else { return }
            MainActor.assumeIsolated {
                let next = survey.shadowInputs()
                self.update(inputs: next.inputs, reason: next.reason)
            }
        }
        let first = survey.shadowInputs()
        update(inputs: first.inputs, reason: first.reason)
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            status = QuietZoneFeedForwardShadowStatus(state: .waiting(waitingReason))
            if pollsAutomatically {
                loop = Task { [weak self] in
                    while !Task.isCancelled {
                        await self?.tick()
                        try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
                    }
                }
            }
        } else {
            loop?.cancel()
            loop = nil
            dropEngine()
            status = .inactive
        }
    }

    /// New inputs (or none, with the reason) drop the running shadow.
    func update(inputs: QuietZoneFeedForwardShadowInputs?, reason: String) {
        waitingReason = reason
        guard inputs != self.inputs else { return }
        self.inputs = inputs
        dropEngine()
        retryCountdown = 0
        if isActive { status = QuietZoneFeedForwardShadowStatus(state: .waiting(reason)) }
    }

    /// One poll: create the shadow if needed, drain the capture, publish.
    func tick() async {
        guard isActive else { return }
        guard let inputs else {
            status = QuietZoneFeedForwardShadowStatus(state: .waiting(waitingReason))
            return
        }
        if engine == nil {
            guard retryCountdown == 0 else {
                retryCountdown -= 1
                return
            }
            guard await create(inputs) else { return }
        }
        guard let running = engine else { return }
        let current = generation
        let rate = deviceRate
        let device = inputs.device
        // The rings have one consumer, this main-actor read; the worker only gets the copy.
        let chunk = running.echoActive && echoBlockedReason(inputs) == nil
            ? driveSource?.readDrive(maximumFrames: Self.driveReadFrames) : nil
        let snapshot: QuietZoneFeedForwardShadowEngine.Snapshot
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                // A nominal-rate change need not fault the capture: check it.
                if let now = rate(device), now != running.sampleRate {
                    throw QuietZoneFeedForwardSurveyError.captureFault
                }
                return try running.pump(drive: chunk)
            }.value
        } catch {
            guard generation == current else { return }
            dropEngine()
            retryCountdown = Self.retryPolls
            status = QuietZoneFeedForwardShadowStatus(
                state: .fault(QuietZoneFeedForwardSurveyError.captureFault.localizedDescription)
            )
            return
        }
        guard isActive, generation == current else { return }
        publish(snapshot, plan: running.plan)
    }

    /// Waits for closed captures to finish closing (tests).
    func flushForTesting() {
        closing?.waitForQueue()
        closing = nil
    }

    private func create(_ inputs: QuietZoneFeedForwardShadowInputs) async -> Bool {
        let current = generation
        let capture: QuietZoneFeedForwardPairCapturing
        do {
            capture = try captureFactory(inputs)
        } catch FeedForwardReferenceTransportError.invalidInput {
            return failCreation(QuietZoneFeedForwardSurveyError.referenceChannelUnavailable(inputs.referenceChannel))
        } catch {
            return failCreation(error)
        }
        let box = UncheckedCapture(capture)
        let echoModel = echoBlockedReason(inputs) == nil ? inputs.echoModel : nil
        let driveRate = echoModel == nil ? nil : driveSource?.driveSampleRate
        let made: Result<QuietZoneFeedForwardShadowEngine, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let plan = try QuietZoneFeedForwardShadowPlanner().plan(
                    bands: inputs.bands, design: inputs.design, budget: inputs.budget,
                    position: inputs.position, nativeSampleRate: box.capture.sampleRate
                )
                guard let engine = QuietZoneFeedForwardShadowEngine(
                    plan: plan, capture: box.capture, echo: echoModel, driveSampleRate: driveRate
                ) else {
                    throw QuietZoneFeedForwardShadowSeedError.unsupportedRate
                }
                try engine.start()
                return .success(engine)
            } catch {
                box.capture.close()
                return .failure(error)
            }
        }.value
        switch made {
        case .success(let created):
            guard isActive, generation == current, engine == nil else {
                created.close()
                return false
            }
            engine = created
            watch = QuietZoneFeedForwardShadowWatch()
            removalWatch = FeedForwardRemovalWatch()
            setDemand(created.echoActive)
            enginesCreated += 1
            return true
        case .failure(let error):
            guard generation == current else { return false }
            return failCreation(error)
        }
    }

    private func failCreation(_ error: Error) -> Bool {
        retryCountdown = Self.retryPolls
        status = QuietZoneFeedForwardShadowStatus(state: .waiting(error.localizedDescription))
        return false
    }

    /// Why echo removal cannot run now (nil when it can). Question 15: off with a subwoofer.
    func echoBlockedReason(_ inputs: QuietZoneFeedForwardShadowInputs) -> String? {
        guard FeatureFlags().isEnabled(.feedForwardLive) || forceEchoForTesting else {
            return "Echo removal is off (feature flag)."
        }
        guard inputs.echoModel != nil else { return "Measure speaker leakage to enable echo removal." }
        guard let driveSource else { return "No speaker drive from the engine." }
        guard driveSource.driveSampleRate != nil else { return "No speaker drive from the engine." }
        if driveSource.subwooferActive { return "Echo removal is off with a subwoofer or bass management." }
        return nil
    }

    /// Tests only: bypasses the feature flag.
    var forceEchoForTesting = false

    private func setDemand(_ requested: Bool) {
        guard demandSet != requested else { return }
        demandSet = requested
        driveSource?.setDriveDemand(requested)
    }

    private func dropEngine() {
        setDemand(false)
        generation += 1
        engine?.close()
        if let engine { closing = engine }
        engine = nil
    }

    private func publish(_ snapshot: QuietZoneFeedForwardShadowEngine.Snapshot, plan: QuietZoneFeedForwardShadowPlan) {
        let s = snapshot.status
        let db = { (power: Float) in 10 * log10(max(Double(power), 1.0e-30)) }
        status = QuietZoneFeedForwardShadowStatus(
            state: .adapting,
            sampleRate: plan.nativeSampleRate,
            decimatedRate: s.decimatedRate,
            seedSource: plan.seedSource,
            comparison: .compare(plan: plan, shadowLeft: snapshot.left, shadowRight: snapshot.right),
            guardState: watch.observe(s),
            measuredDBFS: db(s.measuredPower),
            predictedDBFS: db(s.predictedPower),
            weightGainDB: [s.weightGain.0, s.weightGain.1].map { 20 * log10(max(Double($0), 1.0e-12)) },
            adaptedSeconds: Double(s.samplesSinceRestart) / max(s.decimatedRate, 1),
            gaps: s.gaps,
            modelResets: s.modelResets,
            gainLimited: s.gainLimited,
            echo: echoReadout(snapshot, status: s)
        )
    }

    private func echoReadout(
        _ snapshot: QuietZoneFeedForwardShadowEngine.Snapshot, status s: N60FeedForwardShadowStatus
    ) -> QuietZoneFeedForwardEchoReadout {
        guard let inputs else { return .off }
        if let reason = echoBlockedReason(inputs) { return QuietZoneFeedForwardEchoReadout(alignment: .off(reason)) }
        let stability = FeedForwardLeakageStabilityCheck.evaluate(
            model: inputs.echoModel, weightsLeft: snapshot.left, weightsRight: snapshot.right
        )
        var readout = QuietZoneFeedForwardEchoReadout(alignment: .waiting("starting"), stability: stability)
        readout.driftPPM = snapshot.driftPPM
        switch s.echoState {
        case UInt32(N60_FF_ECHO_LOCKED):
            readout.alignment = .locked
            readout.offsetSamples = Int(s.echoOffset)
            if s.referencePowerAfter > 0, s.referencePowerBefore > 0 {
                readout.removalDB = 10 * log10(Double(s.referencePowerBefore) / Double(s.referencePowerAfter))
            }
        case UInt32(N60_FF_ECHO_SEARCHING):
            readout.alignment = .searching
        default:
            readout.alignment = .waiting(snapshot.alignmentNote ?? "waiting for programme")
        }
        removalWatch.observe(
            locked: s.echoState == UInt32(N60_FF_ECHO_LOCKED), removalDB: readout.removalDB,
            drivePower: s.drivePower, dt: Double(Self.pollNanoseconds) * 1.0e-9
        )
        readout.measureAgain = removalWatch.stale
        return readout
    }
}

/// Hands a freshly made capture to the worker that starts it; nothing else
/// touches it until the engine owns it.
private struct UncheckedCapture: @unchecked Sendable {
    let capture: QuietZoneFeedForwardPairCapturing
    init(_ capture: QuietZoneFeedForwardPairCapturing) { self.capture = capture }
}
