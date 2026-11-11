import Foundation

/// E20 S6: how many extra worker threads a graph gets for its parallel FIR phases. Swift decides and the core only sees
/// `n60_graph_set_workers`, so the realtime engine never reads the flag (AGENTS.md section 11).
///
/// The rule is deliberately plain, because the audio thread alone is the default and a wrong guess only costs a little
/// CPU:
/// - zero workers unless `e20.parallel-render` is on (read once at launch, `refresh`) and the graph uses the non-uniform
///   FIR engine (`firScheme` 1), the only engine whose lanes run as parallel jobs;
/// - zero workers when the estimated single-thread load of the FIR lanes is below `minLoad`;
/// - otherwise enough workers to bring each thread under `minLoad`, never more than the FIR lane count minus one (the
///   audio thread takes a lane too), the machine's performance cores minus one, or `N60_GRAPH_MAX_WORKERS`.
///
/// The cost model is a provisional estimate from the partitioned-convolution operation count, not a measurement. E22
/// calibrates `flopsPerSecond`, `minLoad` and the per-lane cost on the bench machines (E20 S6 bench lines).
enum ParallelRenderPolicy {
    /// Estimated single-thread throughput the model assumes, floating point operations per second.
    static let flopsPerSecond = 8.0e9
    /// A thread is not asked to carry more than this fraction of the IO period; below it a worker is not worth waking.
    static let minLoad = 0.4

    private static let lock = NSLock()
    nonisolated(unsafe) private static var flagOn = false

    /// The flag as read at launch. Feature flags are main-actor and graphs are built on any thread, so the value is
    /// copied here once, the same way `UnifiedGraphFIRScheme.refresh()` does.
    static var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flagOn
    }

    @MainActor static func refresh(_ flags: FeatureFlags? = nil) {
        let value = (flags ?? FeatureFlags()).isEnabled(.parallelRender)
        lock.lock(); flagOn = value; lock.unlock()
    }

    /// Test seam: sets the launch value directly.
    static func setEnabledForTesting(_ value: Bool) {
        lock.lock(); flagOn = value; lock.unlock()
    }

    /// Output lanes one FIR stage runs on.
    static func lanes(of stage: UnifiedGraphStageSpec, outputChannels: UInt32) -> Int {
        if stage.laneMask != 0 { return stage.laneMask.nonzeroBitCount }
        if stage.laneA == N60_LANE_ALL { return Int(outputChannels) }
        return 1
    }

    /// Number of FIR lane jobs in the spec (each lane of each non-uniform FIR stage is one job per callback).
    static func firLaneCount(_ spec: UnifiedGraphSpec) -> Int {
        guard spec.firScheme == UnifiedGraphFIRScheme.nonUniform else { return 0 }
        return spec.stages
            .filter { $0.kind == N60_STAGE_FIR.rawValue }
            .reduce(0) { $0 + lanes(of: $1, outputChannels: spec.outputChannels) }
    }

    /// Estimated fraction of one IO period the FIR lanes need on a single thread. About 220 flops per sample for the
    /// small uniform head partitions plus one flop per 128 taps for the partitioned tail, per lane.
    static func estimatedLoad(_ spec: UnifiedGraphSpec) -> Double {
        guard spec.firScheme == UnifiedGraphFIRScheme.nonUniform, spec.sampleRate > 0 else { return 0 }
        var flopsPerSample = 0.0
        for stage in spec.stages where stage.kind == N60_STAGE_FIR.rawValue {
            let laneCount = Double(lanes(of: stage, outputChannels: spec.outputChannels))
            flopsPerSample += laneCount * (220.0 + Double(stage.params.count) / 128.0)
        }
        return flopsPerSample * spec.sampleRate / flopsPerSecond
    }

    /// Workers for this spec on a machine with `cores` performance cores. `enabled` defaults to the launch flag.
    static func workerCount(
        spec: UnifiedGraphSpec,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        enabled: Bool? = nil
    ) -> Int {
        guard enabled ?? isEnabled else { return 0 }
        let jobs = firLaneCount(spec)
        guard jobs >= 2 else { return 0 }
        let load = estimatedLoad(spec)
        guard load >= minLoad else { return 0 }
        let wanted = Int((load / minLoad).rounded(.up))
        return max(0, min(wanted, jobs - 1, cores - 1, Int(N60_GRAPH_MAX_WORKERS)))
    }

    /// Threads the pool creates for a stream: the most any spec of this kind can use. Zero when the feature is off or the
    /// machine has a single core.
    static func poolSize(
        scheme: UInt32,
        cores: Int = ProcessInfo.processInfo.activeProcessorCount,
        enabled: Bool? = nil
    ) -> Int {
        guard enabled ?? isEnabled, scheme == UnifiedGraphFIRScheme.nonUniform else { return 0 }
        return max(0, min(cores - 1, Int(N60_GRAPH_MAX_WORKERS)))
    }
}
