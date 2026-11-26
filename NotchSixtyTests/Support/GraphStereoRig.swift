import XCTest
@testable import NotchSixty

/// E23 T1: the test-side stand-in for the stereo render kernel. A test publishes an `N60DSPGraphSnapshot`
/// exactly as it did to the kernel; the rig translates it (the production translator) and renders it
/// through `UnifiedGraphHost.processOffline`, so the assertion now runs against the engine that ships.
/// Programs are prepared the way `AudioIOEngine+ProgramApply` does: local generations, taps retained
/// by kind and generation, and the `N60ConvolutionProgramInfo` built from them.
///
/// Republishing builds a new host (state is reset); tests that need continuity across a parameter
/// change publish once. Frame-by-frame rendering uses one-frame blocks.
final class GraphStereoRig {
    private(set) var host: UnifiedGraphHost?
    private var programs: [(kind: UnifiedGraphProgramKind, program: UnifiedGraphFIRProgram)] = []
    private var nextGeneration: UInt64 = 1
    private(set) var lastRefusal: UnifiedGraphFallbackReason?
    private(set) var published: N60DSPGraphSnapshot?
    /// Programs the published snapshot asked for that were not retained (kernel "program misses").
    var programMisses = 0

    /// Optional only so tests keep their `guard let` shape; creation cannot fail.
    static func create() -> GraphStereoRig? { GraphStereoRig() }

    /// The kernel had no per-output hard limit, and `e9.output-protection` is on by default, so the graph would add a
    /// -1 dBFS ceiling the old tests never expected (G115). The rig switches it off for its lifetime (the corpus tests
    /// do the same); `OutputProtectionTests` covers the protection itself. `destroy()` puts the default back.
    private var restoredProtection = false

    init() { Self.suspendOutputProtection() }

    func destroy() {
        guard !restoredProtection else { return }
        restoredProtection = true
        Self.restoreOutputProtection()
    }

    /// For tests that build a graph themselves and need the same no-hard-limit reference.
    static func suspendOutputProtection() {
        MainActor.assumeIsolated {
            let suite = "GraphStereoRig-\(UUID().uuidString)"
            if let defaults = UserDefaults(suiteName: suite) {
                UnifiedGraphOutputProtection.refresh(FeatureFlags(
                    known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly,
                    arguments: ["-NotchSixtyFeatures", "-e9.output-protection"]))
                defaults.removePersistentDomain(forName: suite)
            }
        }
    }

    static func restoreOutputProtection() {
        MainActor.assumeIsolated { UnifiedGraphOutputProtection.refresh() }
    }

    var latencyFrames: Int { Int(host?.latencyFrames ?? 0) }

    /// Prepares taps for `kind` and returns the program info the snapshot setters take.
    @discardableResult
    func prepareProgram(
        _ kind: UnifiedGraphProgramKind, left: [Float], right: [Float]?, declared: UInt32,
        info: inout N60ConvolutionProgramInfo
    ) -> Bool {
        guard !left.isEmpty, left.count <= Int(N60_CONVOLUTION_MAX_TAPS) else { return false }
        if let right, right.count != left.count { return false }
        let generation = nextGeneration
        nextGeneration += 1
        programs.append((kind, UnifiedGraphFIRProgram(
            generation: generation, left: left, right: right, declaredLatencyFrames: declared)))
        info = N60ConvolutionProgramInfo(
            prepared: true,
            generation: generation,
            tapCount: UInt32(left.count),
            partitionCount: N60ConvolutionPartitionCountForTapCount(UInt32(left.count)),
            engineLatencyFrames: N60_CONVOLUTION_PARTITION_FRAMES,
            declaredLatencyFrames: declared)
        return true
    }

    func prepareConvolution(
        left: [Float], right: [Float]? = nil, declared: UInt32 = 0, info: inout N60ConvolutionProgramInfo
    ) -> Bool { prepareProgram(.convolution, left: left, right: right, declared: declared, info: &info) }

    func prepareRoomCorrection(
        left: [Float], right: [Float]? = nil, declared: UInt32 = 0, info: inout N60ConvolutionProgramInfo
    ) -> Bool { prepareProgram(.roomCorrection, left: left, right: right, declared: declared, info: &info) }

    func prepareSpeakerIR(
        left: [Float], right: [Float]? = nil, declared: UInt32 = 0, info: inout N60ConvolutionProgramInfo
    ) -> Bool { prepareProgram(.speakerIR, left: left, right: right, declared: declared, info: &info) }


    // Pointer-shaped entry points so a retargeted call keeps its argument list (the slot is ignored; generations are local).
    func prepareConvolutionProgram(
        _ slot: UInt32, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, _ count: UInt32,
        _ declared: UInt32, _ info: UnsafeMutablePointer<N60ConvolutionProgramInfo>?
    ) -> Bool { prepareShim(.convolution, left, right, count, declared, info) }

    func prepareRoomCorrectionProgram(
        _ slot: UInt32, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, _ count: UInt32,
        _ declared: UInt32, _ info: UnsafeMutablePointer<N60ConvolutionProgramInfo>?
    ) -> Bool { prepareShim(.roomCorrection, left, right, count, declared, info) }

    func prepareSpeakerIRProgram(
        _ slot: UInt32, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, _ count: UInt32,
        _ declared: UInt32, _ info: UnsafeMutablePointer<N60ConvolutionProgramInfo>?
    ) -> Bool { prepareShim(.speakerIR, left, right, count, declared, info) }

    private func prepareShim(
        _ kind: UnifiedGraphProgramKind, _ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, _ count: UInt32,
        _ declared: UInt32, _ info: UnsafeMutablePointer<N60ConvolutionProgramInfo>?
    ) -> Bool {
        var local = N60ConvolutionProgramInfo()
        let l = Array(UnsafeBufferPointer(start: left, count: Int(count)))
        let r = right.map { Array(UnsafeBufferPointer(start: $0, count: Int(count))) }
        guard prepareProgram(kind, left: l, right: r, declared: declared, info: &local) else { return false }
        info?.pointee = local
        return true
    }


    /// What the published snapshot asked for, plus the graph's latency. The old kernel reported its parsed copy
    /// of the same snapshot, so these read the snapshot; behaviour is asserted on rendered audio.
    struct Diagnostics {
        var snapshot: N60DSPGraphSnapshot
        var latencyFrames: UInt32
        /// The graph's hum-detector readback (the bridge's stereo readback type; K2 renames it).
        var readback = N60RenderKernelDiagnostics()
        var mainsDetectedFrequencyHz: Float { readback.mainsDetectedFrequencyHz }
        var mainsDetectionConfidence: Float { readback.mainsDetectionConfidence }
        var denoiserLatencyFrames: UInt32 { latencyFrames }
        var sampleRate: Double { snapshot.sampleRate }
        var channelCount: UInt32 { snapshot.channelCount }
        var bypassed: Bool { snapshot.bypassed }
        var masterGainLinear: Float { snapshot.masterGainLinear }
        var interChannelDelayMs: Double { snapshot.interChannelDelay.signedDelayMs }
        var interChannelAlignmentLatencyFrames: UInt32 { snapshot.interChannelDelay.commonLatencyFrames }
        var eqBandCount: UInt32 { snapshot.eqBandCount }
        var eqLeftBandCount: Int { bands(N60_EQ_CHANNEL_LEFT) }
        var eqRightBandCount: Int { bands(N60_EQ_CHANNEL_RIGHT) }
        var crossoverEnabled: Bool { snapshot.crossover.enabled }
        var crossoverFrequencyHz: Double { snapshot.crossover.frequencyHz }
        var crossoverTopology: N60CrossoverTopology { snapshot.crossover.topology }
        var crossoverMonitorMode: N60CrossoverMonitorMode { snapshot.crossover.monitorMode }
        var crossoverSectionCount: UInt32 { snapshot.crossover.sectionCount }
        var convolutionEnabled: Bool { snapshot.convolution.enabled }
        var convolutionProgramSlot: UInt32 { snapshot.convolution.programSlot }
        var convolutionProgramGeneration: UInt64 { snapshot.convolution.programGeneration }
        var convolutionTapCount: UInt32 { snapshot.convolution.tapCount }
        var convolutionPartitionCount: UInt32 { snapshot.convolution.partitionCount }
        var convolutionEngineLatencyFrames: UInt32 { snapshot.convolution.engineLatencyFrames }
        var convolutionDeclaredLatencyFrames: UInt32 { snapshot.convolution.declaredLatencyFrames }
        var roomCorrectionEnabled: Bool { snapshot.roomCorrection.enabled }
        var roomCorrectionProgramSlot: UInt32 { snapshot.roomCorrection.programSlot }
        var roomCorrectionProgramGeneration: UInt64 { snapshot.roomCorrection.programGeneration }
        var roomCorrectionTapCount: UInt32 { snapshot.roomCorrection.tapCount }
        var roomCorrectionPartitionCount: UInt32 { snapshot.roomCorrection.partitionCount }
        var roomCorrectionDeclaredLatencyFrames: UInt32 { snapshot.roomCorrection.declaredLatencyFrames }
        var speakerIREnabled: Bool { snapshot.speakerIR.enabled }
        var speakerIRProgramSlot: UInt32 { snapshot.speakerIR.programSlot }
        var speakerIRProgramGeneration: UInt64 { snapshot.speakerIR.programGeneration }

        /// The translator refuses a snapshot that names a program it was not given, so a published one has no misses.
        var convolutionProgramMisses: UInt64 { 0 }
        var roomCorrectionProgramMisses: UInt64 { 0 }
        var speakerIRProgramMisses: UInt64 { 0 }
        /// The rig publishes by building a host, so there is no lock-free snapshot read to miss.
        var snapshotReadMisses: UInt64 { 0 }

        private func bands(_ channel: UInt32) -> Int {
            withUnsafeBytes(of: snapshot.eqBandChannelMasks) { masks in
                masks.prefix(Int(snapshot.eqBandCount)).filter { UInt32($0) & channel != 0 }.count
            }
        }
    }

    /// Valid after a successful `publish`.
    var diagnostics: Diagnostics {
        var value = Diagnostics(
            snapshot: published ?? N60DSPGraphSnapshotMakeUnity(48_000), latencyFrames: UInt32(latencyFrames))
        host?.overlayStereoReadbacks(&value.readback, latencyFrames: UInt32(latencyFrames), includeOutput: false)
        return value
    }

    /// Translates and builds. False (with `lastRefusal`) when the graph refuses the snapshot.
    func publish(
        _ snapshot: N60DSPGraphSnapshot, subwoofers: [UnifiedGraphSubwoofer] = [], crossoverHz: Double = 80,
        alignment: StereoBassAlignment? = nil
    ) -> Bool {
        var copy = snapshot
        let retained = programs
        let result = UnifiedGraphTranslator.stereoEligibility(
            snapshot: &copy, sampleRate: snapshot.sampleRate, subwoofers: subwoofers, crossoverHz: crossoverHz,
            programs: { kind, generation in
                retained.first { $0.kind == kind && $0.program.generation == generation }?.program
            },
            alignment: alignment)
        switch result {
        case .failure(let reason):
            lastRefusal = reason
            print("GraphStereoRig: graph refused the snapshot: \(reason)")
            return false
        case .success(let configuration):
            lastRefusal = nil
            guard let spec = try? configuration.makeSpec(), let built = try? UnifiedGraphHost(spec: spec) else {
                return false
            }
            host = built
            published = snapshot
            return true
        }
    }

    /// One frame through a one-frame block.
    func processFrame(
        _ inLeft: Float, _ inRight: Float, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>
    ) {
        guard let host, let out = try? host.processOffline(input: [[inLeft], [inRight]], frames: 1) else {
            left.pointee = 0
            right.pointee = 0
            return
        }
        left.pointee = out[0][0]
        right.pointee = out[1][0]
    }

    /// Whole buffers in blocks of `block` (the last block may be shorter).
    func process(_ input: [[Float]], block: Int = 512) throws -> [[Float]] {
        let host = try XCTUnwrap(host, "publish a snapshot first")
        var out: [[Float]] = [[], []]
        var position = 0
        let count = input[0].count
        while position < count {
            let n = min(block, count - position)
            let chunk = input.map { Array($0[position..<position + n]) }
            let rendered = try host.processOffline(input: chunk, frames: n)
            out[0] += rendered[0]
            out[1] += rendered[1]
            position += n
        }
        return out
    }
}
