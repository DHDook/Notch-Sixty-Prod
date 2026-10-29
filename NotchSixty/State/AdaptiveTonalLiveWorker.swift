import Darwin
import Foundation

/// What the control plane asks of the worker for the next microphone block.
struct AdaptiveTonalLiveCommand: Equatable, Sendable {
    /// The gate is open: publish the adapting gains.
    var writeEnabled = false
    /// Publish the held gains at the silent cap (the ramp-out before a new baseline). Safe at any
    /// time: it can only lower the output.
    var silence = false
    /// Freeze the weights; the path fit keeps running.
    var hold = false
    /// Extra peak cap on the mailbox record (linear per channel); 0 = none.
    var attemptCapLinear: Float = 0
    /// The token the kernel holds for this arm (never 0).
    var armGeneration: UInt64 = 0
    /// Faster path memory and larger dither while true.
    var reidentify = false
    /// One-shot: re-seed the weights as W Sold / Snew and make the new path the reference.
    var reseedFromReference = false
    /// One-shot: clear the latched mic-moved flag.
    var acknowledgeMove = false
}

/// The worker's summary of one block, for the control plane. Plain values, no pointers.
struct AdaptiveTonalLiveReport: Equatable, Sendable {
    var blocks: UInt64 = 0
    var uncoveredBlocks: UInt64 = 0
    var gaps: UInt64 = 0
    var modelResets: UInt64 = 0
    var recordsPublished: UInt64 = 0
    var recordsRejected: UInt64 = 0
    var micMoved = false
    var anyAdapting = false
    var pathFault = false
    var pathStepDegrees = 0.0
    var pathRateDegreesPerSecond = 0.0
    /// 20 log10 of the sum of |W| over the tones (peak, microphone basis).
    var weightLevelDBFS = -240.0
    /// Peak per channel the weights would play: sum over tones of |W| max(|sL|, |sR|).
    var playedPeakLinear = 0.0
    var guardTripped = false
    var guardTripName = "none"
    var tones: [Tone] = []

    struct Tone: Equatable, Sendable {
        var frequencyHz: Double
        var weightDBFS: Double
        var pathPhaseDegrees: Double
        var pathLevelDB: Double
        var adapting: Bool
    }
}

/// The adaptive tonal core, its closed-loop howl guard and the mailbox writer, run off the main
/// thread (E4 S18b). One serial queue: every call into the C core and into the link happens on it.
///
/// Realtime: this is not an audio thread. It never touches the render thread except through the
/// link (a lock-free mailbox and telemetry ring). Allocation happens at creation and for the
/// per-block sample buffers only.
final class AdaptiveTonalLiveWorker: @unchecked Sendable {
    static let chunkFrames = 512
    static let guardArmConvergenceTimes = 3.0
    /// The silent cap: far below any audible level, never zero (zero means "no extra cap").
    static let silentCapLinear: Float = 1.0e-6

    let sampleRate: Double
    let tones: [AdaptiveQuietZoneShadowTone]

    private let queue = DispatchQueue(label: "notchsixty.adaptive-tonal.live", qos: .userInitiated)
    private let core: OpaquePointer
    private let guardRef: OpaquePointer
    private let link: any AdaptiveTonalLiveLink
    private let guardArmFrames: UInt64
    private var processedFrames: UInt64 = 0
    private var guardArmed = false
    private var guardTripReported = false
    private var reidentifying = false
    private var held = false
    private var phases: [Double]
    private var scratch = [Float](repeating: 0, count: AdaptiveTonalLiveWorker.chunkFrames)
    private var previousPathPhases: [Double] = []
    private var previousReportSeconds: Double?
    private var published: UInt64 = 0
    private var rejected: UInt64 = 0
    private var shares: [(left: Double, right: Double)]

    /// Host ticks per second from the mach timebase.
    static var hostTicksPerSecond: Double {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0 else { return 1.0e9 }
        return 1.0e9 * Double(info.denom) / Double(info.numer)
    }

    init?(
        sampleRate: Double,
        tones: [AdaptiveQuietZoneShadowTone],
        hostTicksPerSecond: Double = AdaptiveTonalLiveWorker.hostTicksPerSecond,
        ditherSeed: UInt64 = 0x4E36_3053_4C49_5645,
        link: any AdaptiveTonalLiveLink
    ) {
        guard !tones.isEmpty, tones.count <= Int(N60_FXLMS_MAX_TONES) else { return nil }
        var config = N60RemoteTonalConfigDefault(sampleRate, hostTicksPerSecond)
        config.toneCount = UInt32(tones.count)
        config.ditherSeed = ditherSeed
        withUnsafeMutableBytes(of: &config.toneHz) { raw in
            let hz = raw.bindMemory(to: Float.self)
            for (k, tone) in tones.enumerated() { hz[k] = Float(tone.frequencyHz) }
        }
        func complex(_ c: ActiveQuietZoneComplex) -> N60AncComplex {
            N60AncComplex(re: Float(c.real), im: Float(c.imaginary))
        }
        withUnsafeMutableBytes(of: &config.leftShare) { raw in
            let v = raw.bindMemory(to: N60AncComplex.self)
            for (k, tone) in tones.enumerated() { v[k] = complex(tone.leftShare) }
        }
        withUnsafeMutableBytes(of: &config.rightShare) { raw in
            let v = raw.bindMemory(to: N60AncComplex.self)
            for (k, tone) in tones.enumerated() { v[k] = complex(tone.rightShare) }
        }
        withUnsafeMutableBytes(of: &config.pathSeed) { raw in
            let v = raw.bindMemory(to: N60AncComplex.self)
            for (k, tone) in tones.enumerated() { v[k] = complex(tone.path) }
        }
        withUnsafeMutableBytes(of: &config.weightSeed) { raw in
            let v = raw.bindMemory(to: N60AncComplex.self)
            for (k, tone) in tones.enumerated() {
                v[k] = N60AncComplex(re: Float(tone.offlineMagnitude), im: 0)
            }
        }
        var guardConfig = N60AncGuardConfigDefault(sampleRate)
        guard N60RemoteTonalConfigIsValid(&config), let core = N60RemoteTonalCreate(&config) else {
            return nil
        }
        guard let guardRef = N60AncGuardCreate(&guardConfig) else {
            N60RemoteTonalDestroy(core)
            return nil
        }
        self.sampleRate = sampleRate
        self.tones = tones
        self.core = core
        self.guardRef = guardRef
        self.link = link
        self.phases = Array(repeating: 0, count: tones.count)
        self.shares = tones.map { ($0.leftShare.magnitude, $0.rightShare.magnitude) }
        self.guardArmFrames = UInt64(Self.guardArmConvergenceTimes * config.convergenceSeconds * sampleRate)
    }

    deinit {
        N60RemoteTonalDestroy(core)
        N60AncGuardDestroy(guardRef)
    }

    /// One microphone block. `hostTime` is the first frame's host time (nil: no anchor, the block
    /// is skipped by the core and counted as a gap). `now` is any monotonic clock in seconds.
    func submit(
        _ samples: [Float],
        hostTime: UInt64?,
        discontinuity: Bool,
        now: Double,
        command: AdaptiveTonalLiveCommand,
        completion: @escaping @Sendable (AdaptiveTonalLiveReport) -> Void
    ) {
        queue.async { [self] in
            guard !isRetired else { return }
            completion(step(samples, hostTime: hostTime, discontinuity: discontinuity, now: now, command: command))
        }
    }

    func flush() { queue.sync {} }

    private let retiredLock = NSLock()
    private var retiredFlag = false
    private var isRetired: Bool {
        retiredLock.lock()
        defer { retiredLock.unlock() }
        return retiredFlag
    }

    /// Stops this worker touching the link or the core and waits for the step in flight. After it
    /// returns, a replacement worker is the only writer of the gain mailbox and the only reader of
    /// the telemetry ring (both are single-party).
    func retire() {
        retiredLock.lock()
        retiredFlag = true
        retiredLock.unlock()
        queue.sync {}
    }

    // MARK: - Worker queue

    private func step(
        _ samples: [Float],
        hostTime: UInt64?,
        discontinuity: Bool,
        now: Double,
        command: AdaptiveTonalLiveCommand
    ) -> AdaptiveTonalLiveReport {
        if discontinuity || hostTime == nil {
            N60RemoteTonalMarkDiscontinuity(core)
            processedFrames = 0
            guardArmed = false
        }
        var drained = 0
        while drained < Int(N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY), var record = link.popTelemetry() {
            N60RemoteTonalPushTelemetry(core, &record)
            drained += 1
        }

        apply(command)
        if let hostTime, !samples.isEmpty {
            samples.withUnsafeBufferPointer { buffer in
                _ = N60RemoteTonalProcessMic(core, buffer.baseAddress!, UInt32(buffer.count), hostTime)
            }
            runGuard(on: samples)
        }

        let status = N60RemoteTonalReadStatus(core)
        publishIfWanted(command, status: status)
        return report(from: status, now: now)
    }

    private func apply(_ command: AdaptiveTonalLiveCommand) {
        let shouldHold = command.hold || command.silence
        if shouldHold != held {
            N60RemoteTonalSetHold(core, shouldHold)
            held = shouldHold
        }
        if command.reidentify != reidentifying {
            if command.reidentify { N60RemoteTonalBeginReidentify(core) } else { N60RemoteTonalEndReidentify(core) }
            reidentifying = command.reidentify
        }
        if command.reseedFromReference {
            let status = N60RemoteTonalReadStatus(core)
            var weights = Self.components(status.weight, count: tones.count)
            let paths = Self.components(status.path, count: tones.count)
            let references = Self.components(status.referencePath, count: tones.count)
            for k in weights.indices {
                let pathMagnitude = hypot(paths[k].re, paths[k].im)
                guard pathMagnitude > 1.0e-9 else { continue }
                // W * Sold / Snew keeps the predicted anti-noise at the microphone unchanged.
                weights[k] = Self.divide(Self.multiply(weights[k], references[k]), paths[k])
            }
            _ = N60RemoteTonalSetWeights(core, weights, UInt32(weights.count))
            N60RemoteTonalCaptureReference(core)
            N60AncGuardRequestRearm(guardRef)
        }
        if command.acknowledgeMove { N60RemoteTonalAcknowledgeMove(core) }
    }

    private func runGuard(on samples: [Float]) {
        let status = N60RemoteTonalReadStatus(core)
        let weights = Self.components(status.weight, count: tones.count)
        var start = 0
        while start < samples.count {
            let count = min(Self.chunkFrames, samples.count - start)
            // The reconstructed anti-noise at the microphone rate: sum_k Re(W_k exp(j phase_k)).
            for n in 0 ..< count {
                var value = 0.0
                for k in 0 ..< tones.count {
                    value += Double(weights[k].re) * cos(phases[k]) - Double(weights[k].im) * sin(phases[k])
                    phases[k] += 2 * Double.pi * tones[k].frequencyHz / sampleRate
                    if phases[k] > 2 * Double.pi { phases[k] -= 2 * Double.pi }
                }
                scratch[n] = Float(value)
            }
            samples.withUnsafeBufferPointer { error in
                scratch.withUnsafeMutableBufferPointer { out in
                    _ = N60AncGuardProcess(guardRef, out.baseAddress!, nil, error.baseAddress! + start, UInt32(count))
                }
            }
            start += count
        }
        processedFrames += UInt64(samples.count)
        if !guardArmed, processedFrames >= guardArmFrames {
            N60AncGuardRequestRearm(guardRef)
            guardArmed = true
        }
        if guardArmed, N60AncGuardReadStatus(guardRef).tripped, !guardTripReported {
            // The same 20 ms fade as a kernel trip; the arm then disarms on the trip count.
            guardTripReported = true
            link.requestHowlTrip()
        }
    }

    private func publishIfWanted(_ command: AdaptiveTonalLiveCommand, status: N60RemoteTonalStatus) {
        guard command.writeEnabled || command.silence, command.armGeneration != 0, !guardTripReported else { return }
        let cap = command.silence ? Self.silentCapLinear : command.attemptCapLinear
        var record = N60ActiveQuietZoneGainRecord()
        guard N60RemoteTonalNextRecord(core, command.armGeneration, cap, &record) else { return }
        if command.silence { record.attemptCapLinear = Self.silentCapLinear }
        if link.publish(record) == 0 { rejected += 1 } else { published += 1 }
    }

    private func report(from status: N60RemoteTonalStatus, now: Double) -> AdaptiveTonalLiveReport {
        var report = AdaptiveTonalLiveReport()
        report.blocks = status.blocks
        report.uncoveredBlocks = status.uncoveredBlocks
        report.gaps = status.gaps
        report.modelResets = status.modelResets
        report.recordsPublished = published
        report.recordsRejected = rejected
        report.micMoved = status.micMoved
        let weights = Self.components(status.weight, count: tones.count)
        let paths = Self.components(status.path, count: tones.count)
        let phaseDeg = Self.floats(status.pathPhaseDegrees, count: tones.count)
        let levelDB = Self.floats(status.pathLevelDB, count: tones.count)
        let adapting = withUnsafeBytes(of: status.adapting) { Array($0.bindMemory(to: Bool.self).prefix(tones.count)) }
        var sum = 0.0
        var peak = 0.0
        var step = 0.0
        var currentPhases: [Double] = []
        var fault = false
        for k in 0 ..< tones.count {
            let w = hypot(Double(weights[k].re), Double(weights[k].im))
            if !w.isFinite || !Double(paths[k].re).isFinite || !Double(paths[k].im).isFinite { fault = true }
            sum += w
            peak += w * max(shares[k].left, shares[k].right)
            let phase = atan2(Double(paths[k].im), Double(paths[k].re)) * 180 / .pi
            currentPhases.append(phase)
            if previousPathPhases.count == tones.count {
                var delta = abs(phase - previousPathPhases[k])
                if delta > 180 { delta = 360 - delta }
                step = max(step, delta)
            }
            report.tones.append(.init(
                frequencyHz: tones[k].frequencyHz,
                weightDBFS: 20 * log10(max(w, 1.0e-12)),
                pathPhaseDegrees: Double(phaseDeg[k]),
                pathLevelDB: Double(levelDB[k]),
                adapting: adapting[k]
            ))
        }
        report.anyAdapting = adapting.contains(true)
        report.pathFault = fault
        report.weightLevelDBFS = 20 * log10(max(sum, 1.0e-12))
        report.playedPeakLinear = peak
        report.pathStepDegrees = step
        if let last = previousReportSeconds, now > last, previousPathPhases.count == tones.count {
            report.pathRateDegreesPerSecond = step / (now - last)
        }
        previousPathPhases = currentPhases
        previousReportSeconds = now
        let guardStatus = N60AncGuardReadStatus(guardRef)
        report.guardTripped = guardArmed && guardStatus.tripped
        if report.guardTripped { report.guardTripName = Self.tripName(guardStatus.trip) }
        return report
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

    private static func components<T>(_ tuple: T, count: Int) -> [N60AncComplex] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: N60AncComplex.self).prefix(count)) }
    }

    private static func floats<T>(_ tuple: T, count: Int) -> [Float] {
        withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Float.self).prefix(count)) }
    }

    private static func multiply(_ a: N60AncComplex, _ b: N60AncComplex) -> N60AncComplex {
        N60AncComplex(re: a.re * b.re - a.im * b.im, im: a.re * b.im + a.im * b.re)
    }

    private static func divide(_ a: N60AncComplex, _ b: N60AncComplex) -> N60AncComplex {
        let d = b.re * b.re + b.im * b.im
        return N60AncComplex(re: (a.re * b.re + a.im * b.im) / d, im: (a.im * b.re - a.re * b.im) / d)
    }
}
