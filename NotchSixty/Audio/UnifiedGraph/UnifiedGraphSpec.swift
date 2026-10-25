import Foundation

/// E6 S8: a Swift value description of an n60 graph (libn60core). Every configuration the
/// engine publishes (stereo, multichannel, sub lanes, binaural) is first expressed as a
/// spec; the host turns it into the C description, and a parameter-only difference between
/// two specs of the same topology is published as live parameter posts instead of a rebuild.
struct UnifiedGraphStageSpec: Equatable {
    var kind: UInt32
    var stageId: UInt32
    var laneA: UInt32
    var laneB: UInt32 = 0
    var laneMask: UInt64 = 0
    var capacityFrames: UInt32 = 0
    var params: [Float] = []
}

/// E6 S8d (ABI v9): what the kernel's denoiser sees while it is off, so a graph without the stage keeps
/// the noise profile the kernel would keep. See `n60_graph_desc.parkFftSize`.
struct UnifiedGraphDenoiserPark: Equatable, Sendable {
    var fftSize: UInt32
    var revision: UInt32
    var command: UInt32
}

struct UnifiedGraphSpec: Equatable {
    var sampleRate: Double
    var maxBlockFrames: UInt32
    var inputChannels: UInt32
    var outputChannels: UInt32
    var stages: [UnifiedGraphStageSpec]
    var denoiserPark: UnifiedGraphDenoiserPark?

    /// Two specs share a topology when a rebuild is not needed to move between them,
    /// as far as the control plane can tell without asking the core: same rate, size,
    /// channel counts and the same stages in the same order with the same parameter counts.
    /// Non-live parameter changes inside a matching topology are still caught by the core
    /// (post_params returns UNSUPPORTED) and the host then falls back to a publish.
    func hasSameTopology(as other: UnifiedGraphSpec) -> Bool {
        guard sampleRate == other.sampleRate, maxBlockFrames == other.maxBlockFrames,
              inputChannels == other.inputChannels, outputChannels == other.outputChannels,
              stages.count == other.stages.count else { return false }
        // A change in the denoiser's off view is applied when a snapshot is adopted, so it needs one.
        guard denoiserPark == other.denoiserPark else { return false }
        for (a, b) in zip(stages, other.stages) {
            if a.kind != b.kind || a.stageId != b.stageId || a.laneA != b.laneA
                || a.laneB != b.laneB || a.laneMask != b.laneMask
                || a.capacityFrames != b.capacityFrames
                || a.params.count != b.params.count { return false }
            // FIR taps are not live parameters: new taps are a rebuild (the core carries unchanged filters across it).
            if a.kind == N60_STAGE_FIR.rawValue || a.kind == N60_STAGE_ROOM_FIR.rawValue || a.kind == N60_STAGE_ROOM_FIR_TWO_BAND.rawValue
                || a.kind == N60_STAGE_SPEAKER_IR.rawValue, a.params != b.params { return false }
        }
        return true
    }

    /// Parameter records that differ from `old` (same topology required).
    func changedParameters(since old: UnifiedGraphSpec) -> [n60_param_record] {
        var records: [n60_param_record] = []
        for (new, previous) in zip(stages, old.stages) {
            for index in 0..<new.params.count where new.params[index] != previous.params[index] {
                records.append(n60_param_record(
                    stageId: new.stageId,
                    paramIndex: UInt32(index),
                    value: new.params[index],
                    reserved: 0
                ))
            }
        }
        return records
    }

    /// Copies a C description (for example one built by `n60_layout_graph_build`).
    init(copying desc: UnsafePointer<n60_graph_desc>) {
        let d = desc.pointee
        sampleRate = d.sampleRate
        maxBlockFrames = d.maxBlockFrames
        inputChannels = d.inputChannels
        outputChannels = d.outputChannels
        var out: [UnifiedGraphStageSpec] = []
        if let stagePointer = d.stages {
            for i in 0..<Int(d.stageCount) {
                let s = stagePointer[i]
                var params: [Float] = []
                if let p = s.params, s.paramCount > 0 {
                    params = Array(UnsafeBufferPointer(start: p, count: Int(s.paramCount)))
                }
                out.append(UnifiedGraphStageSpec(
                    kind: s.kind, stageId: s.stageId, laneA: s.laneA, laneB: s.laneB,
                    laneMask: s.laneMask, capacityFrames: s.capacityFrames, params: params
                ))
            }
        }
        stages = out
        if d.parkFftSize != 0 {
            denoiserPark = UnifiedGraphDenoiserPark(
                fftSize: d.parkFftSize, revision: d.parkRevision, command: d.parkCommand
            )
        }
    }

    init(
        sampleRate: Double,
        maxBlockFrames: UInt32,
        inputChannels: UInt32,
        outputChannels: UInt32,
        stages: [UnifiedGraphStageSpec],
        denoiserPark: UnifiedGraphDenoiserPark? = nil
    ) {
        self.sampleRate = sampleRate
        self.maxBlockFrames = maxBlockFrames
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.stages = stages
        self.denoiserPark = denoiserPark
    }

    /// Runs `body` with a C description that is valid only for the call (the core copies
    /// everything it keeps).
    func withDescription<R>(_ body: (UnsafePointer<n60_graph_desc>) -> R) -> R {
        var paramBuffers: [UnsafeMutablePointer<Float>] = []
        defer { paramBuffers.forEach { $0.deallocate() } }
        var descs: [n60_stage_desc] = []
        descs.reserveCapacity(stages.count)
        for stage in stages {
            var desc = n60_stage_desc()
            desc.structSize = UInt32(MemoryLayout<n60_stage_desc>.size)
            desc.kind = stage.kind
            desc.stageId = stage.stageId
            desc.laneA = stage.laneA
            desc.laneB = stage.laneB
            desc.capacityFrames = stage.capacityFrames
            desc.laneMask = stage.laneMask
            desc.paramCount = UInt32(stage.params.count)
            if !stage.params.isEmpty {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: stage.params.count)
                buffer.initialize(from: stage.params, count: stage.params.count)
                paramBuffers.append(buffer)
                desc.params = UnsafePointer(buffer)
            }
            descs.append(desc)
        }
        return descs.withUnsafeBufferPointer { stageBuffer in
            var graphDesc = n60_graph_desc()
            graphDesc.structSize = UInt32(MemoryLayout<n60_graph_desc>.size)
            graphDesc.abiVersion = N60_GRAPH_ABI_VERSION
            graphDesc.sampleRate = sampleRate
            graphDesc.maxBlockFrames = maxBlockFrames
            graphDesc.inputChannels = inputChannels
            graphDesc.outputChannels = outputChannels
            graphDesc.stages = stageBuffer.baseAddress
            graphDesc.stageCount = UInt32(stages.count)
            if let park = denoiserPark {
                graphDesc.parkFftSize = park.fftSize
                graphDesc.parkRevision = park.revision
                graphDesc.parkCommand = park.command
            }
            return withUnsafePointer(to: &graphDesc) { body($0) }
        }
    }
}

extension UnifiedGraphSpec {
    /// Stage id of the EXTERNAL stage that hosts the AU rack (E6 S8e).
    static let externalRackStageId: UInt32 = 700

    /// Kinds that run before the AU rack in the kernel (everything up to the post-EQ meter); the rack follows
    /// the last of them, ahead of the crossover and the system stages.
    private static let beforeRackKinds: Set<UInt32> = [
        N60_STAGE_SANITISE, N60_STAGE_METER_IN, N60_STAGE_GAIN, N60_STAGE_DENOISER, N60_STAGE_MS_ENCODE,
        N60_STAGE_PEQ, N60_STAGE_DYN_EQ, N60_STAGE_MS_DECODE, N60_STAGE_FIR, N60_STAGE_COMPRESSOR,
        N60_STAGE_EXPANDER, N60_STAGE_METER_OUT,
    ].reduce(into: Set<UInt32>()) { $0.insert($1.rawValue) }

    /// A copy with the AU rack's EXTERNAL stage on both stereo lanes, at the kernel's rack seam. The declared
    /// latency is the rack's reported latency; the stage starts active (the rack's own bypass is its runtime).
    func insertingExternalRackStage(latencyFrames: UInt32) -> UnifiedGraphSpec {
        var copy = self
        copy.stages.removeAll { $0.kind == N60_STAGE_EXTERNAL.rawValue }
        let index = (copy.stages.lastIndex { Self.beforeRackKinds.contains($0.kind) }).map { $0 + 1 } ?? 0
        copy.stages.insert(UnifiedGraphStageSpec(
            kind: N60_STAGE_EXTERNAL.rawValue, stageId: Self.externalRackStageId, laneA: 0,
            laneMask: 0b11, capacityFrames: latencyFrames, params: [1]
        ), at: index)
        return copy
    }
}
