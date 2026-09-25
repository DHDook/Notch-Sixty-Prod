from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    if text.count(old) < count:
        raise SystemExit(f"missing pattern in {path}: {old[:100]!r}")
    p.write_text(text.replace(old, new, count))

# --- Render-kernel public graph/diagnostics contract ---
h = 'NotchSixty/Audio/Realtime/N60RenderKernel.h'
replace(h, '#include "N60Crossover.h"\n', '#include "N60Crossover.h"\n#include "N60Dynamics.h"\n')
replace(h,
'''    N60CrossoverSnapshot crossover;\n    N60ConvolutionGraphState convolution;\n''',
'''    N60CrossoverSnapshot crossover;\n    N60DynamicsSnapshot dynamics;\n    N60ConvolutionGraphState convolution;\n''')
replace(h,
'''    uint32_t crossoverSectionCount;\n    bool convolutionEnabled;\n''',
'''    uint32_t crossoverSectionCount;\n    bool compressorEnabled;\n    bool expanderEnabled;\n    bool pauseGateEnabled;\n    float compressorGainReductionDB;\n    float expanderAttenuationDB;\n    float pauseGateGain;\n    bool pauseGateOpen;\n    bool convolutionEnabled;\n''')

# --- Render-kernel runtime integration ---
c = 'NotchSixty/Audio/Realtime/N60RenderKernel.c'
replace(c,
'''    N60CrossoverRuntime crossoverRuntime;\n    N60PartitionedConvolver *convolver;\n''',
'''    N60CrossoverRuntime crossoverRuntime;\n    N60DynamicsRuntime dynamicsRuntime;\n    N60PartitionedConvolver *convolver;\n''')
replace(c,
'''    _Atomic uint64_t roomCorrectionProgramMisses;\n\n    _Atomic uint32_t inputPeakLeftBits;\n''',
'''    _Atomic uint64_t roomCorrectionProgramMisses;\n\n    _Atomic uint32_t compressorGainReductionBits;\n    _Atomic uint32_t expanderAttenuationBits;\n    _Atomic uint32_t pauseGateGainBits;\n    _Atomic bool pauseGateOpen;\n\n    _Atomic uint32_t inputPeakLeftBits;\n''')
replace(c,
'''        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n        || !crossover_snapshot_is_valid(snapshot.crossover, snapshot.sampleRate)\n''',
'''        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n        || !crossover_snapshot_is_valid(snapshot.crossover, snapshot.sampleRate)\n        || !N60DynamicsSnapshotIsValid(snapshot.dynamics)\n''')
replace(c,
'''    if (firstPreparation || sampleRateChanged || leavingGraphBypass) {\n        reset_crossover_runtime(&kernel->crossoverRuntime, snapshot->crossover);\n''',
'''    if (firstPreparation || sampleRateChanged || leavingGraphBypass) {\n        reset_crossover_runtime(&kernel->crossoverRuntime, snapshot->crossover);\n        N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n''')
replace(c,
'''    snapshot.crossover = N60CrossoverSnapshotMakeBypassed();\n    snapshot.convolution.enabled = false;\n''',
'''    snapshot.crossover = N60CrossoverSnapshotMakeBypassed();\n    snapshot.dynamics = N60DynamicsSnapshotMakeBypassed(sampleRate);\n    snapshot.convolution.enabled = false;\n''')
replace(c,
'''    reset_crossover_runtime(&kernel->crossoverRuntime, initial.crossover);\n    reset_smoothed_gain(&kernel->inputGain, 1.0f);\n''',
'''    reset_crossover_runtime(&kernel->crossoverRuntime, initial.crossover);\n    N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    reset_smoothed_gain(&kernel->inputGain, 1.0f);\n''')
replace(c,
'''    reset_crossover_runtime(&kernel->crossoverRuntime, N60CrossoverSnapshotMakeBypassed());\n    N60PartitionedConvolverReset(kernel->convolver);\n''',
'''    reset_crossover_runtime(&kernel->crossoverRuntime, N60CrossoverSnapshotMakeBypassed());\n    N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    N60PartitionedConvolverReset(kernel->convolver);\n''')
replace(c,
'''        left *= next_gain_value(&kernel->balanceGainLeft);\n        right *= next_gain_value(&kernel->balanceGainRight);\n''',
'''        N60DynamicsProcessStereoFrame(&kernel->dynamicsRuntime, context->snapshot.dynamics, &left, &right);\n\n        left *= next_gain_value(&kernel->balanceGainLeft);\n        right *= next_gain_value(&kernel->balanceGainRight);\n''')
replace(c,
'''    publish_meter(&kernel->outputPeakLeftBits, &kernel->outputPeakRightBits, &kernel->outputRMSLeftBits, &kernel->outputRMSRightBits, &kernel->outputOverRangeSamples, context->outputPeakLeft, context->outputPeakRight, context->outputSquareSumLeft, context->outputSquareSumRight, context->outputOverRangeSamples, context->meteredFrames);\n    if (context->acquired && context->slotIndex < N60_SNAPSHOT_SLOT_COUNT) {\n''',
'''    publish_meter(&kernel->outputPeakLeftBits, &kernel->outputPeakRightBits, &kernel->outputRMSLeftBits, &kernel->outputRMSRightBits, &kernel->outputOverRangeSamples, context->outputPeakLeft, context->outputPeakRight, context->outputSquareSumLeft, context->outputSquareSumRight, context->outputOverRangeSamples, context->meteredFrames);\n    if (renderedFrames > 0) {\n        N60DynamicsTelemetry telemetry = N60DynamicsRuntimeTelemetry(&kernel->dynamicsRuntime);\n        atomic_store_explicit(&kernel->compressorGainReductionBits, float_to_bits(telemetry.compressorGainReductionDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->expanderAttenuationBits, float_to_bits(telemetry.expanderAttenuationDB), memory_order_relaxed);\n        atomic_store_explicit(&kernel->pauseGateGainBits, float_to_bits(telemetry.pauseGateGain), memory_order_relaxed);\n        atomic_store_explicit(&kernel->pauseGateOpen, telemetry.pauseGateOpen, memory_order_relaxed);\n    }\n    if (context->acquired && context->slotIndex < N60_SNAPSHOT_SLOT_COUNT) {\n''')
replace(c,
'''        diagnostics.crossoverSectionCount = context.snapshot.crossover.sectionCount;\n        diagnostics.convolutionEnabled = context.snapshot.convolution.enabled;\n''',
'''        diagnostics.crossoverSectionCount = context.snapshot.crossover.sectionCount;\n        diagnostics.compressorEnabled = context.snapshot.dynamics.compressor.enabled;\n        diagnostics.expanderEnabled = context.snapshot.dynamics.expander.enabled;\n        diagnostics.pauseGateEnabled = context.snapshot.dynamics.pauseGate.enabled;\n        diagnostics.convolutionEnabled = context.snapshot.convolution.enabled;\n''')
replace(c,
'''    diagnostics.roomCorrectionProgramMisses = atomic_load_explicit(&kernel->roomCorrectionProgramMisses, memory_order_relaxed);\n    diagnostics.inputMeter = load_meter_reading''',
'''    diagnostics.roomCorrectionProgramMisses = atomic_load_explicit(&kernel->roomCorrectionProgramMisses, memory_order_relaxed);\n    diagnostics.compressorGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->compressorGainReductionBits, memory_order_relaxed));\n    diagnostics.expanderAttenuationDB = bits_to_float(atomic_load_explicit(&kernel->expanderAttenuationBits, memory_order_relaxed));\n    diagnostics.pauseGateGain = bits_to_float(atomic_load_explicit(&kernel->pauseGateGainBits, memory_order_relaxed));\n    diagnostics.pauseGateOpen = atomic_load_explicit(&kernel->pauseGateOpen, memory_order_relaxed);\n    diagnostics.inputMeter = load_meter_reading''')

# --- Swift graph construction ---
s = 'NotchSixty/Audio/StereoPlaybackControl.swift'
replace(s,
'''        bassManagementConfiguration: BassManagementConfiguration,\n        playbackConfiguration: PlaybackControlConfiguration,\n        masterGainLinear: Float = 1.0\n''',
'''        bassManagementConfiguration: BassManagementConfiguration,\n        dynamicsConfiguration: DynamicsConfiguration = DynamicsConfiguration(),\n        playbackConfiguration: PlaybackControlConfiguration,\n        masterGainLinear: Float = 1.0\n''')
replace(s,
'''        guard N60DSPGraphSnapshotSetCrossover(\n            &graph,\n            bassManagementConfiguration.frequencyHz,\n            bassManagementConfiguration.topology.cType,\n            bassManagementConfiguration.monitorMode.cType,\n            DSPGainConfiguration.linearGain(forDB: bassManagementConfiguration.subGainDB),\n            bassManagementConfiguration.subPolarityInverted,\n            bassManagementConfiguration.enabled\n        ) else {\n            throw BassManagementConfigurationError.graphDesignFailed\n        }\n        return graph\n''',
'''        guard N60DSPGraphSnapshotSetCrossover(\n            &graph,\n            bassManagementConfiguration.frequencyHz,\n            bassManagementConfiguration.topology.cType,\n            bassManagementConfiguration.monitorMode.cType,\n            DSPGainConfiguration.linearGain(forDB: bassManagementConfiguration.subGainDB),\n            bassManagementConfiguration.subPolarityInverted,\n            bassManagementConfiguration.enabled\n        ) else {\n            throw BassManagementConfigurationError.graphDesignFailed\n        }\n        graph.dynamics = try dynamicsConfiguration.makeSnapshot(sampleRate: sampleRate)\n        return graph\n''', 1)

# --- Engine state and graph publication ---
e = 'NotchSixty/Audio/AudioIOEngine.swift'
replace(e,
'''    @Published private(set) var bassManagementConfiguration = BassManagementConfiguration()\n    @Published private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()\n''',
'''    @Published private(set) var bassManagementConfiguration = BassManagementConfiguration()\n    @Published private(set) var dynamicsConfiguration = DynamicsConfiguration()\n    @Published private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()\n''')

# Insert dynamicsConfiguration in every stereo graph build. All production call sites have
# playbackConfiguration immediately after bassManagementConfiguration.
p = Path(e)
t = p.read_text()
t = t.replace(
    'bassManagementConfiguration: configuration,\n                playbackConfiguration:',
    'bassManagementConfiguration: configuration,\n                dynamicsConfiguration: dynamicsConfiguration,\n                playbackConfiguration:'
)
t = t.replace(
    'bassManagementConfiguration: bassManagementConfiguration,\n                playbackConfiguration:',
    'bassManagementConfiguration: bassManagementConfiguration,\n                dynamicsConfiguration: dynamicsConfiguration,\n                playbackConfiguration:'
)
p.write_text(t)

# Add public replacement API before room-correction controls.
replace(e,
'''    func loadRoomCorrectionValidationFilter() throws {\n''',
'''    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {\n        _ = try configuration.makeSnapshot(sampleRate: transportSession?.outputFormat.sampleRate ?? 48_000)\n        if let session = transportSession {\n            var graph = try stereoEQConfiguration.makeGraphSnapshot(\n                sampleRate: session.outputFormat.sampleRate,\n                gainConfiguration: gainConfiguration,\n                bassManagementConfiguration: bassManagementConfiguration,\n                dynamicsConfiguration: configuration,\n                playbackConfiguration: playbackControlConfiguration,\n                masterGainLinear: currentMasterSoftwareGain\n            )\n            try attachActiveLinearPhaseProgramIfNeeded(\n                to: &graph,\n                stereoConfiguration: stereoEQConfiguration,\n                playbackConfiguration: playbackControlConfiguration\n            )\n            try attachActiveRoomCorrectionProgramIfNeeded(\n                to: &graph,\n                playbackConfiguration: playbackControlConfiguration\n            )\n            try session.publishDSPGraph(graph)\n        }\n        dynamicsConfiguration = configuration\n        lastErrorDescription = nil\n    }\n\n    func loadRoomCorrectionValidationFilter() throws {\n''')

# --- Product state boundary ---
app = 'NotchSixty/NotchSixtyApp.swift'
replace(app,
'''    var bassManagement: BassManagementConfiguration\n    var roomCorrection: RoomCorrectionConfiguration\n''',
'''    var bassManagement: BassManagementConfiguration\n    var dynamics: DynamicsConfiguration\n    var roomCorrection: RoomCorrectionConfiguration\n''')
replace(app,
'''        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),\n        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration()\n''',
'''        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),\n        dynamics: DynamicsConfiguration = DynamicsConfiguration(),\n        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration()\n''')
replace(app,
'''        self.bassManagement = bassManagement\n        self.roomCorrection = roomCorrection\n''',
'''        self.bassManagement = bassManagement\n        self.dynamics = dynamics\n        self.roomCorrection = roomCorrection\n''')
replace(app, 'static let currentSchemaVersion = 3', 'static let currentSchemaVersion = 4')
replace(app,
'''                bassManagement: audioEngine.bassManagementConfiguration,\n                roomCorrection: audioEngine.roomCorrectionConfiguration\n''',
'''                bassManagement: audioEngine.bassManagementConfiguration,\n                dynamics: audioEngine.dynamicsConfiguration,\n                roomCorrection: audioEngine.roomCorrectionConfiguration\n''')

# --- Provenance register ---
prov = 'docs/PROVENANCE.md'
p = Path(prov)
t = p.read_text()
needle = '| Latency-matched Reference / Delta audition |'
pos = t.find(needle)
if pos < 0:
    raise SystemExit('PR25 provenance row missing')
end = t.find('\n', pos)
row = '\n| Realtime dynamics foundation: compressor, expander, Pause Gate | Specification-derived / original commercial implementation | Product behavior requirements + standard dynamics gain-computer/envelope mathematics + proprietary PR #12–25 graph architecture | PR #26 independently implements a portable linked-stereo dynamics core with immutable precomputed time constants, soft-knee compression, bounded downward expansion, product-specific Pause Gate semantics (Attack = fade-out, Release = fade-in), buffer-rate telemetry, and deterministic tests. Legacy UI/config was used only to inventory externally visible controls/ranges. Historical processor algorithms/tests were not used as implementation reference. |'
p.write_text(t[:end] + row + t[end:])

# --- Xcode project ---
proj = 'NotchSixty.xcodeproj/project.pbxproj'
replace(proj,
'''\t\tA10000000000000000000016 /* StereoPlaybackControlTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000029 /* StereoPlaybackControlTests.swift */; };\n''',
'''\t\tA10000000000000000000016 /* StereoPlaybackControlTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A10000000000000000000029 /* StereoPlaybackControlTests.swift */; };\n\t\tA10000000000000000000017 /* DynamicsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000000000000000000002A /* DynamicsTests.swift */; };\n''')
replace(proj,
'''\t\tA20000000000000000000018 /* MasterVolumeDeviceController.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000028 /* MasterVolumeDeviceController.swift */; };\n''',
'''\t\tA20000000000000000000018 /* MasterVolumeDeviceController.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000028 /* MasterVolumeDeviceController.swift */; };\n\t\tA20000000000000000000019 /* DynamicsConfiguration.swift in Sources */ = {isa = PBXBuildFile; fileRef = A20000000000000000000029 /* DynamicsConfiguration.swift */; };\n''')
replace(proj,
'''\t\tA30000000000000000000012 /* N60Convolution.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000023 /* N60Convolution.c */; };\n''',
'''\t\tA30000000000000000000012 /* N60Convolution.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000023 /* N60Convolution.c */; };\n\t\tA30000000000000000000013 /* N60Dynamics.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000025 /* N60Dynamics.c */; };\n''')
replace(proj,
'''\t\tA10000000000000000000029 /* StereoPlaybackControlTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StereoPlaybackControlTests.swift; sourceTree = "<group>"; };\n''',
'''\t\tA10000000000000000000029 /* StereoPlaybackControlTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = StereoPlaybackControlTests.swift; sourceTree = "<group>"; };\n\t\tA1000000000000000000002A /* DynamicsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DynamicsTests.swift; sourceTree = "<group>"; };\n''')
replace(proj,
'''\t\tA20000000000000000000028 /* MasterVolumeDeviceController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MasterVolumeDeviceController.swift; sourceTree = "<group>"; };\n''',
'''\t\tA20000000000000000000028 /* MasterVolumeDeviceController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MasterVolumeDeviceController.swift; sourceTree = "<group>"; };\n\t\tA20000000000000000000029 /* DynamicsConfiguration.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DynamicsConfiguration.swift; sourceTree = "<group>"; };\n''')
replace(proj,
'''\t\tA30000000000000000000024 /* N60Convolution.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60Convolution.h; sourceTree = "<group>"; };\n''',
'''\t\tA30000000000000000000024 /* N60Convolution.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60Convolution.h; sourceTree = "<group>"; };\n\t\tA30000000000000000000025 /* N60Dynamics.c */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = N60Dynamics.c; sourceTree = "<group>"; };\n\t\tA30000000000000000000026 /* N60Dynamics.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60Dynamics.h; sourceTree = "<group>"; };\n''')
replace(proj,
'''\t\t\t\tA10000000000000000000029 /* StereoPlaybackControlTests.swift */,\n''',
'''\t\t\t\tA10000000000000000000029 /* StereoPlaybackControlTests.swift */,\n\t\t\t\tA1000000000000000000002A /* DynamicsTests.swift */,\n''')
replace(proj,
'''\t\t\t\tA20000000000000000000027 /* StereoPlaybackControl.swift */,\n''',
'''\t\t\t\tA20000000000000000000027 /* StereoPlaybackControl.swift */,\n\t\t\t\tA20000000000000000000029 /* DynamicsConfiguration.swift */,\n''')
replace(proj,
'''\t\t\t\tA30000000000000000000024 /* N60Convolution.h */,\n''',
'''\t\t\t\tA30000000000000000000024 /* N60Convolution.h */,\n\t\t\t\tA30000000000000000000025 /* N60Dynamics.c */,\n\t\t\t\tA30000000000000000000026 /* N60Dynamics.h */,\n''')
replace(proj,
'''\t\t\t\tA30000000000000000000012 /* N60Convolution.c in Sources */,\n''',
'''\t\t\t\tA30000000000000000000012 /* N60Convolution.c in Sources */,\n\t\t\t\tA30000000000000000000013 /* N60Dynamics.c in Sources */,\n''')
replace(proj,
'''\t\t\t\tA10000000000000000000016 /* StereoPlaybackControlTests.swift in Sources */,\n''',
'''\t\t\t\tA10000000000000000000016 /* StereoPlaybackControlTests.swift in Sources */,\n\t\t\t\tA10000000000000000000017 /* DynamicsTests.swift in Sources */,\n''')
replace(proj,
'''\t\t\t\tA20000000000000000000017 /* StereoPlaybackControl.swift in Sources */,\n''',
'''\t\t\t\tA20000000000000000000017 /* StereoPlaybackControl.swift in Sources */,\n\t\t\t\tA20000000000000000000019 /* DynamicsConfiguration.swift in Sources */,\n''')
