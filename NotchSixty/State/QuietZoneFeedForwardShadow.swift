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
    }

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

    init?(plan: QuietZoneFeedForwardShadowPlan, capture: QuietZoneFeedForwardPairCapturing) {
        guard capture.sampleRate == plan.nativeSampleRate else { return nil }
        var config = N60FeedForwardShadowConfigDefault(plan.nativeSampleRate)
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
        self.plan = plan
        self.capture = capture
        self.core = core
        sampleRate = plan.nativeSampleRate
        taps = Int(config.taps)
    }

    deinit { N60FeedForwardShadowDestroy(core) }

    func start() throws { try queue.sync { try capture.start() } }

    /// Drains the capture (up to one second). A jump in sample time (a lost
    /// callback) marks a gap. A capture fault throws.
    func pump() throws -> Snapshot {
        try queue.sync {
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
            return Snapshot(status: N60FeedForwardShadowReadStatus(core), left: left, right: right)
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
                }
            }
            reference.append(frame.sample)
            error.append(samples[i])
        }
        nextSampleTime = last.firstFrameSampleTime + Double(last.frameOffset) + 1
        flush()
    }

    private func flush() {
        guard !reference.isEmpty else { return }
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

    static let inactive = QuietZoneFeedForwardShadowStatus(state: .inactive)
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

    private(set) var isActive = false
    /// Shadows created so far (each rate, device or survey change makes one).
    private(set) var enginesCreated = 0
    private var inputs: QuietZoneFeedForwardShadowInputs?
    private var waitingReason = "Measure the feed-forward design first."
    private var engine: QuietZoneFeedForwardShadowEngine?
    private var closing: QuietZoneFeedForwardShadowEngine?
    private var watch = QuietZoneFeedForwardShadowWatch()
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
        let snapshot: QuietZoneFeedForwardShadowEngine.Snapshot
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                // A nominal-rate change need not fault the capture: check it.
                if let now = rate(device), now != running.sampleRate {
                    throw QuietZoneFeedForwardSurveyError.captureFault
                }
                return try running.pump()
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
        let made: Result<QuietZoneFeedForwardShadowEngine, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let plan = try QuietZoneFeedForwardShadowPlanner().plan(
                    bands: inputs.bands, design: inputs.design, budget: inputs.budget,
                    position: inputs.position, nativeSampleRate: box.capture.sampleRate
                )
                guard let engine = QuietZoneFeedForwardShadowEngine(plan: plan, capture: box.capture) else {
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

    private func dropEngine() {
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
            gainLimited: s.gainLimited
        )
    }
}

/// Hands a freshly made capture to the worker that starts it; nothing else
/// touches it until the engine owns it.
private struct UncheckedCapture: @unchecked Sendable {
    let capture: QuietZoneFeedForwardPairCapturing
    init(_ capture: QuietZoneFeedForwardPairCapturing) { self.capture = capture }
}
