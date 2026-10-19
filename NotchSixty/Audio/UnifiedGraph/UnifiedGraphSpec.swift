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

struct UnifiedGraphSpec: Equatable {
    var sampleRate: Double
    var maxBlockFrames: UInt32
    var inputChannels: UInt32
    var outputChannels: UInt32
    var stages: [UnifiedGraphStageSpec]

    /// Two specs share a topology when a rebuild is not needed to move between them,
    /// as far as the control plane can tell without asking the core: same rate, size,
    /// channel counts and the same stages in the same order with the same parameter counts.
    /// Non-live parameter changes inside a matching topology are still caught by the core
    /// (post_params returns UNSUPPORTED) and the host then falls back to a publish.
    func hasSameTopology(as other: UnifiedGraphSpec) -> Bool {
        guard sampleRate == other.sampleRate, maxBlockFrames == other.maxBlockFrames,
              inputChannels == other.inputChannels, outputChannels == other.outputChannels,
              stages.count == other.stages.count else { return false }
        for (a, b) in zip(stages, other.stages) {
            if a.kind != b.kind || a.stageId != b.stageId || a.laneA != b.laneA
                || a.laneB != b.laneB || a.laneMask != b.laneMask
                || a.capacityFrames != b.capacityFrames
                || a.params.count != b.params.count { return false }
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
    }

    init(
        sampleRate: Double,
        maxBlockFrames: UInt32,
        inputChannels: UInt32,
        outputChannels: UInt32,
        stages: [UnifiedGraphStageSpec]
    ) {
        self.sampleRate = sampleRate
        self.maxBlockFrames = maxBlockFrames
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.stages = stages
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
            return withUnsafePointer(to: &graphDesc) { body($0) }
        }
    }
}
