from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"Expected {label} insertion point was not found")
    return text.replace(old, new, 1)


# ---------------------------------------------------------------------------
# Realtime graph: explicit M/S contract around the EQ + Linear Phase region.
# ---------------------------------------------------------------------------
header_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.h")
header = header_path.read_text()
helpers = '''static inline void N60MidSideEncode(
    float left,
    float right,
    float * _Nonnull mid,
    float * _Nonnull side
) {
    *mid = 0.5f * (left + right);
    *side = 0.5f * (left - right);
}

static inline void N60MidSideDecode(
    float mid,
    float side,
    float * _Nonnull left,
    float * _Nonnull right
) {
    *left = mid + side;
    *right = mid - side;
}

'''
if helpers not in header:
    marker = "typedef enum {\n    N60AuditionModeProcessed = 0,"
    if marker not in header:
        raise SystemExit("Expected Mid/Side helper insertion point was not found")
    header = header.replace(marker, helpers + marker, 1)
header = replace_once(
    header,
    "    bool eqBypassed;\n    uint32_t eqBandCount;",
    "    bool eqBypassed;\n    bool eqMidSideMode;\n    uint32_t eqBandCount;",
    "graph Mid/Side state",
)
header = replace_once(
    header,
    "    bool eqBypassed;\n    uint32_t eqBandCount;\n    uint32_t eqLeftBandCount;",
    "    bool eqBypassed;\n    bool eqMidSideMode;\n    uint32_t eqBandCount;\n    uint32_t eqLeftBandCount;",
    "diagnostics Mid/Side state",
)
header_path.write_text(header)

render_path = Path("NotchSixty/Audio/Realtime/N60RenderKernel.c")
render = render_path.read_text()
old_eq_region = '''        if (!context->snapshot.eqBypassed) {
            for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) {
                N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
                if (!runtime->currentEnabled && runtime->transitionFramesRemaining == 0) continue;
                left = process_eq_band(runtime, left, N60_EQ_CHANNEL_LEFT);
                right = process_eq_band(runtime, right, N60_EQ_CHANNEL_RIGHT);
            }
            advance_eq_transitions(kernel);
            // Dynamic EQ is a capability of the main parametric-EQ stage. Its
            // detector/gain engine remains independently implemented, but it is
            // evaluated here so enabling Dynamic does not move a band into the
            // later dynamics section of the graph.
            N60DynamicsProcessDynamicEQStereoFrame(
                &kernel->dynamicsRuntime,
                context->snapshot.dynamics,
                &left,
                &right
            );
        }

        if (context->snapshot.convolution.enabled) {
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
new_eq_region = '''        bool midSideEQ = !context->snapshot.eqBypassed && context->snapshot.eqMidSideMode;
        if (midSideEQ) {
            float mid = 0.0f;
            float side = 0.0f;
            N60MidSideEncode(left, right, &mid, &side);
            left = mid;
            right = side;
        }

        if (!context->snapshot.eqBypassed) {
            for (uint32_t index = 0; index < N60_MAX_EQ_RENDER_SLOTS; ++index) {
                N60EQBandRuntime *runtime = &kernel->eqRuntime[index];
                if (!runtime->currentEnabled && runtime->transitionFramesRemaining == 0) continue;
                left = process_eq_band(runtime, left, N60_EQ_CHANNEL_LEFT);
                right = process_eq_band(runtime, right, N60_EQ_CHANNEL_RIGHT);
            }
            advance_eq_transitions(kernel);
        }

        if (context->snapshot.convolution.enabled) {
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

        if (midSideEQ) {
            float physicalLeft = 0.0f;
            float physicalRight = 0.0f;
            N60MidSideDecode(left, right, &physicalLeft, &physicalRight);
            left = physicalLeft;
            right = physicalRight;
        }

        if (!context->snapshot.eqBypassed) {
            // Dynamic EQ remains a linked physical-stereo stage. Mid/Side does
            // not create independent M/S dynamic detectors.
            N60DynamicsProcessDynamicEQStereoFrame(
                &kernel->dynamicsRuntime,
                context->snapshot.dynamics,
                &left,
                &right
            );
        }
'''
render = replace_once(render, old_eq_region, new_eq_region, "realtime Mid/Side EQ region")
render = replace_once(
    render,
    "        diagnostics.eqBypassed = context.snapshot.eqBypassed;\n        diagnostics.eqBandCount = context.snapshot.eqBandCount;",
    "        diagnostics.eqBypassed = context.snapshot.eqBypassed;\n        diagnostics.eqMidSideMode = context.snapshot.eqMidSideMode;\n        diagnostics.eqBandCount = context.snapshot.eqBandCount;",
    "Mid/Side diagnostics",
)
render_path.write_text(render)


# ---------------------------------------------------------------------------
# Product model: dedicated Mid and Side states, independent from L/R editing.
# ---------------------------------------------------------------------------
stereo_path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
stereo = stereo_path.read_text()
stereo = replace_once(stereo, "    case linked\n    case independent", "    case linked\n    case independent\n    case midSide", "Mid/Side channel mode")
stereo = replace_once(
    stereo,
    '        case .linked: return "Linked"\n        case .independent: return "Independent"',
    '        case .linked: return "Linked"\n        case .independent: return "Independent"\n        case .midSide: return "Mid/Side"',
    "Mid/Side channel mode display",
)
stereo = replace_once(stereo, "    case linked\n    case left\n    case right", "    case linked\n    case left\n    case right\n    case mid\n    case side", "Mid/Side edit channels")
stereo = replace_once(
    stereo,
    '        case .linked: return "Linked"\n        case .left: return "Left"\n        case .right: return "Right"',
    '        case .linked: return "Linked"\n        case .left: return "Left"\n        case .right: return "Right"\n        case .mid: return "Mid"\n        case .side: return "Side"',
    "Mid/Side edit display",
)
stereo = replace_once(
    stereo,
    "    var leftBands: [EQBand]\n    var rightBands: [EQBand]\n    var independentSeeded: Bool",
    "    var leftBands: [EQBand]\n    var rightBands: [EQBand]\n    var midBands: [EQBand]\n    var sideBands: [EQBand]\n    var independentSeeded: Bool\n    var midSideSeeded: Bool",
    "Mid/Side state storage",
)
stereo = replace_once(
    stereo,
    "        leftBands: [EQBand] = [],\n        rightBands: [EQBand] = [],\n        independentSeeded: Bool = false",
    "        leftBands: [EQBand] = [],\n        rightBands: [EQBand] = [],\n        midBands: [EQBand] = [],\n        sideBands: [EQBand] = [],\n        independentSeeded: Bool = false,\n        midSideSeeded: Bool = false",
    "Mid/Side initializer parameters",
)
stereo = replace_once(
    stereo,
    "        self.channelMode = channelMode\n        self.editChannel = channelMode == .linked ? .linked : editChannel\n        self.phaseMode = phaseMode",
    '''        self.channelMode = channelMode
        switch channelMode {
        case .linked:
            self.editChannel = .linked
        case .independent:
            self.editChannel = editChannel == .right ? .right : .left
        case .midSide:
            self.editChannel = editChannel == .side ? .side : .mid
        }
        self.phaseMode = phaseMode''',
    "Mid/Side initializer edit selection",
)
stereo = replace_once(
    stereo,
    "        self.leftBands = leftBands\n        self.rightBands = rightBands\n        self.independentSeeded = independentSeeded",
    "        self.leftBands = leftBands\n        self.rightBands = rightBands\n        self.midBands = midBands\n        self.sideBands = sideBands\n        self.independentSeeded = independentSeeded\n        self.midSideSeeded = midSideSeeded",
    "Mid/Side initializer state assignment",
)
stereo = replace_once(
    stereo,
    '''        case .independent:
            return editChannel == .right ? rightBands : leftBands
''',
    '''        case .independent:
            return editChannel == .right ? rightBands : leftBands
        case .midSide:
            return editChannel == .side ? sideBands : midBands
''',
    "Mid/Side editable bands",
)
stereo = replace_once(
    stereo,
    '''        case .independent:
            return leftBands.lazy.filter(\.enabled).count + rightBands.lazy.filter(\.enabled).count
''',
    '''        case .independent:
            return leftBands.lazy.filter(\.enabled).count + rightBands.lazy.filter(\.enabled).count
        case .midSide:
            return midBands.lazy.filter(\.enabled).count + sideBands.lazy.filter(\.enabled).count
''',
    "Mid/Side enabled-band count",
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
stereo = replace_once(stereo, old_set_mode, new_set_mode, "Mid/Side channel-mode transition")
old_set_edit = '''    mutating func setEditChannel(_ channel: EQEditChannel) {
        guard channelMode == .independent else {
            editChannel = .linked
            return
        }
        editChannel = channel == .right ? .right : .left
    }
'''
new_set_edit = '''    mutating func setEditChannel(_ channel: EQEditChannel) {
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
stereo = replace_once(stereo, old_set_edit, new_set_edit, "Mid/Side edit selection")
stereo = replace_once(
    stereo,
    '''        case .independent:
            if editChannel == .right {
                rightBands = bands
            } else {
                leftBands = bands
            }
''',
    '''        case .independent:
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
''',
    "Mid/Side editable-band replacement",
)
stereo = replace_once(
    stereo,
    '''            case .linked: staticBoost = channelBoost(linkedBands)
            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))
''',
    '''            case .linked: staticBoost = channelBoost(linkedBands)
            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))
            case .midSide: staticBoost = max(channelBoost(midBands), channelBoost(sideBands))
''',
    "Mid/Side automatic headroom",
)
stereo = replace_once(
    stereo,
    "        graph.eqBypassed = bypassed\n        N60DSPGraphSnapshotClearEQ(&graph)",
    "        graph.eqBypassed = bypassed\n        graph.eqMidSideMode = channelMode == .midSide\n        N60DSPGraphSnapshotClearEQ(&graph)",
    "Mid/Side graph publication",
)
stereo = replace_once(
    stereo,
    '''            case .independent:
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
''',
    '''            case .independent:
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
''',
    "Mid/Side minimum-phase compilation",
)
stereo = replace_once(
    stereo,
    '''        case .independent:
            source = channel == .right ? rightBands : leftBands
''',
    '''        case .independent:
            source = channel == .right ? rightBands : leftBands
        case .midSide:
            source = channel == .side ? sideBands : midBands
''',
    "Mid/Side Linear Phase projection",
)
stereo_path.write_text(stereo)


# ---------------------------------------------------------------------------
# Engine validation and Linear Phase program preparation.
# ---------------------------------------------------------------------------
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
engine = replace_once(
    engine,
    "        for bands in [configuration.linkedBands, configuration.leftBands, configuration.rightBands] {",
    "        for bands in [configuration.linkedBands, configuration.leftBands, configuration.rightBands, configuration.midBands, configuration.sideBands] {",
    "Mid/Side storage validation",
)
old_prepare = '''        let leftDesign = try designLinearPhaseTaps(
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
new_prepare = '''        let primaryChannel: EQEditChannel
        switch configuration.channelMode {
        case .linked: primaryChannel = .linked
        case .independent: primaryChannel = .left
        case .midSide: primaryChannel = .mid
        }
        let leftDesign = try designLinearPhaseTaps(
            configuration,
            channel: primaryChannel,
            sampleRate: sampleRate,
            tapCount: tapCount
        )

        let rightTaps: [Float]?
        if configuration.channelMode != .linked {
            let secondaryChannel: EQEditChannel = configuration.channelMode == .midSide ? .side : .right
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
engine = replace_once(engine, old_prepare, new_prepare, "Mid/Side Linear Phase preparation")
engine_path.write_text(engine)


# ---------------------------------------------------------------------------
# Validation UI: expose M/S channel editing without leaking L/R labels.
# ---------------------------------------------------------------------------
view_path = Path("NotchSixty/ContentView.swift")
view = view_path.read_text()
view = replace_once(view, ".frame(width: 180)\n                if engine.stereoEQConfiguration.channelMode == .independent {", ".frame(width: 260)\n                if engine.stereoEQConfiguration.channelMode == .independent {", "three-mode channel picker width")
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
view = replace_once(view, old_picker, new_picker, "Mid/Side edit picker")
view_path.write_text(view)


# ---------------------------------------------------------------------------
# Regression tests: product state + realtime identity/routing/audition contracts.
# ---------------------------------------------------------------------------
tests_path = Path("NotchSixtyTests/NotchSixtyTests.swift")
tests = tests_path.read_text()
tests_to_add = r'''    func testMidSideModelPublishesDedicatedLanesInMinimumAndLinearPhase() throws {
        let midBand = EQBand(type: .peaking, frequencyHz: 700, gainDB: 3, q: 1.0)
        let sideBand = EQBand(type: .highShelf, frequencyHz: 4_000, gainDB: -2, q: 0.707)
        let configuration = StereoEQConfiguration(
            channelMode: .midSide,
            editChannel: .mid,
            phaseMode: .minimumPhase,
            midBands: [midBand],
            sideBands: [sideBand],
            midSideSeeded: true
        )
        let graph = try configuration.makeGraphSnapshot(
            sampleRate: 96_000,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(),
            playbackConfiguration: PlaybackControlConfiguration()
        )
        XCTAssertTrue(graph.eqMidSideMode)
        XCTAssertEqual(graph.eqBandCount, 2)
        XCTAssertEqual(graph.eqBandChannelMasks.0, UInt8(N60_EQ_CHANNEL_LEFT))
        XCTAssertEqual(graph.eqBandChannelMasks.1, UInt8(N60_EQ_CHANNEL_RIGHT))

        var linear = configuration
        linear.phaseMode = .linearPhase
        XCTAssertEqual(try linear.linearPhaseBands(for: .mid, sampleRate: 96_000).count, 1)
        XCTAssertEqual(try linear.linearPhaseBands(for: .side, sampleRate: 96_000).count, 1)
    }

    func testMidSideRealtimeIdentityAndAuditionContracts() throws {
        guard let kernel = N60RenderKernelCreate() else {
            XCTFail("Unable to allocate render kernel")
            return
        }
        defer { N60RenderKernelDestroy(kernel) }

        let pairs: [(Float, Float)] = [(0.25, -0.5), (0.4, 0.4), (0.4, -0.4)]
        var graph = N60DSPGraphSnapshotMakeUnity(96_000)
        graph.eqMidSideMode = true
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        for pair in pairs {
            var left: Float = 0
            var right: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, pair.0, pair.1, &left, &right)
            XCTAssertEqual(left, pair.0, accuracy: 0.000_001)
            XCTAssertEqual(right, pair.1, accuracy: 0.000_001)
        }

        graph.auditionMode = N60AuditionModeReference
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        var left: Float = 0
        var right: Float = 0
        N60RenderKernelProcessStereoFrame(kernel, 0.3, -0.2, &left, &right)
        XCTAssertEqual(left, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(right, -0.2, accuracy: 0.000_001)

        graph.auditionMode = N60AuditionModeDelta
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
        N60RenderKernelProcessStereoFrame(kernel, 0.3, -0.2, &left, &right)
        XCTAssertEqual(left, 0.0, accuracy: 0.000_001)
        XCTAssertEqual(right, 0.0, accuracy: 0.000_001)
    }

    func testMidSideMinimumPhaseRoutesMidAndSideIndependently() throws {
        func settledOutput(channelMask: UInt8, inputLeft: Float, inputRight: Float) throws -> (Float, Float) {
            guard let kernel = N60RenderKernelCreate() else {
                XCTFail("Unable to allocate render kernel")
                return (0, 0)
            }
            defer { N60RenderKernelDestroy(kernel) }
            var graph = N60DSPGraphSnapshotMakeUnity(48_000)
            graph.eqMidSideMode = true
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &graph, 0, channelMask, N60BiquadFilterTypeLowShelf,
                500, 6, 0.707, true
            ))
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, graph))
            var left: Float = 0
            var right: Float = 0
            for _ in 0..<4_096 {
                N60RenderKernelProcessStereoFrame(kernel, inputLeft, inputRight, &left, &right)
            }
            return (left, right)
        }

        let midOnly = try settledOutput(
            channelMask: UInt8(N60_EQ_CHANNEL_LEFT), inputLeft: 0.1, inputRight: 0.1
        )
        XCTAssertEqual(midOnly.0, midOnly.1, accuracy: 0.000_01)
        XCTAssertGreaterThan(abs(midOnly.0), 0.15)

        let midFilterOnPureSide = try settledOutput(
            channelMask: UInt8(N60_EQ_CHANNEL_LEFT), inputLeft: 0.1, inputRight: -0.1
        )
        XCTAssertEqual(midFilterOnPureSide.0, 0.1, accuracy: 0.000_01)
        XCTAssertEqual(midFilterOnPureSide.1, -0.1, accuracy: 0.000_01)

        let sideOnly = try settledOutput(
            channelMask: UInt8(N60_EQ_CHANNEL_RIGHT), inputLeft: 0.1, inputRight: -0.1
        )
        XCTAssertEqual(sideOnly.0, -sideOnly.1, accuracy: 0.000_01)
        XCTAssertGreaterThan(abs(sideOnly.0), 0.15)
    }

'''
if "testMidSideModelPublishesDedicatedLanesInMinimumAndLinearPhase" not in tests:
    marker = "    func testAllPassMaintainsUnityMagnitudeAcrossSupportedRates() {\n"
    if marker not in tests:
        raise SystemExit("Expected Mid/Side test insertion point was not found")
    tests = tests.replace(marker, tests_to_add + marker, 1)
tests_path.write_text(tests)

print("PR34 Phase C Mid/Side integration applied.")
