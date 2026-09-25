from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    t = p.read_text()
    if t.count(old) < count:
        raise SystemExit(f'missing marker in {path}: {old[:120]!r}')
    p.write_text(t.replace(old, new, count))

# Xcode project: add protection C module and tests.
p = 'NotchSixty.xcodeproj/project.pbxproj'
replace(p,
'''\t\tA10000000000000000000017 /* DynamicsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000000000000000000002A /* DynamicsTests.swift */; };\n''',
'''\t\tA10000000000000000000017 /* DynamicsTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000000000000000000002A /* DynamicsTests.swift */; };\n\t\tA10000000000000000000018 /* ProtectionTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = A1000000000000000000002B /* ProtectionTests.swift */; };\n''')
replace(p,
'''\t\tA30000000000000000000013 /* N60Dynamics.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000025 /* N60Dynamics.c */; };\n''',
'''\t\tA30000000000000000000013 /* N60Dynamics.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000025 /* N60Dynamics.c */; };\n\t\tA30000000000000000000014 /* N60Protection.c in Sources */ = {isa = PBXBuildFile; fileRef = A30000000000000000000027 /* N60Protection.c */; };\n''')
replace(p,
'''\t\tA1000000000000000000002A /* DynamicsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DynamicsTests.swift; sourceTree = "<group>"; };\n''',
'''\t\tA1000000000000000000002A /* DynamicsTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DynamicsTests.swift; sourceTree = "<group>"; };\n\t\tA1000000000000000000002B /* ProtectionTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProtectionTests.swift; sourceTree = "<group>"; };\n''')
replace(p,
'''\t\tA30000000000000000000026 /* N60Dynamics.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60Dynamics.h; sourceTree = "<group>"; };\n''',
'''\t\tA30000000000000000000026 /* N60Dynamics.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60Dynamics.h; sourceTree = "<group>"; };\n\t\tA30000000000000000000027 /* N60Protection.c */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.c; path = N60Protection.c; sourceTree = "<group>"; };\n\t\tA30000000000000000000028 /* N60Protection.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = N60Protection.h; sourceTree = "<group>"; };\n''')
replace(p,
'''\t\t\t\tA1000000000000000000002A /* DynamicsTests.swift */,\n''',
'''\t\t\t\tA1000000000000000000002A /* DynamicsTests.swift */,\n\t\t\t\tA1000000000000000000002B /* ProtectionTests.swift */,\n''')
replace(p,
'''\t\t\t\tA30000000000000000000026 /* N60Dynamics.h */,\n''',
'''\t\t\t\tA30000000000000000000026 /* N60Dynamics.h */,\n\t\t\t\tA30000000000000000000027 /* N60Protection.c */,\n\t\t\t\tA30000000000000000000028 /* N60Protection.h */,\n''')
replace(p,
'''\t\t\t\tA10000000000000000000017 /* DynamicsTests.swift in Sources */,\n''',
'''\t\t\t\tA10000000000000000000017 /* DynamicsTests.swift in Sources */,\n\t\t\t\tA10000000000000000000018 /* ProtectionTests.swift in Sources */,\n''')
replace(p,
'''\t\t\t\tA30000000000000000000013 /* N60Dynamics.c in Sources */,\n''',
'''\t\t\t\tA30000000000000000000013 /* N60Dynamics.c in Sources */,\n\t\t\t\tA30000000000000000000014 /* N60Protection.c in Sources */,\n''')

# Public render graph contract.
p = 'NotchSixty/Audio/Realtime/N60RenderKernel.h'
replace(p, '#include "N60Dynamics.h"\n', '#include "N60Dynamics.h"\n#include "N60Protection.h"\n')
replace(p,
'''    N60DynamicsSnapshot dynamics;\n    N60ConvolutionGraphState convolution;\n''',
'''    N60DynamicsSnapshot dynamics;\n    N60ProtectionSnapshot protection;\n    N60ConvolutionGraphState convolution;\n''')
replace(p,
'''    float pauseGateGain;\n    bool pauseGateOpen;\n    bool convolutionEnabled;\n''',
'''    float pauseGateGain;\n    bool pauseGateOpen;\n    bool softClipperEnabled;\n    bool limiterEnabled;\n    N60OversamplingFactor oversamplingFactor;\n    N60OversamplingFactor effectiveOversamplingFactor;\n    float inputTruePeakLinear;\n    float outputTruePeakLinear;\n    float limiterGainReductionDB;\n    uint64_t limiterSafetyClampSamples;\n    bool convolutionEnabled;\n''')

# Render kernel integration.
p = 'NotchSixty/Audio/Realtime/N60RenderKernel.c'
replace(p,
'''    N60DynamicsRuntime dynamicsRuntime;\n    N60PartitionedConvolver *convolver;\n''',
'''    N60DynamicsRuntime dynamicsRuntime;\n    N60ProtectionRuntime *protectionRuntime;\n    N60PartitionedConvolver *convolver;\n''')
replace(p,
'''    bool preparedEQBypassed;\n\n    _Atomic uint64_t renderedFrames;\n''',
'''    bool preparedEQBypassed;\n    N60OversamplingFactor preparedProtectionFactor;\n    bool preparedLimiterEnabled;\n    uint32_t preparedLimiterLookAheadHighSamples;\n\n    _Atomic uint64_t renderedFrames;\n''')
replace(p,
'''    _Atomic bool pauseGateOpen;\n\n    _Atomic uint32_t inputPeakLeftBits;\n''',
'''    _Atomic bool pauseGateOpen;\n    _Atomic uint32_t inputTruePeakBits;\n    _Atomic uint32_t outputTruePeakBits;\n    _Atomic uint32_t limiterGainReductionBits;\n    _Atomic uint64_t limiterSafetyClampSamples;\n\n    _Atomic uint32_t inputPeakLeftBits;\n''')
replace(p,
'''        || !N60DynamicsSnapshotIsValid(snapshot.dynamics)\n        || !convolution_snapshot_is_valid(snapshot.convolution)\n''',
'''        || !N60DynamicsSnapshotIsValid(snapshot.dynamics)\n        || !N60ProtectionSnapshotIsValid(&snapshot.protection)\n        || !convolution_snapshot_is_valid(snapshot.convolution)\n''')
replace(p,
'''    if (firstPreparation || sampleRateChanged || leavingGraphBypass) {\n        reset_crossover_runtime(&kernel->crossoverRuntime, snapshot->crossover);\n        N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    } else {\n''',
'''    bool protectionStructureChanged = kernel->preparedProtectionFactor != snapshot->protection.effectiveFactor\n        || kernel->preparedLimiterEnabled != snapshot->protection.limiterEnabled\n        || kernel->preparedLimiterLookAheadHighSamples != snapshot->protection.limiterLookAheadHighSamples;\n    if (firstPreparation || sampleRateChanged || leavingGraphBypass) {\n        reset_crossover_runtime(&kernel->crossoverRuntime, snapshot->crossover);\n        N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    } else {\n''')
replace(p,
'''    kernel->preparedGeneration = snapshot->generation;\n    kernel->preparedSampleRate = snapshot->sampleRate;\n''',
'''    if (firstPreparation || sampleRateChanged || leavingGraphBypass || protectionStructureChanged) {\n        N60ProtectionRuntimeReset(kernel->protectionRuntime);\n    }\n    kernel->preparedProtectionFactor = snapshot->protection.effectiveFactor;\n    kernel->preparedLimiterEnabled = snapshot->protection.limiterEnabled;\n    kernel->preparedLimiterLookAheadHighSamples = snapshot->protection.limiterLookAheadHighSamples;\n\n    kernel->preparedGeneration = snapshot->generation;\n    kernel->preparedSampleRate = snapshot->sampleRate;\n''')
replace(p,
'''    snapshot.dynamics = N60DynamicsSnapshotMakeBypassed(sampleRate);\n    snapshot.convolution.enabled = false;\n''',
'''    snapshot.dynamics = N60DynamicsSnapshotMakeBypassed(sampleRate);\n    snapshot.protection = N60ProtectionSnapshotMakeBypassed(sampleRate);\n    snapshot.convolution.enabled = false;\n''')
replace(p,
'''    kernel->roomCorrectionConvolver = N60PartitionedConvolverCreate();\n    if (kernel->roomCorrectionConvolver == NULL) {\n        N60PartitionedConvolverDestroy(kernel->convolver);\n        free(kernel);\n        return NULL;\n    }\n    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);\n''',
'''    kernel->roomCorrectionConvolver = N60PartitionedConvolverCreate();\n    if (kernel->roomCorrectionConvolver == NULL) {\n        N60PartitionedConvolverDestroy(kernel->convolver);\n        free(kernel);\n        return NULL;\n    }\n    kernel->protectionRuntime = N60ProtectionRuntimeCreate();\n    if (kernel->protectionRuntime == NULL) {\n        N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);\n        N60PartitionedConvolverDestroy(kernel->convolver);\n        free(kernel);\n        return NULL;\n    }\n    N60DSPGraphSnapshot initial = N60DSPGraphSnapshotMakeUnity(48000.0);\n''')
replace(p,
'''    N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);\n    N60PartitionedConvolverDestroy(kernel->convolver);\n    free(kernel);\n''',
'''    N60ProtectionRuntimeDestroy(kernel->protectionRuntime);\n    N60PartitionedConvolverDestroy(kernel->roomCorrectionConvolver);\n    N60PartitionedConvolverDestroy(kernel->convolver);\n    free(kernel);\n''')
replace(p,
'''    N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    N60PartitionedConvolverReset(kernel->convolver);\n''',
'''    N60DynamicsRuntimeReset(&kernel->dynamicsRuntime);\n    N60ProtectionRuntimeReset(kernel->protectionRuntime);\n    N60PartitionedConvolverReset(kernel->convolver);\n''')
replace(p,
'''    kernel->preparedEQBypassed = false;\n    atomic_store_explicit(&kernel->renderedFrames, 0, memory_order_relaxed);\n''',
'''    kernel->preparedEQBypassed = false;\n    kernel->preparedProtectionFactor = N60OversamplingFactor1x;\n    kernel->preparedLimiterEnabled = false;\n    kernel->preparedLimiterLookAheadHighSamples = 0;\n    atomic_store_explicit(&kernel->renderedFrames, 0, memory_order_relaxed);\n''')
replace(p,
'''N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel *kernel) {\n    N60RenderKernelRenderContext context = acquire_render_context(kernel);\n    if (context.acquired) prepare_runtime_for_snapshot(kernel, &context.snapshot);\n    return context;\n}\n''',
'''N60RenderKernelRenderContext N60RenderKernelBeginRender(N60RenderKernel *kernel) {\n    N60RenderKernelRenderContext context = acquire_render_context(kernel);\n    if (context.acquired) {\n        prepare_runtime_for_snapshot(kernel, &context.snapshot);\n        N60ProtectionRuntimeBeginBuffer(kernel->protectionRuntime);\n    }\n    return context;\n}\n''')
replace(p,
'''        float outputGain = next_gain_value(&kernel->outputGain);\n        left *= outputGain;\n        right *= outputGain;\n\n        N60DynamicsProcessPauseGateStereoFrame(\n''',
'''        float outputGain = next_gain_value(&kernel->outputGain);\n        left *= outputGain;\n        right *= outputGain;\n\n        N60ProtectionProcessStereoFrame(\n            kernel->protectionRuntime,\n            &context->snapshot.protection,\n            &left,\n            &right\n        );\n\n        N60DynamicsProcessPauseGateStereoFrame(\n''')
replace(p,
'''        atomic_store_explicit(&kernel->pauseGateOpen, telemetry.pauseGateOpen, memory_order_relaxed);\n    }\n''',
'''        atomic_store_explicit(&kernel->pauseGateOpen, telemetry.pauseGateOpen, memory_order_relaxed);\n        N60ProtectionTelemetry protection = N60ProtectionRuntimeTelemetry(kernel->protectionRuntime);\n        atomic_store_explicit(&kernel->inputTruePeakBits, float_to_bits(protection.inputTruePeakLinear), memory_order_relaxed);\n        atomic_store_explicit(&kernel->outputTruePeakBits, float_to_bits(protection.outputTruePeakLinear), memory_order_relaxed);\n        atomic_store_explicit(&kernel->limiterGainReductionBits, float_to_bits(protection.limiterGainReductionDB), memory_order_relaxed);\n        atomic_fetch_add_explicit(&kernel->limiterSafetyClampSamples, protection.limiterSafetyClampSamples, memory_order_relaxed);\n    }\n''')
replace(p,
'''        diagnostics.pauseGateEnabled = context.snapshot.dynamics.pauseGate.enabled;\n        diagnostics.convolutionEnabled = context.snapshot.convolution.enabled;\n''',
'''        diagnostics.pauseGateEnabled = context.snapshot.dynamics.pauseGate.enabled;\n        diagnostics.softClipperEnabled = context.snapshot.protection.softClipperEnabled;\n        diagnostics.limiterEnabled = context.snapshot.protection.limiterEnabled;\n        diagnostics.oversamplingFactor = context.snapshot.protection.oversamplingFactor;\n        diagnostics.effectiveOversamplingFactor = context.snapshot.protection.effectiveFactor;\n        diagnostics.convolutionEnabled = context.snapshot.convolution.enabled;\n''')
replace(p,
'''    diagnostics.pauseGateOpen = atomic_load_explicit(&kernel->pauseGateOpen, memory_order_relaxed);\n    diagnostics.inputMeter = load_meter_reading''',
'''    diagnostics.pauseGateOpen = atomic_load_explicit(&kernel->pauseGateOpen, memory_order_relaxed);\n    diagnostics.inputTruePeakLinear = bits_to_float(atomic_load_explicit(&kernel->inputTruePeakBits, memory_order_relaxed));\n    diagnostics.outputTruePeakLinear = bits_to_float(atomic_load_explicit(&kernel->outputTruePeakBits, memory_order_relaxed));\n    diagnostics.limiterGainReductionDB = bits_to_float(atomic_load_explicit(&kernel->limiterGainReductionBits, memory_order_relaxed));\n    diagnostics.limiterSafetyClampSamples = atomic_load_explicit(&kernel->limiterSafetyClampSamples, memory_order_relaxed);\n    diagnostics.inputMeter = load_meter_reading''')

# Graph builder: protection is part of dynamics domain and contributes deterministic latency.
p = 'NotchSixty/Audio/StereoPlaybackControl.swift'
replace(p,
'''        graph.dynamics = try dynamicsConfiguration.makeSnapshot(sampleRate: sampleRate)\n        return graph\n''',
'''        graph.dynamics = try dynamicsConfiguration.makeSnapshot(sampleRate: sampleRate)\n        graph.protection = try dynamicsConfiguration.makeProtectionSnapshot(sampleRate: sampleRate)\n        let protectionLatency = UInt64(graph.protection.latencyFrames)\n        let totalLatency = UInt64(graph.latencyFrames) + protectionLatency\n        guard totalLatency < UInt64(N60_MAX_AUDITION_DELAY_FRAMES) else {\n            throw DynamicsConfigurationError.invalidOversampling\n        }\n        graph.latencyFrames = UInt32(totalLatency)\n        return graph\n''')

# Audio engine validation, transition semantics, and startup graph correctness.
p = 'NotchSixty/Audio/AudioIOEngine.swift'
replace(p,
'''    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {\n        _ = try configuration.makeSnapshot(sampleRate: transportSession?.outputFormat.sampleRate ?? 48_000)\n        if let session = transportSession {\n''',
'''    func replaceDynamicsConfiguration(_ configuration: DynamicsConfiguration) throws {\n        let validationRate = transportSession?.outputFormat.sampleRate ?? 48_000\n        _ = try configuration.makeSnapshot(sampleRate: validationRate)\n        let newProtection = try configuration.makeProtectionSnapshot(sampleRate: validationRate)\n        if let session = transportSession {\n            let oldProtection = try dynamicsConfiguration.makeProtectionSnapshot(sampleRate: session.outputFormat.sampleRate)\n''')
replace(p,
'''            try attachActiveRoomCorrectionProgramIfNeeded(\n                to: &graph,\n                playbackConfiguration: playbackControlConfiguration\n            )\n            try session.publishDSPGraph(graph)\n        }\n        dynamicsConfiguration = configuration\n''',
'''            try attachActiveRoomCorrectionProgramIfNeeded(\n                to: &graph,\n                playbackConfiguration: playbackControlConfiguration\n            )\n            let protectionStructureChanged = oldProtection.latencyFrames != newProtection.latencyFrames\n                || oldProtection.effectiveFactor != newProtection.effectiveFactor\n                || oldProtection.limiterEnabled != newProtection.limiterEnabled\n                || dynamicsConfiguration.softClipper.enabled != configuration.softClipper.enabled\n            if protectionStructureChanged {\n                try session.transitionDSPGraph(graph)\n            } else {\n                try session.publishDSPGraph(graph)\n            }\n        }\n        dynamicsConfiguration = configuration\n''', 1)
# buildTransport was still relying on the default dynamics argument; preserve configured dynamics on rebuild/recovery.
replace(p,
'''        var graph = try stereoEQConfiguration.makeGraphSnapshot(\n            sampleRate: session.outputFormat.sampleRate,\n            gainConfiguration: gainConfiguration,\n            bassManagementConfiguration: bassManagementConfiguration,\n            playbackConfiguration: playbackControlConfiguration\n        )\n''',
'''        var graph = try stereoEQConfiguration.makeGraphSnapshot(\n            sampleRate: session.outputFormat.sampleRate,\n            gainConfiguration: gainConfiguration,\n            bassManagementConfiguration: bassManagementConfiguration,\n            dynamicsConfiguration: dynamicsConfiguration,\n            playbackConfiguration: playbackControlConfiguration\n        )\n''')

# Product schema evolves with protection configuration.
p = 'NotchSixty/NotchSixtyApp.swift'
replace(p, '    static let currentSchemaVersion = 4\n', '    static let currentSchemaVersion = 5\n')

# Existing schema assertion.
p = 'NotchSixtyTests/NotchSixtyTests.swift'
t = Path(p).read_text()
if 'XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 4)' in t:
    t = t.replace('XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 4)', 'XCTAssertEqual(ProductConfiguration.currentSchemaVersion, 5)')
elif 'schemaVersion, 4' in t:
    t = t.replace('schemaVersion, 4', 'schemaVersion, 5')
Path(p).write_text(t)
