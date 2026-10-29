import Combine
import Foundation

/// E4 S6: the offline tonal design for one tone, as the adaptive core is
/// seeded from it. Paths and outputs are in the microphone basis.
struct AdaptiveQuietZoneSeed: Equatable, Sendable {
    var frequencyHz: Double
    var leftPath: ActiveQuietZoneComplex
    var rightPath: ActiveQuietZoneComplex
    var leftOutput: ActiveQuietZoneComplex
    var rightOutput: ActiveQuietZoneComplex
}

/// One adaptive tone: a single complex weight W drives the left and right
/// speakers as (leftShare W, rightShare W), the split of the offline design.
/// One error microphone cannot tell the speakers apart, so the split stays
/// fixed and the path the core sees is leftShare S_L + rightShare S_R.
struct AdaptiveQuietZoneShadowTone: Equatable, Sendable {
    /// Seeds recomputed from fresh measurements differ by noise; the core is
    /// kept unless a tone's frequency changes or its path or split moves by
    /// more than these.
    static let pathToleranceDB = 0.5
    static let pathToleranceDegrees = 5.0

    func isClose(to other: AdaptiveQuietZoneShadowTone) -> Bool {
        func close(_ a: ActiveQuietZoneComplex, _ b: ActiveQuietZoneComplex) -> Bool {
            let floor = 1.0e-9
            if a.magnitude < floor || b.magnitude < floor {
                return abs(a.magnitude - b.magnitude) < 1.0e-6
            }
            let ratio = a / b
            let degrees = abs(atan2(ratio.imaginary, ratio.real)) * 180 / .pi
            return abs(20 * log10(ratio.magnitude)) <= Self.pathToleranceDB
                && degrees <= Self.pathToleranceDegrees
        }
        return frequencyHz == other.frequencyHz
            && close(path, other.path)
            && close(leftShare, other.leftShare)
            && close(rightShare, other.rightShare)
    }

    static func sameDesign(_ a: [AdaptiveQuietZoneShadowTone], _ b: [AdaptiveQuietZoneShadowTone]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.isClose(to: $1) }
    }

    var frequencyHz: Double
    var leftShare: ActiveQuietZoneComplex
    var rightShare: ActiveQuietZoneComplex
    var path: ActiveQuietZoneComplex
    /// sqrt(|L|^2 + |R|^2) of the offline outputs: the offline design's W.
    var offlineMagnitude: Double

    static func tones(from seeds: [AdaptiveQuietZoneSeed]) -> [AdaptiveQuietZoneShadowTone] {
        seeds
            .filter {
                $0.frequencyHz >= Double(N60_ACTIVE_QUIET_ZONE_MIN_HZ)
                    && $0.frequencyHz <= Double(N60_ACTIVE_QUIET_ZONE_MAX_HZ)
            }
            .prefix(Int(N60_FXLMS_MAX_TONES))
            .map { seed in
                let norm = hypot(seed.leftOutput.magnitude, seed.rightOutput.magnitude)
                let left: ActiveQuietZoneComplex
                let right: ActiveQuietZoneComplex
                if norm > 1.0e-9 {
                    left = seed.leftOutput / norm
                    right = seed.rightOutput / norm
                } else {
                    left = ActiveQuietZoneComplex(real: 0.5.squareRoot(), imaginary: 0)
                    right = left
                }
                return AdaptiveQuietZoneShadowTone(
                    frequencyHz: seed.frequencyHz,
                    leftShare: left,
                    rightShare: right,
                    path: left * seed.leftPath + right * seed.rightPath,
                    offlineMagnitude: norm
                )
            }
    }
}

// E4 S18b: the route from adaptive weights to output is `AdaptiveTonalOutputGate` (the shadow
// itself holds no engine handle and plays nothing).

struct AdaptiveQuietZoneShadowToneStatus: Identifiable, Equatable, Sendable {
    var frequencyHz: Double
    var adapting: Bool
    /// The shadow weight, and the offline design's, as peak dBFS. Both are
    /// peak amplitudes in the microphone basis: the core's output is
    /// Re(W exp(j phase)) and the planner's outputs are the same phasors.
    /// The offline value is sqrt(|L|^2 + |R|^2).
    var weightDBFS: Double
    var offlineDBFS: Double
    /// Path estimate used (the offline seed; no probe in shadow).
    var pathGainDB: Double
    var pathPhaseDegrees: Double
    /// Tone level at the error microphone, measured and as predicted with the
    /// shadow output added.
    var measuredDBFS: Double
    var predictedDBFS: Double

    var id: Double { frequencyHz }
    var predictedReductionDB: Double { measuredDBFS - predictedDBFS }
}

struct AdaptiveQuietZoneShadowStatus: Equatable, Sendable {
    enum State: String, Equatable, Sendable {
        case inactive
        case waitingForTones
        case waitingForMicrophone
        case adapting
        case unsupportedRate

        var displayName: String {
            switch self {
            case .inactive: return "Off"
            case .waitingForTones: return "Waiting for tones"
            case .waitingForMicrophone: return "Waiting for microphone"
            case .adapting: return "Adapting (shadow)"
            case .unsupportedRate: return "Unsupported rate"
            }
        }
    }

    enum Guard: Equatable, Sendable {
        case arming
        case clear
        case wouldHaveTripped(String)
    }

    var state: State
    var sampleRate: Double?
    var tones: [AdaptiveQuietZoneShadowToneStatus]
    var guardState: Guard
    var gaps: UInt64
    var modelResets: UInt64
    /// Microphone blocks dropped because the shadow queue fell behind.
    var droppedBlocks: UInt64 = 0

    static let inactive = AdaptiveQuietZoneShadowStatus(
        state: .inactive, sampleRate: nil, tones: [], guardState: .arming, gaps: 0, modelResets: 0
    )
}

/// The adaptive core and its howl guard, run off the main thread. The core's
/// output is metered and discarded: this type holds no engine or render
/// handle, so nothing it computes can reach the device.
final class AdaptiveQuietZoneShadowEngine: @unchecked Sendable {
    static let chunkFrames = 512
    /// The guard arms (and re-arms after any gap) after three convergence
    /// times: the core's start-up rise from silence is faster than the guard's
    /// fade-in contract allows. In shadow the guard checks growth, non-finite
    /// samples and the ceiling on the unplayed output; its error-rise check is
    /// off (no baseline), since the real error cannot respond to it.
    static let guardArmConvergenceTimes = 3.0

    let sampleRate: Double
    let tones: [AdaptiveQuietZoneShadowTone]

    private let queue = DispatchQueue(
        label: "notchsixty.adaptive-quiet-zone.shadow", qos: .userInitiated
    )
    private let core: OpaquePointer
    private let guardRef: OpaquePointer
    private let guardArmFrames: UInt64
    private var processedFrames: UInt64 = 0
    private var guardArmed = false
    private var output = [Float](repeating: 0, count: AdaptiveQuietZoneShadowEngine.chunkFrames)

    init?(sampleRate: Double, tones: [AdaptiveQuietZoneShadowTone]) {
        var config = N60AdaptiveTonalConfigDefault(sampleRate)
        config.shadow = true
        config.toneCount = UInt32(tones.count)
        withUnsafeMutableBytes(of: &config.toneHz) { raw in
            let hz = raw.bindMemory(to: Float.self)
            for (k, tone) in tones.enumerated() { hz[k] = Float(tone.frequencyHz) }
        }
        withUnsafeMutableBytes(of: &config.toneSeed) { raw in
            let seed = raw.bindMemory(to: N60AncComplex.self)
            for (k, tone) in tones.enumerated() {
                seed[k] = N60AncComplex(re: Float(tone.path.real), im: Float(tone.path.imaginary))
            }
        }
        var guardConfig = N60AncGuardConfigDefault(sampleRate)
        guard let core = N60AdaptiveTonalCreate(&config) else { return nil }
        guard let guardRef = N60AncGuardCreate(&guardConfig) else {
            N60AdaptiveTonalDestroy(core)
            return nil
        }
        self.sampleRate = sampleRate
        self.tones = tones
        self.core = core
        self.guardRef = guardRef
        guardArmFrames = UInt64(Self.guardArmConvergenceTimes * config.convergenceSeconds * sampleRate)
    }

    deinit {
        N60AdaptiveTonalDestroy(core)
        N60AncGuardDestroy(guardRef)
    }

    func submit(
        _ frames: [Float],
        discontinuity: Bool,
        completion: @escaping @Sendable (N60AdaptiveTonalStatus, N60AncGuardStatus?) -> Void
    ) {
        queue.async { [self] in
            if discontinuity {
                N60AdaptiveTonalMarkDiscontinuity(core)
                processedFrames = 0
                guardArmed = false
            }
            frames.withUnsafeBufferPointer { error in
                output.withUnsafeMutableBufferPointer { out in
                    var start = 0
                    while start < error.count {
                        let count = min(Self.chunkFrames, error.count - start)
                        let e = error.baseAddress! + start
                        N60AdaptiveTonalProcess(core, e, out.baseAddress!, UInt32(count))
                        _ = N60AncGuardProcess(guardRef, out.baseAddress!, nil, e, UInt32(count))
                        N60AdaptiveTonalService(core)
                        start += count
                    }
                }
            }
            processedFrames += UInt64(frames.count)
            if !guardArmed, processedFrames >= guardArmFrames {
                N60AncGuardRequestRearm(guardRef)
                guardArmed = true
            }
            completion(
                N60AdaptiveTonalReadStatus(core),
                guardArmed ? N60AncGuardReadStatus(guardRef) : nil
            )
        }
    }

    func flush() { queue.sync {} }
}

/// E4 S6: the adaptive tonal canceller in shadow mode. It takes the error
/// microphone from the ambient monitor, seeds itself from the live tonal
/// design, adapts on the virtual error, and reports what it would do. It is
/// active only while the app shell turns it on.
@MainActor
final class AdaptiveQuietZoneShadow: ObservableObject {
    @Published private(set) var status = AdaptiveQuietZoneShadowStatus.inactive

    private(set) var isActive = false
    private var seeds: [AdaptiveQuietZoneSeed] = []
    private var engine: AdaptiveQuietZoneShadowEngine?
    private var epoch: UUID?
    private var generation = 0
    private var pendingResults = 0
    private var submitted: UInt64 = 0
    private var lastApplied: UInt64 = 0
    private var droppedBlocks: UInt64 = 0
    private var dropPending = false
    /// Microphone blocks allowed in flight before new ones are dropped.
    static let maximumPendingBlocks = 8
    private var seedObservation: AnyCancellable?

    var hasEngine: Bool { engine != nil }

    init(quietZone: ActiveQuietZoneController? = nil, ambient: AmbientCompensationController? = nil) {
        seedObservation = quietZone?.$adaptiveSeeds.sink { [weak self] seeds in
            self?.updateSeeds(seeds)
        }
        ambient?.microphoneFramesObserver = { [weak self] frames, rate, epoch, skipped in
            self?.receiveMicrophoneFrames(frames, sampleRate: rate, epoch: epoch, skipped: skipped)
        }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if !active {
            dropEngine()
            status = .inactive
        } else {
            status.state = AdaptiveQuietZoneShadowTone.tones(from: seeds).isEmpty
                ? .waitingForTones : .waitingForMicrophone
        }
    }

    func updateSeeds(_ newSeeds: [AdaptiveQuietZoneSeed]) {
        seeds = newSeeds
        guard isActive else { return }
        let tones = AdaptiveQuietZoneShadowTone.tones(from: newSeeds)
        if tones.isEmpty {
            dropEngine()
            status = AdaptiveQuietZoneShadowStatus(
                state: .waitingForTones, sampleRate: nil, tones: [], guardState: .arming,
                gaps: 0, modelResets: 0
            )
        } else if let engine, !AdaptiveQuietZoneShadowTone.sameDesign(engine.tones, tones) {
            dropEngine()
            status.state = .waitingForMicrophone
        }
    }

    func receiveMicrophoneFrames(
        _ frames: [Float],
        sampleRate: Double,
        epoch: UUID,
        skipped: Bool = false
    ) {
        guard isActive, !frames.isEmpty else { return }
        let tones = AdaptiveQuietZoneShadowTone.tones(from: seeds)
        guard !tones.isEmpty else {
            status.state = .waitingForTones
            return
        }
        if pendingResults >= Self.maximumPendingBlocks {
            droppedBlocks += 1
            dropPending = true
            return
        }
        var discontinuity = epoch != self.epoch || skipped || dropPending
        dropPending = false
        if engine == nil || engine?.sampleRate != sampleRate
            || !AdaptiveQuietZoneShadowTone.sameDesign(engine?.tones ?? [], tones) {
            dropEngine()
            guard let created = AdaptiveQuietZoneShadowEngine(sampleRate: sampleRate, tones: tones) else {
                status = AdaptiveQuietZoneShadowStatus(
                    state: .unsupportedRate, sampleRate: sampleRate, tones: [], guardState: .arming,
                    gaps: 0, modelResets: 0
                )
                return
            }
            engine = created
            discontinuity = false
        }
        self.epoch = epoch
        guard let engine else { return }
        let current = generation
        pendingResults += 1
        submitted += 1
        let order = submitted
        engine.submit(frames, discontinuity: discontinuity) { [weak self] core, guardStatus in
            Task { @MainActor in
                guard let self else { return }
                self.pendingResults -= 1
                // Results hop to the main actor in separate tasks; never let
                // an older one overwrite a newer one.
                guard self.generation == current, self.isActive, order > self.lastApplied else { return }
                self.lastApplied = order
                self.apply(core: core, guardStatus: guardStatus, engine: engine)
            }
        }
    }

    /// Waits for queued frames, then for their results to reach `status`.
    func flushForTesting() async {
        engine?.flush()
        while pendingResults > 0 { await Task.yield() }
    }

    private static func tripName(_ trip: N60AncGuardTrip) -> String {
        switch trip {
        case N60AncGuardTripGrowth: return "growth"
        case N60AncGuardTripErrorRise: return "error rise"
        case N60AncGuardTripNonFinite: return "non-finite sample"
        case N60AncGuardTripOverCeiling: return "over ceiling"
        default: return "none"
        }
    }

    private func dropEngine() {
        engine = nil
        epoch = nil
        generation += 1
    }

    private func apply(
        core: N60AdaptiveTonalStatus,
        guardStatus: N60AncGuardStatus?,
        engine: AdaptiveQuietZoneShadowEngine
    ) {
        func components<T>(_ tuple: T) -> [N60AncComplex] {
            withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: N60AncComplex.self)) }
        }
        let weights = components(core.weight)
        let paths = components(core.path)
        let measured = components(core.measuredTone)
        let predicted = components(core.predictedTone)
        let adapting = withUnsafeBytes(of: core.adapting) { Array($0.bindMemory(to: Bool.self)) }
        let db = { (value: Double) in 20 * log10(max(value, 1.0e-12)) }
        let magnitude = { (c: N60AncComplex) in hypot(Double(c.re), Double(c.im)) }
        let tones = engine.tones.enumerated().map { k, tone in
            AdaptiveQuietZoneShadowToneStatus(
                frequencyHz: tone.frequencyHz,
                adapting: adapting[k],
                weightDBFS: db(magnitude(weights[k])),
                offlineDBFS: db(tone.offlineMagnitude),
                pathGainDB: db(magnitude(paths[k])),
                pathPhaseDegrees: atan2(Double(paths[k].im), Double(paths[k].re)) * 180 / .pi,
                measuredDBFS: db(magnitude(measured[k])),
                predictedDBFS: db(magnitude(predicted[k]))
            )
        }
        let guardState: AdaptiveQuietZoneShadowStatus.Guard
        if let guardStatus {
            guardState = guardStatus.tripped
                ? .wouldHaveTripped(Self.tripName(guardStatus.trip)) : .clear
        } else {
            guardState = .arming
        }
        status = AdaptiveQuietZoneShadowStatus(
            state: .adapting,
            sampleRate: engine.sampleRate,
            tones: tones,
            guardState: guardState,
            gaps: core.gaps,
            modelResets: core.modelResets,
            droppedBlocks: droppedBlocks
        )
    }
}
