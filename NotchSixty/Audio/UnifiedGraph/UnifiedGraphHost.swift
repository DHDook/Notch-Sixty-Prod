import Foundation

enum UnifiedGraphError: Error, Equatable {
    case coreStatus(UInt32)
    case invalidConfiguration(String)
    case unsupportedConfiguration(String)
}

/// Outcome of `UnifiedGraphHost.apply`.
enum UnifiedGraphApplyResult: Equatable {
    case unchanged
    /// Same topology: only the changed parameters were posted (ramped inside the stages).
    case posted(count: Int)
    /// New topology: published, so the core warms it up and fades from the old graph.
    case published
}

/// Owns one libn60core graph on the control plane. Realtime use is limited to the graph
/// pointer handed to the bridge (`rawGraph`); everything else here runs on the control
/// thread and is serialised by a lock. The host must outlive any bridge that renders it.
///
/// Realtime notes (the documentation AGENTS.md section 4 asks for):
/// - allocation: none on the audio thread; the core allocates only in build and publish.
/// - synchronisation: the core's own wait-free snapshot swap and parameter mailbox.
/// - latency: `latencyFrames` reads `n60_graph_latency_frames`.
/// - rates: any native rate 8 kHz to 768 kHz; no resampling.
/// - channels: the spec decides; the stereo bridge hook requires two in and two out.
/// - reset: a rebuild fades from the old graph; the host never resets state in place.
final class UnifiedGraphHost: @unchecked Sendable {
    private let lock = NSLock()
    private var graph: OpaquePointer?
    private(set) var spec: UnifiedGraphSpec

    init(spec: UnifiedGraphSpec) throws {
        self.spec = spec
        var built: OpaquePointer?
        let status = spec.withDescription { n60_graph_build($0, &built) }
        guard status == N60_STATUS_OK, let built else {
            throw UnifiedGraphError.coreStatus(status.rawValue)
        }
        graph = built
    }

    deinit {
        release()
    }

    /// Retires the graph under the host lock, so a concurrent `meter`, `apply` or readback sees
    /// either the live graph or none, never a freed one. Idempotent. Only after the bridge that
    /// renders the graph has been destroyed.
    func release() {
        lock.lock(); defer { lock.unlock() }
        if let graph { n60_graph_retire(graph) }
        graph = nil
        // A registered EXTERNAL processor's context (E26 S7b2) is freed only after the graph is retired.
        retained = nil
    }

    /// An object the graph's EXTERNAL callback points at (the ANC lane feed). Kept alive until `release`, which
    /// retires the graph first. Set once, before IO starts.
    /// Read and written under the host lock (G25), so a control call racing `release()` sees the resource or nil, and
    /// holds a strong reference to it while it works.
    var retainedResource: AnyObject? {
        get { lock.lock(); defer { lock.unlock() }; return retained }
        set { lock.lock(); defer { lock.unlock() }; retained = newValue }
    }
    private var retained: AnyObject?

    /// E26 S7b2: sum of the trip counts of the guard stages, read from the newest published snapshot. Control thread.
    func guardTripCount(stageIds: [UInt32]) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return 0 }
        var total: UInt64 = 0
        for id in stageIds {
            var status = n60_guard_status()
            status.structSize = UInt32(MemoryLayout<n60_guard_status>.size)
            if n60_graph_read_guard(graph, id, &status) == N60_STATUS_OK { total &+= status.tripCount }
        }
        return total
    }

    /// The graph pointer for `N60RealtimeAudioBridgeSetUnifiedGraph`. Valid while the host lives.
    var rawGraph: UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        return graph.map { UnsafeMutableRawPointer($0) }
    }

    /// E27 S2c. Control plane, under the host lock. The newest `frames` samples of lanes 0 and 1 of an analyser tap
    /// stage, taken at one start index (so the channels stay aligned). nil when the stage is not in the live graph,
    /// holds fewer than `frames` samples since the last rebuild (a new snapshot starts empty), or the range was
    /// overwritten while reading (the seqlock refuses it).
    ///
    /// `since`: samples written before this index (the ring held them frozen while demand was off) are not used; a
    /// rebuild restarts the count, so a `since` above the current count is ignored.
    func readAnalyserTap(stageId: UInt32, frames: Int, since: UInt64 = 0) -> (left: [Float], right: [Float])? {
        lock.lock(); defer { lock.unlock() }
        return readAnalyserTapLocked(stageId: stageId, frames: frames, since: since)
    }

    /// E27 S4 (G17). Control plane. Remembers where the ring stands now, for `readAnalyserTapSinceBaseline`. The
    /// baselines live with the host and are dropped by a rebuild (a rebuild empties the rings), so a stale value can
    /// never hide the samples of the new ring.
    func markAnalyserTapBaseline(stageId: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return }
        var written: UInt64 = 0
        guard n60_graph_read_capture(graph, stageId, 0, 0, nil, 0, &written) == N60_STATUS_OK else { return }
        analyserTapBaselines[stageId] = written
    }

    /// The baseline marked for `stageId` (0 when none, or when a rebuild dropped it).
    func analyserTapBaseline(stageId: UInt32) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return analyserTapBaselines[stageId] ?? 0
    }

    func clearAnalyserTapBaselines() {
        lock.lock(); defer { lock.unlock() }
        analyserTapBaselines.removeAll()
    }

    /// `readAnalyserTap` using the stored baseline of the stage.
    func readAnalyserTapSinceBaseline(stageId: UInt32, frames: Int) -> (left: [Float], right: [Float])? {
        lock.lock(); defer { lock.unlock() }
        return readAnalyserTapLocked(stageId: stageId, frames: frames, since: analyserTapBaselines[stageId] ?? 0)
    }

    private var analyserTapBaselines: [UInt32: UInt64] = [:]

    private func readAnalyserTapLocked(stageId: UInt32, frames: Int, since: UInt64) -> (left: [Float], right: [Float])? {
        guard frames > 0, frames <= Int(UnifiedGraphAnalyserTaps.capacityFrames) / 2 else { return nil }
        guard let graph else { return nil }
        var written: UInt64 = 0
        guard n60_graph_read_capture(graph, stageId, 0, 0, nil, 0, &written) == N60_STATUS_OK,
              written >= UInt64(frames) else { return nil }
        let floor = since <= written ? since : 0
        guard written - floor >= UInt64(frames) else { return nil }
        let start = written - UInt64(frames)
        var lanes: [[Float]] = []
        for lane in UInt32(0)..<2 {
            var buffer = [Float](repeating: 0, count: frames)
            var after: UInt64 = 0
            let status = buffer.withUnsafeMutableBufferPointer {
                n60_graph_read_capture(graph, stageId, lane, start, $0.baseAddress, UInt32(frames), &after)
            }
            guard status == N60_STATUS_OK else { return nil }
            lanes.append(buffer)
        }
        return (lanes[0], lanes[1])
    }

    /// E27 S2c. Samples the tap has written so far (0 when the stage is absent).
    func analyserTapWritten(stageId: UInt32) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return 0 }
        var written: UInt64 = 0
        guard n60_graph_read_capture(graph, stageId, 0, 0, nil, 0, &written) == N60_STATUS_OK else { return 0 }
        return written
    }

    var inputChannels: UInt32 { lock.lock(); defer { lock.unlock() }; return spec.inputChannels }
    var outputChannels: UInt32 { lock.lock(); defer { lock.unlock() }; return spec.outputChannels }

    /// Moves the graph to `newSpec`: parameter posts when only live values differ, a
    /// faded rebuild otherwise. Safe to call while a bridge is rendering the graph.
    ///
    /// `linearFade`: a rebuild crossfades with the linear law (old * (1 - t) + new * t) instead of
    /// equal-power. Use it when old and new graphs carry the same signal, as an EQ bypass, A/B or
    /// audition switch does (E27 S3b): an equal-power fade of two copies of one signal at different
    /// gains swells past both by up to 3 percent in the middle.
    @discardableResult
    func apply(_ newSpec: UnifiedGraphSpec, linearFade: Bool = false) throws -> UnifiedGraphApplyResult {
        lock.lock(); defer { lock.unlock() }
        return try applyLocked(newSpec, linearFade: linearFade)
    }

    private var fadeLawLinear = false

    /// Control thread, under the lock. Sets the fade law stamped into the next published snapshot.
    /// Nothing else sets rebuild options; `fadeMs` repeats the core default (20 ms) so keep them equal.
    private func setFadeLaw(linear: Bool) {
        guard let graph, linear != fadeLawLinear else { return }
        var options = n60_rebuild_options(
            structSize: UInt32(MemoryLayout<n60_rebuild_options>.size),
            fadeMs: 20,
            cpuBudgetPercent: 0,
            reserved: linear ? 1 : 0
        )
        if n60_graph_set_rebuild_options(graph, &options) == N60_STATUS_OK { fadeLawLinear = linear }
    }

    /// Posts a head pose to the BINAURAL stage (yaw, pitch and roll are its live parameters 0 to 2;
    /// the stage glides between the response cells). Control thread; no rebuild and no spec copy:
    /// three parameter records go straight to the mailbox. Throws when the stage was built with a
    /// single orientation (head tracking off at build time), because the yaw would be ignored.
    @discardableResult
    func setBinauralPose(yaw: Float, pitch: Float, roll: Float) throws -> UnifiedGraphApplyResult {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { throw UnifiedGraphError.invalidConfiguration("graph released") }
        guard let index = spec.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_BINAURAL }),
              spec.stages[index].params.count >= 5 else {
            throw UnifiedGraphError.invalidConfiguration("no binaural stage")
        }
        guard spec.stages[index].params[4] > 1 else {
            throw UnifiedGraphError.unsupportedConfiguration("binaural stage has one orientation")
        }
        let values: [Float] = [
            Float(N60HeadPoseWrap180(Double(yaw))),
            min(180, max(-180, pitch)),
            min(180, max(-180, roll)),
        ]
        if values.enumerated().allSatisfy({ spec.stages[index].params[$0.offset] == $0.element }) {
            return .unchanged
        }
        let stageId = spec.stages[index].stageId
        let records = values.enumerated().map {
            n60_param_record(stageId: stageId, paramIndex: UInt32($0.offset), value: $0.element, reserved: 0)
        }
        let status = records.withUnsafeBufferPointer {
            n60_graph_post_params(graph, $0.baseAddress, UInt32($0.count))
        }
        guard status == N60_STATUS_OK else { throw UnifiedGraphError.coreStatus(status.rawValue) }
        for (offset, value) in values.enumerated() { spec.stages[index].params[offset] = value }
        return .posted(count: records.count)
    }

    private func applyLocked(_ newSpec: UnifiedGraphSpec, linearFade: Bool = false) throws -> UnifiedGraphApplyResult {
        guard let graph else { throw UnifiedGraphError.invalidConfiguration("graph released") }
        if newSpec == spec { return .unchanged }
        if newSpec.hasSameTopology(as: spec) {
            let records = newSpec.changedParameters(since: spec)
            if records.isEmpty {
                spec = newSpec
                return .unchanged
            }
            let status = records.withUnsafeBufferPointer {
                n60_graph_post_params(graph, $0.baseAddress, UInt32($0.count))
            }
            if status == N60_STATUS_OK {
                spec = newSpec
                return .posted(count: records.count)
            }
            if status != N60_STATUS_UNSUPPORTED && status != N60_STATUS_QUEUE_FULL {
                throw UnifiedGraphError.coreStatus(status.rawValue)
            }
            // A parameter that needs a new topology (or a full mailbox): publish instead.
        }
        setFadeLaw(linear: linearFade)
        let status = newSpec.withDescription { n60_graph_publish(graph, $0) }
        guard status == N60_STATUS_OK else { throw UnifiedGraphError.coreStatus(status.rawValue) }
        spec = newSpec
        // E27 S4 (G17): a new snapshot starts with empty tap rings, so the marked baselines no longer apply.
        analyserTapBaselines.removeAll()
        return .published
    }

    /// Peak and RMS of a meter stage lane (for example `N60_LSTAGE_FINAL_METER`).
    func meter(stageId: UInt32, lane: UInt32) -> (peak: Float, rms: Float)? {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return nil }
        var peak: Float = 0
        var rms: Float = 0
        guard n60_graph_read_meter(graph, stageId, lane, &peak, &rms) == N60_STATUS_OK else {
            return nil
        }
        return (peak, rms)
    }

    /// Over-range sample count of a meter stage lane since the previous read (reset by the read).
    func overRangeSamples(stageId: UInt32, lane: UInt32) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return 0 }
        var count: UInt64 = 0
        guard n60_graph_read_over_range(graph, stageId, lane, &count) == N60_STATUS_OK else { return 0 }
        return count
    }

    /// Fills the program lane levels of a bridge meter snapshot from the graph's METER_OUT stage.
    /// `n60_graph_read_meter` is control-thread-only, so every graph meter read goes through this
    /// host's lock (shared with `apply` and `release`); the audio callback never takes it.
    func overlayProgramMeters(_ meter: inout N60LiveNChannelMeterSnapshot) {
        guard meter.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return }
        // One locked pass, so a publish cannot interleave between lanes.
        for channel in 0..<meter.programChannelCount {
            var peak: Float = 0
            var rms: Float = 0
            if n60_graph_read_meter(graph, N60_LSTAGE_METER_OUT, channel, &peak, &rms) == N60_STATUS_OK {
                N60LiveNChannelMeterSetProgramLevels(&meter, channel, peak, rms)
            }
        }
    }

    /// E6 S8 remainder: fills the stereo meter readings and the latency of a render diagnostics
    /// record from the graph's own METER_IN, METER_OUT and FINAL_METER stages (lanes 0 and 1) and
    /// its reported latency, replacing the kernel's, which does not run while the graph renders.
    /// `latencyFrames` is passed in because the session removes the integer inter-channel taps
    /// (the kernel's figure excludes them). The output reading is left alone when `includeOutput`
    /// is false (the bridge's output VU already supplies it). S8c: also fills over-range counts,
    /// the compressor and limiter gain reduction, the limiter's input and output true peaks and the
    /// true-peak guard flag from the graph (ABI v8). Peaks, over-range counts and the max gain
    /// reduction are read-and-reset in the core. One locked pass; control plane.
    func overlayStereoReadbacks(
        _ diagnostics: inout N60RenderKernelDiagnostics,
        latencyFrames: UInt32,
        includeOutput: Bool
    ) {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return }
        func reading(_ stage: UInt32) -> N60StereoMeterReading {
            var over = [UInt64](repeating: 0, count: 2)
            for lane in 0..<2 {
                _ = n60_graph_read_over_range(graph, stage, UInt32(lane), &over[lane])
            }
            var peak = [Float](repeating: 0, count: 2)
            var rms = [Float](repeating: 0, count: 2)
            for lane in 0..<2 {
                _ = n60_graph_read_meter(graph, stage, UInt32(lane), &peak[lane], &rms[lane])
            }
            return N60StereoMeterReading(
                peakLeft: peak[0], peakRight: peak[1], rmsLeft: rms[0], rmsRight: rms[1], overRangeSamples: over[0] &+ over[1]
            )
        }
        diagnostics.inputMeter = reading(N60_LSTAGE_METER_IN)
        diagnostics.postEQMeter = reading(N60_LSTAGE_METER_OUT)
        if includeOutput { diagnostics.outputMeter = reading(N60_LSTAGE_FINAL_METER) }
        diagnostics.latencyFrames = latencyFrames
        // E6 S12a: the hum detector's readback (the kernel reports it in its own diagnostics).
        var mains = n60_mains_readback()
        mains.structSize = UInt32(MemoryLayout<n60_mains_readback>.size)
        if n60_graph_read_mains(graph, UnifiedGraphConfiguration.cleanupStageId, &mains) == N60_STATUS_OK {
            diagnostics.mainsDetectedFrequencyHz = mains.frequencyHz
            diagnostics.mainsDetectionConfidence = mains.confidence
        }
        if let comp = dynamicsReading(graph, stageId: UnifiedGraphConfiguration.compressorStageId) {
            diagnostics.compressorGainReductionDB = comp.grMaxDb
        }
        // E6 S12b: the de-esser's gain reduction (positive dB, as the kernel reports it).
        if let ess = dynamicsReading(graph, stageId: UnifiedGraphConfiguration.deessStageId) {
            diagnostics.deEsserGainReductionDB = ess.grMaxDb
        }
        // E6 S12c: the loudness and dialogue telemetry (the kernel reports it in its own diagnostics).
        var loud = n60_loudness_readback()
        loud.structSize = UInt32(MemoryLayout<n60_loudness_readback>.size)
        if n60_graph_read_loudness(graph, UnifiedGraphConfiguration.loudnessStageId, &loud) == N60_STATUS_OK {
            diagnostics.loudnessShortTermLUFS = loud.shortTermLufs
            diagnostics.loudnessMatchGainDB = loud.matchGainDb
            diagnostics.loudnessContourScale = loud.contourScale
            diagnostics.dialogueProgramLevelDBFS = loud.dialogueProgramDbfs
            diagnostics.dialogueBandLevelDBFS = loud.dialogueBandDbfs
            diagnostics.dialogueGapDB = loud.dialogueGapDb
            diagnostics.dialogueVoiceConfidence = loud.dialogueVoiceConfidence
            diagnostics.dialogueBoostDB = loud.dialogueBoostDb
        }
        // E6 S12d: per-band multiband gain reduction (the kernel reports the value at the end of the block).
        var band = n60_multiband_readback()
        band.structSize = UInt32(MemoryLayout<n60_multiband_readback>.size)
        if n60_graph_read_multiband(graph, UnifiedGraphConfiguration.multibandStageId, &band) == N60_STATUS_OK {
            diagnostics.multibandLowGainReductionDB = band.grNowDb.0
            diagnostics.multibandMidGainReductionDB = band.grNowDb.1
            diagnostics.multibandHighGainReductionDB = band.grNowDb.2
        }
        if let prot = dynamicsReading(graph, stageId: N60_LSTAGE_PROTECTION) {
            diagnostics.limiterGainReductionDB = prot.grMaxDb
            diagnostics.inputTruePeakLinear = prot.inTruePeak
            diagnostics.outputTruePeakLinear = prot.outTruePeak
            diagnostics.truePeakGuardActive = prot.guardActive != 0
        }
    }

    /// The reading for lane 0 (linked groups publish the same value on every lane); nil when the
    /// stage is not in the live graph. Caller holds `lock`.
    private func dynamicsReading(_ graph: OpaquePointer, stageId: UInt32, lane: UInt32 = 0) -> n60_dynamics_readback? {
        var out = n60_dynamics_readback()
        out.structSize = UInt32(MemoryLayout<n60_dynamics_readback>.size)
        guard n60_graph_read_dynamics(graph, stageId, lane, &out) == N60_STATUS_OK else { return nil }
        return out
    }

    /// Gain reduction, true-peak and guard readings of the graph's compressor and protection
    /// stages for the diagnostics record; nil when no stage is present. Control plane.
    func dynamicsReadings() -> UnifiedGraphDynamicsReading? {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return nil }
        let comp = dynamicsReading(graph, stageId: UnifiedGraphConfiguration.compressorStageId)
        let prot = dynamicsReading(graph, stageId: N60_LSTAGE_PROTECTION)
        guard comp != nil || prot != nil else { return nil }
        return UnifiedGraphDynamicsReading(
            compressorGainReductionDB: comp?.grMaxDb ?? 0,
            limiterGainReductionDB: prot?.grMaxDb ?? 0,
            inputTruePeakLinear: prot?.inTruePeak ?? 0,
            outputTruePeakLinear: prot?.outTruePeak ?? 0,
            truePeakGuardActive: (prot?.guardActive ?? 0) != 0
        )
    }

    /// E9 S5: the protection readings of each output lane `0..<lanes` (user stage of a sub lane or an independent program lane,
    /// the always-on hard limit). A lane without a stage reads nil for it. Empty when the graph has no hard limits (the flag
    /// is off). Control plane.
    func outputProtectionReadings(lanes: Int) -> [UnifiedGraphOutputProtectionReading] {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return [] }
        var out: [UnifiedGraphOutputProtectionReading] = []
        for lane in 0..<lanes {
            guard let hard = dynamicsReading(graph, stageId: UnifiedGraphOutputProtection.hardLimitStageBase + UInt32(lane), lane: UInt32(lane)) else {
                continue
            }
            let user = dynamicsReading(graph, stageId: UnifiedGraphOutputProtection.userLaneStageBase + UInt32(lane), lane: UInt32(lane))
            out.append(UnifiedGraphOutputProtectionReading(
                lane: lane, userGainReductionDB: user?.grMaxDb, userTruePeakLinear: user?.outTruePeak,
                hardLimitGainReductionDB: hard.grMaxDb, outputTruePeakLinear: hard.outTruePeak))
        }
        return out
    }

    var latencyFrames: UInt32 {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return 0 }
        return n60_graph_latency_frames(graph)
    }

    var rebuildState: UInt32 {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return 0 }
        var status = n60_rebuild_status()
        status.structSize = UInt32(MemoryLayout<n60_rebuild_status>.size)
        guard n60_graph_get_rebuild_status(graph, &status) == N60_STATUS_OK else { return 0 }
        return status.state
    }

    /// Frees snapshots the realtime side has retired. Control thread.
    @discardableResult
    func collect() -> UInt32 {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { return 0 }
        return n60_graph_collect(graph)
    }

    /// Renders planar float blocks through the graph on the calling thread. For tests and
    /// offline use only; a graph attached to a live bridge must be processed by that bridge's
    /// callback alone.
    func processOffline(input: [[Float]], frames: Int) throws -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        guard let graph else { throw UnifiedGraphError.invalidConfiguration("graph released") }
        let inCount = Int(spec.inputChannels)
        let outCount = Int(spec.outputChannels)
        guard input.count == inCount, input.allSatisfy({ $0.count >= frames }), frames > 0 else {
            throw UnifiedGraphError.invalidConfiguration("input shape")
        }
        var inPointers: [UnsafePointer<Float>?] = []
        var outPointers: [UnsafeMutablePointer<Float>?] = []
        var inStorage: [UnsafeMutablePointer<Float>] = []
        var outStorage: [UnsafeMutablePointer<Float>] = []
        defer {
            inStorage.forEach { $0.deallocate() }
            outStorage.forEach { $0.deallocate() }
        }
        for channel in input {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            buffer.initialize(from: channel, count: frames)
            inStorage.append(buffer)
            inPointers.append(UnsafePointer(buffer))
        }
        for _ in 0..<outCount {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            buffer.initialize(repeating: 0, count: frames)
            outStorage.append(buffer)
            outPointers.append(buffer)
        }
        let status = inPointers.withUnsafeBufferPointer { ip in
            outPointers.withUnsafeBufferPointer { op in
                n60_graph_process(graph, ip.baseAddress, op.baseAddress, UInt32(frames))
            }
        }
        guard status == N60_STATUS_OK else { throw UnifiedGraphError.coreStatus(status.rawValue) }
        return outStorage.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }
}

/// E6 S8c: graph gain-reduction, true-peak and guard readbacks (values since the last read).
/// E9 S5: one output lane's protection readings (gain reduction in dB as the core reports it, true peak linear).
struct UnifiedGraphOutputProtectionReading: Equatable, Sendable {
    var lane: Int
    var userGainReductionDB: Float?
    var userTruePeakLinear: Float?
    var hardLimitGainReductionDB: Float
    var outputTruePeakLinear: Float
}

struct UnifiedGraphDynamicsReading: Equatable, Sendable {
    let compressorGainReductionDB: Float
    let limiterGainReductionDB: Float
    let inputTruePeakLinear: Float
    let outputTruePeakLinear: Float
    let truePeakGuardActive: Bool
}
