from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    text = p.read_text()
    if text.count(old) < count:
        raise SystemExit(f"pattern missing in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, count))

# C public contract
h = "NotchSixty/Audio/Realtime/N60RenderKernel.h"
replace(h,
'''#define N60_EQ_CHANNEL_STEREO (N60_EQ_CHANNEL_LEFT | N60_EQ_CHANNEL_RIGHT)\n''',
'''#define N60_EQ_CHANNEL_STEREO (N60_EQ_CHANNEL_LEFT | N60_EQ_CHANNEL_RIGHT)\n#define N60_MAX_AUDITION_DELAY_FRAMES 131072u\n\ntypedef enum {\n    N60AuditionModeProcessed = 0,\n    N60AuditionModeReference = 1,\n    N60AuditionModeDelta = 2,\n} N60AuditionMode;\n''')
replace(h,
'''    bool bypassed;\n    uint32_t latencyFrames;\n''',
'''    bool bypassed;\n    N60AuditionMode auditionMode;\n    uint32_t latencyFrames;\n''', 2)
replace(h,
'''    bool bypassed;\n    float inputGainLinear;\n''',
'''    bool bypassed;\n    N60AuditionMode auditionMode;\n    float inputGainLinear;\n''')

# C runtime
c = "NotchSixty/Audio/Realtime/N60RenderKernel.c"
replace(c,
'''    N60SmoothedGain balanceGainRight;\n    uint64_t preparedGeneration;\n''',
'''    N60SmoothedGain balanceGainRight;\n    float referenceDelayLeft[N60_MAX_AUDITION_DELAY_FRAMES];\n    float referenceDelayRight[N60_MAX_AUDITION_DELAY_FRAMES];\n    uint32_t referenceDelayWriteIndex;\n    uint64_t preparedGeneration;\n''')
replace(c,
'''        || !isfinite(snapshot.balanceGainRightLinear)\n        || snapshot.balanceGainRightLinear < 0.0f\n        || snapshot.balanceGainRightLinear > 1.0f\n        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n''',
'''        || !isfinite(snapshot.balanceGainRightLinear)\n        || snapshot.balanceGainRightLinear < 0.0f\n        || snapshot.balanceGainRightLinear > 1.0f\n        || snapshot.auditionMode < N60AuditionModeProcessed\n        || snapshot.auditionMode > N60AuditionModeDelta\n        || (snapshot.auditionMode != N60AuditionModeProcessed\n            && snapshot.latencyFrames >= N60_MAX_AUDITION_DELAY_FRAMES)\n        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n''')
replace(c,
'''static void meter_sample(float left, float right, float *peakLeft, float *peakRight, double *squareSumLeft, double *squareSumRight, uint64_t *overRangeSamples) {\n''',
'''static void process_reference_delay(\n    N60RenderKernel *kernel,\n    uint32_t delayFrames,\n    float inputLeft,\n    float inputRight,\n    float *referenceLeft,\n    float *referenceRight\n) {\n    if (delayFrames == 0) {\n        *referenceLeft = inputLeft;\n        *referenceRight = inputRight;\n    } else {\n        uint32_t readIndex = (kernel->referenceDelayWriteIndex\n            + N60_MAX_AUDITION_DELAY_FRAMES\n            - delayFrames) % N60_MAX_AUDITION_DELAY_FRAMES;\n        *referenceLeft = kernel->referenceDelayLeft[readIndex];\n        *referenceRight = kernel->referenceDelayRight[readIndex];\n    }\n\n    kernel->referenceDelayLeft[kernel->referenceDelayWriteIndex] = inputLeft;\n    kernel->referenceDelayRight[kernel->referenceDelayWriteIndex] = inputRight;\n    kernel->referenceDelayWriteIndex = (kernel->referenceDelayWriteIndex + 1u) % N60_MAX_AUDITION_DELAY_FRAMES;\n}\n\nstatic void meter_sample(float left, float right, float *peakLeft, float *peakRight, double *squareSumLeft, double *squareSumRight, uint64_t *overRangeSamples) {\n''')
replace(c,
'''    snapshot.bypassed = false;\n    snapshot.latencyFrames = 0;\n''',
'''    snapshot.bypassed = false;\n    snapshot.auditionMode = N60AuditionModeProcessed;\n    snapshot.latencyFrames = 0;\n''')
replace(c,
'''    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    return kernel;\n''',
'''    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    kernel->referenceDelayWriteIndex = 0;\n    return kernel;\n''')
replace(c,
'''    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    kernel->preparedGeneration = 0;\n''',
'''    reset_smoothed_gain(&kernel->balanceGainRight, 1.0f);\n    memset(kernel->referenceDelayLeft, 0, sizeof(kernel->referenceDelayLeft));\n    memset(kernel->referenceDelayRight, 0, sizeof(kernel->referenceDelayRight));\n    kernel->referenceDelayWriteIndex = 0;\n    kernel->preparedGeneration = 0;\n''')
replace(c,
'''    float left = sanitize_sample(kernel, inputLeft);\n    float right = sanitize_sample(kernel, inputRight);\n    meter_sample(left, right, &context->inputPeakLeft, &context->inputPeakRight, &context->inputSquareSumLeft, &context->inputSquareSumRight, &context->inputOverRangeSamples);\n\n    if (context->acquired && !context->snapshot.bypassed) {\n''',
'''    float left = sanitize_sample(kernel, inputLeft);\n    float right = sanitize_sample(kernel, inputRight);\n    float referenceLeft = 0.0f;\n    float referenceRight = 0.0f;\n    uint32_t referenceDelayFrames = context->acquired ? context->snapshot.latencyFrames : 0;\n    process_reference_delay(kernel, referenceDelayFrames, left, right, &referenceLeft, &referenceRight);\n    meter_sample(left, right, &context->inputPeakLeft, &context->inputPeakRight, &context->inputSquareSumLeft, &context->inputSquareSumRight, &context->inputOverRangeSamples);\n\n    if (context->acquired && !context->snapshot.bypassed) {\n''')
replace(c,
'''        float outputGain = next_gain_value(&kernel->outputGain);\n        left *= outputGain;\n        right *= outputGain;\n    } else {\n''',
'''        float outputGain = next_gain_value(&kernel->outputGain);\n        left *= outputGain;\n        right *= outputGain;\n\n        switch (context->snapshot.auditionMode) {\n        case N60AuditionModeReference:\n            left = referenceLeft;\n            right = referenceRight;\n            break;\n        case N60AuditionModeDelta:\n            left -= referenceLeft;\n            right -= referenceRight;\n            break;\n        case N60AuditionModeProcessed:\n        default:\n            break;\n        }\n    } else {\n''')
replace(c,
'''        diagnostics.bypassed = context.snapshot.bypassed;\n        diagnostics.inputGainLinear = context.snapshot.inputGainLinear;\n''',
'''        diagnostics.bypassed = context.snapshot.bypassed;\n        diagnostics.auditionMode = context.snapshot.auditionMode;\n        diagnostics.inputGainLinear = context.snapshot.inputGainLinear;\n''')

# Swift audition model / graph mapping
s = "NotchSixty/Audio/StereoPlaybackControl.swift"
replace(s,
'''enum FIRUpdatePolicy {\n    static func isRawBypassed(_ playback: PlaybackControlConfiguration) -> Bool {\n        playback.globalBypassed || playback.flatAuditionEnabled\n    }\n''',
'''enum FIRUpdatePolicy {\n    static func isRawBypassed(_ playback: PlaybackControlConfiguration) -> Bool {\n        playback.globalBypassed\n    }\n''')
replace(s,
'''struct PlaybackControlConfiguration: Equatable, Sendable {\n    static let balanceRange = -1.0...1.0\n\n    var balance: Double = 0\n    var globalBypassed = false\n    var flatAuditionEnabled = false\n\n    var balanceLinearGains: (left: Float, right: Float) {\n''',
'''enum AuditionMode: String, CaseIterable, Identifiable, Sendable {\n    case processed\n    case reference\n    case delta\n\n    var id: String { rawValue }\n\n    var displayName: String {\n        switch self {\n        case .processed: return "Processed"\n        case .reference: return "Reference"\n        case .delta: return "Delta"\n        }\n    }\n\n    var cType: N60AuditionMode {\n        switch self {\n        case .processed: return N60AuditionModeProcessed\n        case .reference: return N60AuditionModeReference\n        case .delta: return N60AuditionModeDelta\n        }\n    }\n}\n\nstruct PlaybackControlConfiguration: Equatable, Sendable {\n    static let balanceRange = -1.0...1.0\n\n    var balance: Double\n    var globalBypassed: Bool\n    var auditionMode: AuditionMode\n\n    init(\n        balance: Double = 0,\n        globalBypassed: Bool = false,\n        flatAuditionEnabled: Bool = false,\n        auditionMode: AuditionMode? = nil\n    ) {\n        self.balance = balance\n        self.globalBypassed = globalBypassed\n        self.auditionMode = auditionMode ?? (flatAuditionEnabled ? .reference : .processed)\n    }\n\n    var flatAuditionEnabled: Bool {\n        get { auditionMode == .reference }\n        set { auditionMode = newValue ? .reference : .processed }\n    }\n\n    var balanceLinearGains: (left: Float, right: Float) {\n''')
replace(s,
'''        graph.bypassed = playbackConfiguration.globalBypassed || playbackConfiguration.flatAuditionEnabled\n        graph.eqBypassed = bypassed\n''',
'''        graph.bypassed = playbackConfiguration.globalBypassed\n        graph.auditionMode = playbackConfiguration.auditionMode.cType\n        graph.eqBypassed = bypassed\n''')

# Engine public setter + transition semantics
engine = "NotchSixty/Audio/AudioIOEngine.swift"
replace(engine,
'''    func setFlatAuditionEnabled(_ enabled: Bool) throws {\n        var updated = playbackControlConfiguration\n        updated.flatAuditionEnabled = enabled\n        try applyPlaybackControlConfiguration(updated)\n    }\n''',
'''    func setFlatAuditionEnabled(_ enabled: Bool) throws {\n        var updated = playbackControlConfiguration\n        updated.auditionMode = enabled ? .reference : .processed\n        try applyPlaybackControlConfiguration(updated)\n    }\n\n    func setAuditionMode(_ mode: AuditionMode) throws {\n        var updated = playbackControlConfiguration\n        updated.auditionMode = mode\n        try applyPlaybackControlConfiguration(updated)\n    }\n''')
replace(engine,
'''            if wasBypassed != willBeBypassed {\n                try session.transitionDSPGraph(graph)\n            } else {\n                try session.publishDSPGraph(graph)\n            }\n''',
'''            let auditionModeChanged = playbackControlConfiguration.auditionMode != configuration.auditionMode\n            if wasBypassed != willBeBypassed || auditionModeChanged {\n                try session.transitionDSPGraph(graph)\n            } else {\n                try session.publishDSPGraph(graph)\n            }\n''')

# Tests: core semantic coverage
path = Path("NotchSixtyTests/StereoPlaybackControlTests.swift")
text = path.read_text()
marker = "    func testGraphBypassReturnsUntreatedStereoSamples() {"
if marker not in text:
    raise SystemExit("test insertion marker missing")
new_tests = r'''    func testReferenceAuditionDelaysRawInputByPublishedLatency() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.auditionMode = N60AuditionModeReference
        graph.latencyFrames = 3
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        let inputs: [Float] = [1, 0.5, -0.25, 0, 0, 0]
        var outputs: [Float] = []
        for sample in inputs {
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, sample, &left, &right)
            outputs.append(left)
            XCTAssertEqual(left, right, accuracy: 0.000_001)
        }
        XCTAssertEqual(outputs[0], 0, accuracy: 0.000_001)
        XCTAssertEqual(outputs[1], 0, accuracy: 0.000_001)
        XCTAssertEqual(outputs[2], 0, accuracy: 0.000_001)
        XCTAssertEqual(outputs[3], 1, accuracy: 0.000_001)
        XCTAssertEqual(outputs[4], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(outputs[5], -0.25, accuracy: 0.000_001)
    }

    func testDeltaAuditionNullsUnityConvolutionAgainstLatencyMatchedReference() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var program = N60ConvolutionProgramInfo()
        var taps: [Float] = [1]
        XCTAssertTrue(taps.withUnsafeBufferPointer { buffer in
            N60RenderKernelPrepareConvolutionProgram(
                kernel,
                0,
                buffer.baseAddress!,
                nil,
                UInt32(buffer.count),
                0,
                &program
            )
        })

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&graph, 0, program, true))
        graph.auditionMode = N60AuditionModeDelta
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var maxAbs: Float = 0
        for frame in 0..<2_000 {
            let sample = Float(sin(Double(frame) * 0.031) * 0.4)
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, sample, -sample, &left, &right)
            if frame > Int(program.engineLatencyFrames) + 16 {
                maxAbs = max(maxAbs, abs(left), abs(right))
            }
        }
        XCTAssertLessThan(maxAbs, 0.000_01)
    }

    func testGlobalBypassOverridesAuditionModeAndStillAppliesMasterGain() {
        guard let kernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to create render kernel")
        }
        defer { N60RenderKernelDestroy(kernel) }

        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.bypassed = true
        graph.auditionMode = N60AuditionModeDelta
        graph.latencyFrames = 128
        graph.masterGainLinear = 0.5
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.4, -0.2, &left, &right)
        XCTAssertEqual(left, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.1, accuracy: 0.000_001)
    }

    func testFlatCompatibilityAliasMapsToReferenceAudition() {
        var playback = PlaybackControlConfiguration(flatAuditionEnabled: true)
        XCTAssertEqual(playback.auditionMode, .reference)
        XCTAssertTrue(playback.flatAuditionEnabled)
        playback.flatAuditionEnabled = false
        XCTAssertEqual(playback.auditionMode, .processed)
        XCTAssertFalse(FIRUpdatePolicy.isRawBypassed(PlaybackControlConfiguration(auditionMode: .reference)))
        XCTAssertTrue(FIRUpdatePolicy.isRawBypassed(PlaybackControlConfiguration(globalBypassed: true)))
    }

'''
path.write_text(text.replace(marker, new_tests + marker, 1))
