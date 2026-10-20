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
    }

    /// The graph pointer for `N60RealtimeAudioBridgeSetUnifiedGraph`. Valid while the host lives.
    var rawGraph: UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        return graph.map { UnsafeMutableRawPointer($0) }
    }

    var inputChannels: UInt32 { lock.lock(); defer { lock.unlock() }; return spec.inputChannels }
    var outputChannels: UInt32 { lock.lock(); defer { lock.unlock() }; return spec.outputChannels }

    /// Moves the graph to `newSpec`: parameter posts when only live values differ, a
    /// faded rebuild otherwise. Safe to call while a bridge is rendering the graph.
    @discardableResult
    func apply(_ newSpec: UnifiedGraphSpec) throws -> UnifiedGraphApplyResult {
        lock.lock(); defer { lock.unlock() }
        return try applyLocked(newSpec)
    }

    /// Posts a head pose to the BINAURAL stage (yaw, pitch and roll are its live parameters 0 to 2;
    /// the stage glides between the response cells). Control thread; no rebuild.
    @discardableResult
    func setBinauralPose(yaw: Float, pitch: Float, roll: Float) throws -> UnifiedGraphApplyResult {
        lock.lock(); defer { lock.unlock() }
        var next = spec
        guard let index = next.stages.firstIndex(where: { $0.stageId == N60_LSTAGE_BINAURAL }),
              next.stages[index].params.count >= 3 else {
            throw UnifiedGraphError.invalidConfiguration("no binaural stage")
        }
        next.stages[index].params[0] = Float(N60HeadPoseWrap180(Double(yaw)))
        next.stages[index].params[1] = min(180, max(-180, pitch))
        next.stages[index].params[2] = min(180, max(-180, roll))
        return try applyLocked(next)
    }

    private func applyLocked(_ newSpec: UnifiedGraphSpec) throws -> UnifiedGraphApplyResult {
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
        let status = newSpec.withDescription { n60_graph_publish(graph, $0) }
        guard status == N60_STATUS_OK else { throw UnifiedGraphError.coreStatus(status.rawValue) }
        spec = newSpec
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
