from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Realtime graph: select L/R or M/S only around the main EQ region.
# ---------------------------------------------------------------------------
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
header = replace_once(
    header,
    "typedef enum {\n    N60AuditionModeProcessed = 0,\n    N60AuditionModeReference = 1,\n    N60AuditionModeDelta = 2,\n} N60AuditionMode;\n",
    "typedef enum {\n    N60AuditionModeProcessed = 0,\n    N60AuditionModeReference = 1,\n    N60AuditionModeDelta = 2,\n} N60AuditionMode;\n\ntypedef enum {\n    N60EQDomainLeftRight = 0,\n    N60EQDomainMidSide = 1,\n} N60EQDomain;\n",
    "EQ domain enum",
)
header = replace_once(
    header,
    "    bool eqBypassed;\n    uint32_t eqBandCount;",
    "    bool eqBypassed;\n    N60EQDomain eqDomain;\n    uint32_t eqBandCount;",
    "graph EQ domain field",
)
header_path.write_text(header)

kernel_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
kernel = kernel_path.read_text()
kernel = replace_once(
    kernel,
    "        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n",
    "        || snapshot.eqDomain < N60EQDomainLeftRight\n        || snapshot.eqDomain > N60EQDomainMidSide\n        || snapshot.eqBandCount > N60_MAX_EQ_RENDER_SLOTS\n",
    "EQ domain validation",
)
kernel = replace_once(
    kernel,
    "    snapshot.eqBypassed = false;\n    snapshot.eqBandCount = 0;",
    "    snapshot.eqBypassed = false;\n    snapshot.eqDomain = N60EQDomainLeftRight;\n    snapshot.eqBandCount = 0;",
    "unity EQ domain",
)
old_eq = '''        if (!context->snapshot.eqBypassed) {
            for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) {
                N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
                if (!runtime->currentEnabled && runtime->transitionFramesRemaining == 0) continue;
                left = process_eq_band(runtime, left, N60_EQ_CHANNEL_LEFT);
                right = process_eq_band(runtime, right, N60_EQ_CHANNEL_RIGHT);
            }
            advance_eq_transitions(kernel);
'''
new_eq = '''        if (!context->snapshot.eqBypassed) {
            bool midSideEQ = context->snapshot.eqDomain == N60EQDomainMidSide;
            if (midSideEQ) {
                float mid = 0.5f * (left + right);
                float side = 0.5f * (left - right);
                left = mid;
                right = side;
            }
            for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) {
                N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
                if (!runtime->currentEnabled && runtime->transitionFramesRemaining == 0) continue;
                left = process_eq_band(runtime, left, N60_EQ_CHANNEL_LEFT);
                right = process_eq_band(runtime, right, N60_EQ_CHANNEL_RIGHT);
            }
            if (midSideEQ) {
                float mid = left;
                float side = right;
                left = mid + side;
                right = mid - side;
            }
            advance_eq_transitions(kernel);
'''
kernel = replace_once(kernel, old_eq, new_eq, "minimum-phase M/S EQ wrapper")
old_conv = '''        if (context->snapshot.convolution.enabled) {
            float convolvedLeft = left;
            float convolvedRight = right;
            if (N60PartitionedConvolverProcessSample(
                    kernel->convolver,
                    context->snapshot.convolution.programSlot,
                    context->snapshot.convolution.programGeneration,
                    left,
                    right,
                    &convolvedLeft,
                    &convolvedRight)) {
                left = convolvedLeft;
                right = convolvedRight;
            } else {
                atomic_fetch_add_explicit(&kernel->convolutionProgramMisses, 1, memory_order_relaxed);
            }
        }
'''
new_conv = '''        if (context->snapshot.convolution.enabled) {
            bool midSideEQ = context->snapshot.eqDomain == N60EQDomainMidSide;
            float convolutionInputLeft = left;
            float convolutionInputRight = right;
            if (midSideEQ) {
                convolutionInputLeft = 0.5f * (left + right);
                convolutionInputRight = 0.5f * (left - right);
            }
            float convolvedLeft = convolutionInputLeft;
            float convolvedRight = convolutionInputRight;
            if (N60PartitionedConvolverProcessSample(
                    kernel->convolver,
                    context->snapshot.convolution.programSlot,
                    context->snapshot.convolution.programGeneration,
                    convolutionInputLeft,
                    convolutionInputRight,
                    &convolvedLeft,
                    &convolvedRight)) {
                if (midSideEQ) {
                    left = convolvedLeft + convolvedRight;
                    right = convolvedLeft - convolvedRight;
                } else {
                    left = convolvedLeft;
                    right = convolvedRight;
                }
            } else {
                atomic_fetch_add_explicit(&kernel->convolutionProgramMisses, 1, memory_order_relaxed);
            }
        }
'''
kernel = replace_once(kernel, old_conv, new_conv, "linear-phase M/S convolution wrapper")
kernel_path.write_text(kernel)


# ---------------------------------------------------------------------------
# Product model: Linked, independent L/R, or independent Mid/Side static EQ.
# ---------------------------------------------------------------------------
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
stereo = replace_once(stereo, "    case linked\n    case independent\n", "    case linked\n    case independent\n    case midSide\n", "M/S channel mode")
stereo = replace_once(stereo, '        case .linked: return "Linked"\n        case .independent: return "Independent"', '        case .linked: return "Linked"\n        case .independent: return "Independent"\n        case .midSide: return "Mid/Side"', "M/S channel display")
stereo = replace_once(stereo, "    case linked\n    case left\n    case right\n", "    case linked\n    case left\n    case right\n    case mid\n    case side\n", "M/S edit channels")
stereo = replace_once(stereo, '        case .linked: return "Linked"\n        case .left: return "Left"\n        case .right: return "Right"', '        case .linked: return "Linked"\n        case .left: return "Left"\n        case .right: return "Right"\n        case .mid: return "Mid"\n        case .side: return "Side"', "M/S edit display")
stereo = replace_once(
    stereo,
    "    var linkedBands: [EQBand]\n    var leftBands: [EQBand]\n    var rightBands: [EQBand]\n    var independentSeeded: Bool",
    "    var linkedBands: [EQBand]\n    var leftBands: [EQBand]\n    var rightBands: [EQBand]\n    var midBands: [EQBand]\n    var sideBands: [EQBand]\n    var independentSeeded: Bool\n    var midSideSeeded: Bool",
    "M/S band storage",
)
stereo = replace_once(
    stereo,
    "        linkedBands: [EQBand] = [],\n        leftBands: [EQBand] = [],\n        rightBands: [EQBand] = [],\n        independentSeeded: Bool = false",
    "        linkedBands: [EQBand] = [],\n        leftBands: [EQBand] = [],\n        rightBands: [EQBand] = [],\n        midBands: [EQBand] = [],\n        sideBands: [EQBand] = [],\n        independentSeeded: Bool = false,\n        midSideSeeded: Bool = false",
    "M/S initializer parameters",
)
stereo = replace_once(
    stereo,
    "        self.channelMode = channelMode\n        self.editChannel = channelMode == .linked ? .linked : editChannel\n        self.phaseMode = phaseMode",
    "        self.channelMode = channelMode\n        switch channelMode {\n        case .linked: self.editChannel = .linked\n        case .independent: self.editChannel = editChannel == .right ? .right : .left\n        case .midSide: self.editChannel = editChannel == .side ? .side : .mid\n        }\n        self.phaseMode = phaseMode",
    "M/S initializer edit channel",
)
stereo = replace_once(
    stereo,
    "        self.linkedBands = linkedBands\n        self.leftBands = leftBands\n        self.rightBands = rightBands\n        self.independentSeeded = independentSeeded",
    "        self.linkedBands = linkedBands\n        self.leftBands = leftBands\n        self.rightBands = rightBands\n        self.midBands = midBands\n        self.sideBands = sideBands\n        self.independentSeeded = independentSeeded\n        self.midSideSeeded = midSideSeeded",
    "M/S initializer assignment",
)
stereo = replace_once(
    stereo,
    "        case .linked:\n            return linkedBands\n        case .independent:\n            return editChannel == .right ? rightBands : leftBands",
    "        case .linked:\n            return linkedBands\n        case .independent:\n            return editChannel == .right ? rightBands : leftBands\n        case .midSide:\n            return editChannel == .side ? sideBands : midBands",
    "M/S editable bands",
)
stereo = replace_once(
    stereo,
    "        case .linked:\n            return linkedBands.lazy.filter(\\.enabled).count\n        case .independent:\n            return leftBands.lazy.filter(\\.enabled).count + rightBands.lazy.filter(\\.enabled).count",
    "        case .linked:\n            return linkedBands.lazy.filter(\\.enabled).count\n        case .independent:\n            return leftBands.lazy.filter(\\.enabled).count + rightBands.lazy.filter(\\.enabled).count\n        case .midSide:\n            return midBands.lazy.filter(\\.enabled).count + sideBands.lazy.filter(\\.enabled).count",
    "M/S enabled band count",
)
old_set_mode = '''    mutating func setChannelMode(_ mode: EQChannelMode) {
        guard channelMode != mode else { return }
        if mode == .independent && !independentSeeded {
            leftBands = linkedBands
            rightBands = linkedBands
            independentSeeded = true
        }
        channelMode = mode
        editChannel = mode == .linked ? .linked : (editChannel == .right ? .right : .left)
    }
'''
new_set_mode = '''    mutating func setChannelMode(_ mode: EQChannelMode) {
        guard channelMode != mode else { return }
        if mode == .independent && !independentSeeded {
            leftBands = linkedBands
            rightBands = linkedBands
            independentSeeded = true
        }
        if mode == .midSide && !midSideSeeded {
            midBands = linkedBands
            sideBands = linkedBands
            midSideSeeded = true
        }
        channelMode = mode
        switch mode {
        case .linked: editChannel = .linked
        case .independent: editChannel = editChannel == .right ? .right : .left
        case .midSide: editChannel = editChannel == .side ? .side : .mid
        }
    }
'''
stereo = replace_once(stereo, old_set_mode, new_set_mode, "M/S channel mode switching")
old_edit = '''    mutating func setEditChannel(_ channel: EQEditChannel) {
        guard channelMode == .independent else {
            editChannel = .linked
            return
        }
        editChannel = channel == .right ? .right : .left
    }
'''
new_edit = '''    mutating func setEditChannel(_ channel: EQEditChannel) {
        switch channelMode {
        case .linked:
            editChannel = .linked
        case .independent:
            editChannel = channel == .right ? .right : .left
        case .midSide:
            editChannel = channel == .side ? .side : .mid
        }
    }
'''
stereo = replace_once(stereo, old_edit, new_edit, "M/S edit switching")
old_replace = '''        case .linked:
            linkedBands = bands
        case .independent:
            if editChannel == .right {
                rightBands = bands
            } else {
                leftBands = bands
            }
'''
new_replace = '''        case .linked:
            linkedBands = bands
        case .independent:
            if editChannel == .right {
                rightBands = bands
            } else {
                leftBands = bands
            }
        case .midSide:
            if editChannel == .side {
                sideBands = bands
            } else {
                midBands = bands
            }
'''
stereo = replace_once(stereo, old_replace, new_replace, "M/S editable replacement")
stereo = replace_once(
    stereo,
    "            case .linked: staticBoost = channelBoost(linkedBands)\n            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))",
    "            case .linked: staticBoost = channelBoost(linkedBands)\n            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))\n            case .midSide: staticBoost = max(channelBoost(midBands), channelBoost(sideBands))",
    "M/S automatic headroom",
)
stereo = replace_once(
    stereo,
    "        guard phaseMode == .minimumPhase,\n              !bypassed,\n              channelMode == .linked else { return }",
    "        guard phaseMode == .minimumPhase,\n              !bypassed else { return }",
    "shared Dynamic EQ guard",
)
stereo = replace_once(
    stereo,
    "        graph.eqBypassed = bypassed\n        N60DSPGraphSnapshotClearEQ(&graph)",
    "        graph.eqBypassed = bypassed\n        graph.eqDomain = channelMode == .midSide ? N60EQDomainMidSide : N60EQDomainLeftRight\n        N60DSPGraphSnapshotClearEQ(&graph)",
    "graph M/S domain selection",
)
old_min_switch = '''            case .independent:
                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
'''
new_min_switch = '''            case .independent:
                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
            case .midSide:
                for band in try validatedEnabledBands(midBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(sideBands, sampleRate: sampleRate) {
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
'''
stereo = replace_once(stereo, old_min_switch, new_min_switch, "minimum-phase M/S bands")
stereo = replace_once(
    stereo,
    "        case .linked:\n            source = linkedBands\n        case .independent:\n            source = channel == .right ? rightBands : leftBands",
    "        case .linked:\n            source = linkedBands\n        case .independent:\n            source = channel == .right ? rightBands : leftBands\n        case .midSide:\n            source = channel == .side ? sideBands : midBands",
    "linear-phase M/S bands",
)
stereo_path.write_text(stereo)


# ---------------------------------------------------------------------------
# Linear-phase preparation maps convolver lanes to Mid/Side when requested.
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(
    engine,
    "        for bands in [configuration.linkedBands, configuration.leftBands, configuration.rightBands] {",
    "        for bands in [configuration.linkedBands, configuration.leftBands, configuration.rightBands, configuration.midBands, configuration.sideBands] {",
    "M/S storage validation",
)
old_linear_prepare = '''        let leftDesign = try designLinearPhaseTaps(
            configuration,
            channel: configuration.channelMode == .linked ? .linked : .left,
            sampleRate: sampleRate,
            tapCount: tapCount
        )

        let rightTaps: [Float]?
        if configuration.channelMode == .independent {
            let rightDesign = try designLinearPhaseTaps(
                configuration,
                channel: .right,
                sampleRate: sampleRate,
                tapCount: tapCount
            )
            guard rightDesign.info.groupDelayFrames == leftDesign.info.groupDelayFrames else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            rightTaps = rightDesign.taps
        } else {
            rightTaps = nil
        }
'''
new_linear_prepare = '''        let primaryChannel: EQEditChannel
        let secondaryChannel: EQEditChannel?
        switch configuration.channelMode {
        case .linked:
            primaryChannel = .linked
            secondaryChannel = nil
        case .independent:
            primaryChannel = .left
            secondaryChannel = .right
        case .midSide:
            primaryChannel = .mid
            secondaryChannel = .side
        }

        let leftDesign = try designLinearPhaseTaps(
            configuration,
            channel: primaryChannel,
            sampleRate: sampleRate,
            tapCount: tapCount
        )

        let rightTaps: [Float]?
        if let secondaryChannel {
            let rightDesign = try designLinearPhaseTaps(
                configuration,
                channel: secondaryChannel,
                sampleRate: sampleRate,
                tapCount: tapCount
            )
            guard rightDesign.info.groupDelayFrames == leftDesign.info.groupDelayFrames else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            rightTaps = rightDesign.taps
        } else {
            rightTaps = nil
        }
'''
engine = replace_once(engine, old_linear_prepare, new_linear_prepare, "linear-phase M/S preparation")
engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Validation UI exposes Mid/Side selection. Dynamic EQ remains shared/linked.
# ---------------------------------------------------------------------------
content_path = Path("NotchSixty/ContentView.swift")
content = content_path.read_text()
old_picker = '''                if engine.stereoEQConfiguration.channelMode == .independent {
                    Picker("Edit", selection: eqEditChannelBinding) {
                        Text("Left").tag(EQEditChannel.left)
                        Text("Right").tag(EQEditChannel.right)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
'''
new_picker = '''                if engine.stereoEQConfiguration.channelMode == .independent {
                    Picker("Edit", selection: eqEditChannelBinding) {
                        Text("Left").tag(EQEditChannel.left)
                        Text("Right").tag(EQEditChannel.right)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                } else if engine.stereoEQConfiguration.channelMode == .midSide {
                    Picker("Edit", selection: eqEditChannelBinding) {
                        Text("Mid").tag(EQEditChannel.mid)
                        Text("Side").tag(EQEditChannel.side)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
'''
content = replace_once(content, old_picker, new_picker, "M/S UI edit picker")
content = replace_once(
    content,
    '                    Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic is available for linked, minimum-phase Peak bands; the standalone C detector/gain engine remains an internal implementation detail.")',
    '                    Text("Commercial capacity: up to \\(EQConfiguration.maximumBandCount) EQ bands. Dynamic EQ remains one shared minimum-phase linked layer while Stereo or Mid/Side static EQ is edited independently; the standalone C detector/gain engine remains an internal implementation detail.")',
    "Dynamic EQ M/S validation copy",
)
content_path.write_text(content)


# ---------------------------------------------------------------------------
# XCTest coverage: identity, model editing, domain publication, and M/S lanes.
# ---------------------------------------------------------------------------
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
tests_to_add = r'''
    func testMidSideModeSeedsIndependentMidAndSideStates() {
        let seed = EQBand(type: .peaking, frequencyHz: 1_200, gainDB: 2.5, q: 1.1)
        var configuration = StereoEQConfiguration(linkedBands: [seed])
        configuration.setChannelMode(.midSide)

        XCTAssertEqual(configuration.channelMode, .midSide)
        XCTAssertEqual(configuration.editChannel, .mid)
        XCTAssertEqual(configuration.midBands, [seed])
        XCTAssertEqual(configuration.sideBands, [seed])

        configuration.setEditChannel(.side)
        var side = configuration.editableBands
        side[0].gainDB = -3.0
        configuration.replaceEditableBands(side)
        XCTAssertEqual(configuration.midBands[0].gainDB, 2.5, accuracy: 0.000_001)
        XCTAssertEqual(configuration.sideBands[0].gainDB, -3.0, accuracy: 0.000_001)
    }

    func testMidSideGraphPublishesDomainAndIndependentLaneMasks() throws {
        let mid = EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1.0)
        let side = EQBand(type: .peaking, frequencyHz: 2_000, gainDB: -4, q: 1.0)
        let configuration = StereoEQConfiguration(
            channelMode: .midSide,
            editChannel: .mid,
            phaseMode: .minimumPhase,
            midBands: [mid],
            sideBands: [side],
            midSideSeeded: true
        )
        let graph = try configuration.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertEqual(graph.eqDomain, N60EQDomainMidSide)
        XCTAssertEqual(graph.eqBandCount, 2)
        XCTAssertEqual(graph.eqBandChannelMasks.0, UInt8(N60_EQ_CHANNEL_LEFT))
        XCTAssertEqual(graph.eqBandChannelMasks.1, UInt8(N60_EQ_CHANNEL_RIGHT))
    }

    func testMidSideEncodeDecodeIsTransparentAcrossSupportedRates() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        for rate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            var graph = N60DSPGraphSnapshotMakeUnity(rate)
            graph.eqDomain = N60EQDomainMidSide
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
            for pair: (Float, Float) in [(0.25, -0.5), (0.75, 0.75), (-0.6, 0.6)] {
                var left: Float = 0
                var right: Float = 0
                N60RenderKernelProcessStereoFrame(kernel, pair.0, pair.1, &left, &right)
                XCTAssertEqual(left, pair.0, accuracy: 0.000_001)
                XCTAssertEqual(right, pair.1, accuracy: 0.000_001)
            }
        }
    }

    func testMidOnlyMinimumPhaseEQChangesCenterButNotPureSide() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        let rate = 48_000.0
        var graph = N60DSPGraphSnapshotMakeUnity(rate)
        graph.eqDomain = N60EQDomainMidSide
        XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
            &graph, 0, UInt8(N60_EQ_CHANNEL_LEFT), N60BiquadFilterTypePeaking,
            1_000, 6, 1.0, true
        ))
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))

        func measuredGain(pureMid: Bool) -> Double {
            var inputSquares = 0.0
            var outputSquares = 0.0
            let total = 16_384
            let warmup = 4_096
            for frame in 0..<total {
                let x = Float(sin(2.0 * Double.pi * 1_000.0 * Double(frame) / rate) * 0.1)
                let inputLeft = x
                let inputRight = pureMid ? x : -x
                var outputLeft: Float = 0
                var outputRight: Float = 0
                N60RenderKernelProcessStereoFrame(kernel, inputLeft, inputRight, &outputLeft, &outputRight)
                if frame >= warmup {
                    inputSquares += Double(inputLeft * inputLeft)
                    outputSquares += Double(outputLeft * outputLeft)
                }
            }
            return 10.0 * log10(outputSquares / inputSquares)
        }

        let midGain = measuredGain(pureMid: true)
        N60RenderKernelReset(kernel)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        let sideGain = measuredGain(pureMid: false)
        XCTAssertEqual(midGain, 6.0, accuracy: 0.25)
        XCTAssertEqual(sideGain, 0.0, accuracy: 0.05)
    }

    func testMidSideLinearPhaseProjectsIndependentMidAndSideProgramsThrough384k() throws {
        let mid = EQBand(type: .lowShelf, frequencyHz: 180, gainDB: 3, q: 0.707)
        let side = EQBand(type: .highShelf, frequencyHz: 6_000, gainDB: -2, q: 0.707)
        let configuration = StereoEQConfiguration(
            channelMode: .midSide,
            editChannel: .mid,
            phaseMode: .linearPhase,
            midBands: [mid],
            sideBands: [side],
            midSideSeeded: true
        )
        for rate in [48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            let midBands = try configuration.linearPhaseBands(for: .mid, sampleRate: rate)
            let sideBands = try configuration.linearPhaseBands(for: .side, sampleRate: rate)
            XCTAssertFalse(midBands.isEmpty)
            XCTAssertFalse(sideBands.isEmpty)
            let graph = try configuration.makeGraphSnapshot(
                sampleRate: rate,
                gainConfiguration: DSPGainConfiguration(),
                bassManagementConfiguration: BassManagementConfiguration(),
                playbackConfiguration: PlaybackControlConfiguration()
            )
            XCTAssertEqual(graph.eqDomain, N60EQDomainMidSide)
        }
    }
'''
if tests_to_add not in tests:
    marker = "\n    func testBootstrapTestBundleRuns() {"
    if marker not in tests:
        raise SystemExit("Expected test insertion point was not found")
    tests = tests.replace(marker, tests_to_add + marker, 1)
tests_path.write_text(tests)

print("PR34 Phase C Mid/Side EQ integration applied.")
