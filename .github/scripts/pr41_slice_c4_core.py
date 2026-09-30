from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# 1. Crossover DSP: a dedicated post-shared-DSP physical speaker-bus splitter.
cross_path = Path("NotchSixty/Audio/Realtime/N60Crossover.h")
cross = cross_path.read_text()
insert_anchor = '''\n#ifdef __cplusplus\n}\n#endif\n\n#endif\n'''
splitter = r'''

typedef enum {
    N60SpeakerCrossoverModeMainsSub = 0,
    N60SpeakerCrossoverModeBiAmp = 1,
    N60SpeakerCrossoverModeTriAmp = 2,
} N60SpeakerCrossoverMode;

typedef struct {
    bool enabled;
    N60SpeakerCrossoverMode mode;
    double lowerFrequencyHz;
    N60CrossoverTopology lowerTopology;
    double upperFrequencyHz;
    N60CrossoverTopology upperTopology;
    float subGainLinear;
    bool subPolarityInverted;
    bool subPhaseAlignmentEnabled;
    double subPhaseAlignmentFrequencyHz;
    double subPhaseAlignmentQ;
    N60BiquadCoefficients subPhaseAlignmentAllPass;
    uint32_t lowerSectionCount;
    uint32_t upperSectionCount;
    N60BiquadCoefficients lowerLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients lowerHighPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients upperLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients upperHighPass[N60_MAX_CROSSOVER_SECTIONS];
} N60SpeakerBusSplitterSnapshot;

static inline N60SpeakerBusSplitterSnapshot N60SpeakerBusSplitterSnapshotMakeBypassed(void) {
    N60SpeakerBusSplitterSnapshot snapshot = {0};
    snapshot.enabled = false;
    snapshot.mode = N60SpeakerCrossoverModeMainsSub;
    snapshot.lowerFrequencyHz = 80.0;
    snapshot.lowerTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.upperFrequencyHz = 2_000.0;
    snapshot.upperTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.subGainLinear = 1.0f;
    snapshot.subPhaseAlignmentFrequencyHz = 80.0;
    snapshot.subPhaseAlignmentQ = 0.7;
    snapshot.subPhaseAlignmentAllPass = N60BiquadCoefficientsMakeIdentity();
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.lowerLowPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.lowerHighPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.upperLowPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.upperHighPass[index] = N60BiquadCoefficientsMakeIdentity();
    }
    return snapshot;
}

// Control-plane only. Physical speaker crossover filters are intentionally
// designed after the shared stereo DSP graph. The realtime bridge consumes only
// this immutable coefficient snapshot and fixed preallocated filter state.
static inline bool N60SpeakerBusSplitterSnapshotMake(
    double sampleRate,
    N60SpeakerCrossoverMode mode,
    double lowerFrequencyHz,
    N60CrossoverTopology lowerTopology,
    double upperFrequencyHz,
    N60CrossoverTopology upperTopology,
    float subGainLinear,
    bool subPolarityInverted,
    bool subPhaseAlignmentEnabled,
    double subPhaseAlignmentFrequencyHz,
    double subPhaseAlignmentQ,
    N60SpeakerBusSplitterSnapshot * _Nonnull snapshot
) {
    if (snapshot == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(lowerFrequencyHz) || lowerFrequencyHz <= 0.0
        || lowerFrequencyHz >= sampleRate * 0.5
        || !isfinite(subGainLinear) || subGainLinear < 0.0f
        || mode < N60SpeakerCrossoverModeMainsSub
        || mode > N60SpeakerCrossoverModeTriAmp) {
        return false;
    }
    if (mode == N60SpeakerCrossoverModeTriAmp
        && (!isfinite(upperFrequencyHz)
            || upperFrequencyHz <= lowerFrequencyHz
            || upperFrequencyHz >= sampleRate * 0.5)) {
        return false;
    }
    if (mode == N60SpeakerCrossoverModeMainsSub
        && (!isfinite(subPhaseAlignmentFrequencyHz)
            || subPhaseAlignmentFrequencyHz <= 0.0
            || subPhaseAlignmentFrequencyHz >= sampleRate * 0.5
            || !isfinite(subPhaseAlignmentQ)
            || subPhaseAlignmentQ <= 0.0)) {
        return false;
    }

    double lowerQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
    uint32_t lowerCount = 0;
    if (!N60CrossoverTopologyQValues(lowerTopology, lowerQ, &lowerCount)) return false;

    N60SpeakerBusSplitterSnapshot designed = N60SpeakerBusSplitterSnapshotMakeBypassed();
    designed.enabled = true;
    designed.mode = mode;
    designed.lowerFrequencyHz = lowerFrequencyHz;
    designed.lowerTopology = lowerTopology;
    designed.upperFrequencyHz = upperFrequencyHz;
    designed.upperTopology = upperTopology;
    designed.subGainLinear = subGainLinear;
    designed.subPolarityInverted = subPolarityInverted;
    designed.subPhaseAlignmentEnabled = mode == N60SpeakerCrossoverModeMainsSub
        && subPhaseAlignmentEnabled;
    designed.subPhaseAlignmentFrequencyHz = subPhaseAlignmentFrequencyHz;
    designed.subPhaseAlignmentQ = subPhaseAlignmentQ;
    designed.lowerSectionCount = lowerCount;

    for (uint32_t index = 0; index < lowerCount; ++index) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeLowPass, sampleRate, lowerFrequencyHz,
                0.0, lowerQ[index], &designed.lowerLowPass[index])
            || !N60BiquadDesign(
                N60BiquadFilterTypeHighPass, sampleRate, lowerFrequencyHz,
                0.0, lowerQ[index], &designed.lowerHighPass[index])) {
            return false;
        }
    }

    if (mode == N60SpeakerCrossoverModeTriAmp) {
        double upperQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
        uint32_t upperCount = 0;
        if (!N60CrossoverTopologyQValues(upperTopology, upperQ, &upperCount)) return false;
        designed.upperSectionCount = upperCount;
        for (uint32_t index = 0; index < upperCount; ++index) {
            if (!N60BiquadDesign(
                    N60BiquadFilterTypeLowPass, sampleRate, upperFrequencyHz,
                    0.0, upperQ[index], &designed.upperLowPass[index])
                || !N60BiquadDesign(
                    N60BiquadFilterTypeHighPass, sampleRate, upperFrequencyHz,
                    0.0, upperQ[index], &designed.upperHighPass[index])) {
                return false;
            }
        }
    }

    if (designed.subPhaseAlignmentEnabled) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeAllPass,
                sampleRate,
                subPhaseAlignmentFrequencyHz,
                0.0,
                subPhaseAlignmentQ,
                &designed.subPhaseAlignmentAllPass)) {
            return false;
        }
    }

    *snapshot = designed;
    return true;
}
'''
if "N60SpeakerBusSplitterSnapshotMake(" in cross:
    raise SystemExit("C4 splitter already present")
cross = replace_once(cross, insert_anchor, splitter + insert_anchor, "C4 splitter header insertion")
cross_path.write_text(cross)


# 2. Realtime bridge: configure fixed splitter state while stopped, derive all
# logical speaker buses after the final shared stereo DSP result, then map them.
header_path = Path("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h")
header = header_path.read_text()
header = replace_once(
    header,
    '''bool N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(\n    N60RealtimeAudioBridge * _Nonnull bridge,\n    N60SameDeviceOutputMap map\n);\n''',
    '''bool N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(\n    N60RealtimeAudioBridge * _Nonnull bridge,\n    N60SameDeviceOutputMap map\n);\nbool N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(\n    N60RealtimeAudioBridge * _Nonnull bridge,\n    N60SpeakerBusSplitterSnapshot snapshot\n);\n''',
    "C4 bridge splitter declaration",
)
header_path.write_text(header)

impl_path = Path("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c")
impl = impl_path.read_text()
struct_anchor = '''typedef struct {\n    uint32_t totalFrames;\n    uint32_t remainingFrames;\n    uint64_t appliedCommandSequence;\n} N60StartupFadeRuntime;\n'''
runtime_struct = r'''typedef struct {
    N60SpeakerBusSplitterSnapshot snapshot;
    N60BiquadState lowerLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerLowMono[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowerHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState upperHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState subPhaseAlignment;
} N60SpeakerBusSplitterRuntime;

'''
impl = replace_once(impl, struct_anchor, struct_anchor + "\n" + runtime_struct, "C4 bridge splitter runtime")
impl = replace_once(
    impl,
    '''    N60RenderKernel *renderKernel;\n    N60SameDeviceOutputMap sameDeviceOutputMap;\n''',
    '''    N60RenderKernel *renderKernel;\n    N60SameDeviceOutputMap sameDeviceOutputMap;\n    N60SpeakerBusSplitterRuntime speakerBusSplitter;\n''',
    "C4 bridge splitter storage",
)
# Add helpers before bridge creation.
create_anchor = '''N60RealtimeAudioBridge *N60RealtimeAudioBridgeCreate(uint32_t capacityFrames) {\n'''
helpers = r'''static float process_splitter_sections(
    const N60BiquadCoefficients *coefficients,
    N60BiquadState *states,
    uint32_t count,
    float input
) {
    float output = input;
    for (uint32_t index = 0; index < count; ++index) {
        output = N60BiquadProcessSample(coefficients[index], &states[index], output);
    }
    return output;
}

static void process_speaker_bus_splitter(
    N60SpeakerBusSplitterRuntime *runtime,
    float left,
    float right,
    N60SpeakerBusFrame *frame
) {
    *frame = N60SpeakerBusFrameMakeSilence();
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftFullRange, left);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightFullRange, right);
    if (!runtime->snapshot.enabled) return;

    const N60SpeakerBusSplitterSnapshot *snapshot = &runtime->snapshot;
    if (snapshot->mode == N60SpeakerCrossoverModeMainsSub) {
        float mainsLeft = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighLeft,
            snapshot->lowerSectionCount, left
        );
        float mainsRight = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighRight,
            snapshot->lowerSectionCount, right
        );
        float subMono = 0.5f * (left + right);
        subMono = process_splitter_sections(
            snapshot->lowerLowPass, runtime->lowerLowMono,
            snapshot->lowerSectionCount, subMono
        );
        if (snapshot->subPhaseAlignmentEnabled) {
            subMono = N60BiquadProcessSample(
                snapshot->subPhaseAlignmentAllPass,
                &runtime->subPhaseAlignment,
                subMono
            );
        }
        subMono *= snapshot->subGainLinear;
        if (snapshot->subPolarityInverted) subMono = -subMono;
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftHigh, mainsLeft);
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightHigh, mainsRight);
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusSubMono, subMono);
        return;
    }

    float lowLeft = process_splitter_sections(
        snapshot->lowerLowPass, runtime->lowerLowLeft,
        snapshot->lowerSectionCount, left
    );
    float lowRight = process_splitter_sections(
        snapshot->lowerLowPass, runtime->lowerLowRight,
        snapshot->lowerSectionCount, right
    );
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftLow, lowLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightLow, lowRight);

    if (snapshot->mode == N60SpeakerCrossoverModeBiAmp) {
        float highLeft = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighLeft,
            snapshot->lowerSectionCount, left
        );
        float highRight = process_splitter_sections(
            snapshot->lowerHighPass, runtime->lowerHighRight,
            snapshot->lowerSectionCount, right
        );
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftHigh, highLeft);
        (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightHigh, highRight);
        return;
    }

    float midLeft = process_splitter_sections(
        snapshot->lowerHighPass, runtime->lowerHighLeft,
        snapshot->lowerSectionCount, left
    );
    float midRight = process_splitter_sections(
        snapshot->lowerHighPass, runtime->lowerHighRight,
        snapshot->lowerSectionCount, right
    );
    midLeft = process_splitter_sections(
        snapshot->upperLowPass, runtime->upperLowLeft,
        snapshot->upperSectionCount, midLeft
    );
    midRight = process_splitter_sections(
        snapshot->upperLowPass, runtime->upperLowRight,
        snapshot->upperSectionCount, midRight
    );
    float highLeft = process_splitter_sections(
        snapshot->upperHighPass, runtime->upperHighLeft,
        snapshot->upperSectionCount, left
    );
    float highRight = process_splitter_sections(
        snapshot->upperHighPass, runtime->upperHighRight,
        snapshot->upperSectionCount, right
    );
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftMid, midLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightMid, midRight);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusLeftHigh, highLeft);
    (void)N60SpeakerBusFrameSet(frame, N60SpeakerOutputBusRightHigh, highRight);
}

'''
impl = replace_once(impl, create_anchor, helpers + create_anchor, "C4 splitter processing helpers")
# Add configuration API before value-for-channel implementation.
api_anchor = '''bool N60SameDeviceOutputMapValueForChannel(\n'''
config_api = r'''bool N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(
    N60RealtimeAudioBridge *bridge,
    N60SpeakerBusSplitterSnapshot snapshot
) {
    if (bridge == NULL || !snapshot.enabled) return false;
    memset(&bridge->speakerBusSplitter, 0, sizeof(bridge->speakerBusSplitter));
    bridge->speakerBusSplitter.snapshot = snapshot;
    return true;
}

'''
impl = replace_once(impl, api_anchor, config_api + api_anchor, "C4 splitter configuration API")
# Replace full-range-only map frame generation with true logical splitter output.
impl = replace_once(
    impl,
    '''        if (sameDeviceMultiOutput) {\n            N60SpeakerBusFrame busFrame = N60SpeakerBusFrameMakeSilence();\n            (void)N60SpeakerBusFrameSet(&busFrame, N60SpeakerOutputBusLeftFullRange, finalLeft);\n            (void)N60SpeakerBusFrameSet(&busFrame, N60SpeakerOutputBusRightFullRange, finalRight);\n            if (!N60SameDeviceOutputMapWriteFrame(\n                &bridge->sameDeviceOutputMap, &busFrame, outOutputData, frameIndex\n            )) {\n''',
    '''        if (sameDeviceMultiOutput) {\n            N60SpeakerBusFrame busFrame;\n            process_speaker_bus_splitter(\n                &bridge->speakerBusSplitter, finalLeft, finalRight, &busFrame\n            );\n            if (!N60SameDeviceOutputMapWriteFrame(\n                &bridge->sameDeviceOutputMap, &busFrame, outOutputData, frameIndex\n            )) {\n''',
    "C4 live speaker bus generation",
)
impl_path.write_text(impl)


# 3. Swift model: physical crossover modes, wider driver crossover ranges, safe
# route/mode compatibility and control-plane splitter design.
engine_path = Path("NotchSixty/Audio/AudioIOEngine.swift")
engine = engine_path.read_text()
mode_anchor = '''struct BassManagementConfiguration: Equatable, Codable, Sendable {\n'''
mode_code = r'''enum SpeakerCrossoverMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case mainsSub
    case biAmp
    case triAmp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mainsSub: return "Mains + Sub"
        case .biAmp: return "Bi-Amp"
        case .triAmp: return "Tri-Amp"
        }
    }

    var cType: N60SpeakerCrossoverMode {
        switch self {
        case .mainsSub: return N60SpeakerCrossoverModeMainsSub
        case .biAmp: return N60SpeakerCrossoverModeBiAmp
        case .triAmp: return N60SpeakerCrossoverModeTriAmp
        }
    }

    func supports(bus: SpeakerOutputBus) -> Bool {
        if bus == .leftFullRange || bus == .rightFullRange { return true }
        switch self {
        case .mainsSub:
            return bus == .leftHigh || bus == .rightHigh || bus == .subMono
        case .biAmp:
            return bus == .leftLow || bus == .rightLow || bus == .leftHigh || bus == .rightHigh
        case .triAmp:
            return bus == .leftLow || bus == .rightLow
                || bus == .leftMid || bus == .rightMid
                || bus == .leftHigh || bus == .rightHigh
        }
    }
}

'''
engine = replace_once(engine, mode_anchor, mode_code + mode_anchor, "C4 crossover mode insertion")
engine = replace_once(
    engine,
    '''    static let subPhaseAlignmentQRange = 0.1...10.0\n\n    var enabled = false\n''',
    '''    static let subPhaseAlignmentQRange = 0.1...10.0\n    static let speakerFrequencyRange = 20.0...20_000.0\n\n    var enabled = false\n''',
    "C4 speaker frequency range",
)
engine = replace_once(
    engine,
    '''    var subPhaseAlignmentQ: Double = 0.7\n}\n\nenum BassManagementConfigurationError''',
    '''    var subPhaseAlignmentQ: Double = 0.7\n    // Optional for backward-compatible profile decoding. Nil preserves the\n    // existing recombined-stereo bass-management behavior.\n    var physicalOutputMode: SpeakerCrossoverMode? = nil\n    var upperFrequencyHz: Double? = nil\n    var upperTopology: CrossoverTopology? = nil\n\n    var lowerFrequencyRange: ClosedRange<Double> {\n        switch physicalOutputMode {\n        case .biAmp, .triAmp:\n            return Self.speakerFrequencyRange\n        case .mainsSub, .none:\n            return Self.frequencyRange\n        }\n    }\n\n    func makeSpeakerBusSplitterSnapshot(sampleRate: Double) throws -> N60SpeakerBusSplitterSnapshot {\n        guard enabled, let physicalOutputMode else {\n            throw BassManagementConfigurationError.physicalCrossoverModeRequired\n        }\n        guard frequencyHz.isFinite, lowerFrequencyRange.contains(frequencyHz),\n              frequencyHz < sampleRate * 0.5 else {\n            throw BassManagementConfigurationError.invalidFrequency(frequencyHz)\n        }\n        let upper = upperFrequencyHz ?? max(frequencyHz + 1.0, frequencyHz * 2.0)\n        if physicalOutputMode == .triAmp {\n            guard upper.isFinite, Self.speakerFrequencyRange.contains(upper),\n                  upper > frequencyHz, upper < sampleRate * 0.5 else {\n                throw BassManagementConfigurationError.invalidUpperFrequency(upper)\n            }\n        }\n        var snapshot = N60SpeakerBusSplitterSnapshot()\n        guard N60SpeakerBusSplitterSnapshotMake(\n            sampleRate,\n            physicalOutputMode.cType,\n            frequencyHz,\n            topology.cType,\n            upper,\n            (upperTopology ?? topology).cType,\n            DSPGainConfiguration.linearGain(forDB: subGainDB),\n            subPolarityInverted,\n            subPhaseAlignmentEnabled,\n            subPhaseAlignmentFrequencyHz,\n            subPhaseAlignmentQ,\n            &snapshot\n        ) else {\n            throw BassManagementConfigurationError.speakerBusSplitterDesignFailed\n        }\n        return snapshot\n    }\n}\n\nenum BassManagementConfigurationError''',
    "C4 bass configuration extension",
)
engine = replace_once(
    engine,
    '''    case invalidSubPhaseAlignmentQ(Double)\n    case graphDesignFailed\n''',
    '''    case invalidSubPhaseAlignmentQ(Double)\n    case invalidUpperFrequency(Double)\n    case physicalCrossoverModeRequired\n    case physicalCrossoverChangeRequiresIdle\n    case speakerBusSplitterDesignFailed\n    case graphDesignFailed\n''',
    "C4 bass errors",
)
engine = replace_once(
    engine,
    '''        case .invalidSubPhaseAlignmentQ(let value):\n            return "Sub phase-alignment Q \\(value) is outside the supported 0.1...10 range."\n        case .graphDesignFailed:\n''',
    '''        case .invalidSubPhaseAlignmentQ(let value):\n            return "Sub phase-alignment Q \\(value) is outside the supported 0.1...10 range."\n        case .invalidUpperFrequency(let value):\n            return "Upper crossover frequency \\(value) Hz must be above the lower crossover and below the active Nyquist limit."\n        case .physicalCrossoverModeRequired:\n            return "Choose Mains + Sub, Bi-Amp, or Tri-Amp before routing split speaker buses."\n        case .physicalCrossoverChangeRequiresIdle:\n            return "Stop processing before changing a physical speaker crossover."\n        case .speakerBusSplitterDesignFailed:\n            return "Unable to design the physical speaker crossover for the active output sample rate."\n        case .graphDesignFailed:\n''',
    "C4 bass error descriptions",
)
# Existing graph validation accepts wider lower crossover when physical mode is bi/tri.
engine = replace_once(
    engine,
    '''        guard bassManagementConfiguration.frequencyHz.isFinite,\n              BassManagementConfiguration.frequencyRange.contains(bassManagementConfiguration.frequencyHz) else {\n''',
    '''        guard bassManagementConfiguration.frequencyHz.isFinite,\n              bassManagementConfiguration.lowerFrequencyRange.contains(bassManagementConfiguration.frequencyHz) else {\n''',
    "C4 graph lower frequency validation",
)
# Add tri-amp upper validation immediately after lower frequency guard.
upper_guard_anchor = '''            throw BassManagementConfigurationError.invalidFrequency(bassManagementConfiguration.frequencyHz)\n        }\n        guard bassManagementConfiguration.subGainDB.isFinite,\n'''
upper_guard = '''            throw BassManagementConfigurationError.invalidFrequency(bassManagementConfiguration.frequencyHz)\n        }\n        if bassManagementConfiguration.physicalOutputMode == .triAmp {\n            let upper = bassManagementConfiguration.upperFrequencyHz ?? .nan\n            guard upper.isFinite, BassManagementConfiguration.speakerFrequencyRange.contains(upper),\n                  upper > bassManagementConfiguration.frequencyHz, upper < sampleRate * 0.5 else {\n                throw BassManagementConfigurationError.invalidUpperFrequency(upper)\n            }\n        }\n        guard bassManagementConfiguration.subGainDB.isFinite,\n'''
engine = replace_once(engine, upper_guard_anchor, upper_guard, "C4 graph upper frequency validation")

# Engine helpers: physical split routes suppress the old early recombined crossover.
class_anchor = '''    var selectedOutputDevice: AudioOutputDevice? {\n'''
class_helpers = r'''    var physicalSpeakerBusRoutingActive: Bool {
        guard let routing = multiOutputRoutingConfiguration, routing.enabled else { return false }
        return routing.enabledRoutes.contains { !$0.bus.isFullRangeBus }
    }

    private func renderBassManagementConfiguration(
        _ source: BassManagementConfiguration? = nil
    ) -> BassManagementConfiguration {
        var render = source ?? bassManagementConfiguration
        if physicalSpeakerBusRoutingActive {
            // The physical splitter runs after shared DSP/audition. Disabling the
            // older early recombined crossover prevents double filtering.
            render.enabled = false
            render.subPhaseAlignmentEnabled = false
        }
        return render
    }

'''
engine = replace_once(engine, class_anchor, class_helpers + class_anchor, "C4 engine render helper")

# Tighten replacement API for physical split mode and broaden validation range.
engine = replace_once(
    engine,
    '''        guard configuration.frequencyHz.isFinite,\n              BassManagementConfiguration.frequencyRange.contains(configuration.frequencyHz) else {\n''',
    '''        guard configuration.frequencyHz.isFinite,\n              configuration.lowerFrequencyRange.contains(configuration.frequencyHz) else {\n''',
    "C4 replace lower frequency validation",
)
replace_guard_anchor = '''        guard configuration.subPhaseAlignmentQ.isFinite,\n              BassManagementConfiguration.subPhaseAlignmentQRange.contains(configuration.subPhaseAlignmentQ) else {\n            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(configuration.subPhaseAlignmentQ)\n        }\n        if let session = transportSession {\n'''
replace_guard = '''        guard configuration.subPhaseAlignmentQ.isFinite,\n              BassManagementConfiguration.subPhaseAlignmentQRange.contains(configuration.subPhaseAlignmentQ) else {\n            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(configuration.subPhaseAlignmentQ)\n        }\n        if configuration.physicalOutputMode == .triAmp {\n            let upper = configuration.upperFrequencyHz ?? .nan\n            guard upper.isFinite, BassManagementConfiguration.speakerFrequencyRange.contains(upper),\n                  upper > configuration.frequencyHz else {\n                throw BassManagementConfigurationError.invalidUpperFrequency(upper)\n            }\n        }\n        if physicalSpeakerBusRoutingActive, lifecycle.state != .idle, configuration != bassManagementConfiguration {\n            throw BassManagementConfigurationError.physicalCrossoverChangeRequiresIdle\n        }\n        if let session = transportSession {\n'''
engine = replace_once(engine, replace_guard_anchor, replace_guard, "C4 replace physical idle guard")
# Prospective replacement graph must also suppress the old early crossover.
engine = replace_once(
    engine,
    '''                bassManagementConfiguration: configuration,\n                dynamicsConfiguration: dynamicsConfiguration,\n''',
    '''                bassManagementConfiguration: renderBassManagementConfiguration(configuration),\n                dynamicsConfiguration: dynamicsConfiguration,\n''',
    "C4 replacement render bass configuration",
)
# All ordinary graph rebuilds in AudioIOEngine use the helper while split routing is active.
class_index = engine.find("@MainActor\nfinal class AudioIOEngine")
if class_index < 0:
    raise SystemExit("C4 AudioIOEngine class marker missing")
prefix, body = engine[:class_index], engine[class_index:]
count = body.count("bassManagementConfiguration: bassManagementConfiguration,")
if count < 5:
    raise SystemExit(f"C4 expected multiple graph rebuilds, found {count}")
body = body.replace(
    "bassManagementConfiguration: bassManagementConfiguration,",
    "bassManagementConfiguration: renderBassManagementConfiguration(),"
)
engine = prefix + body
engine_path.write_text(engine)


# 4. Routing compatibility helpers. Full-range fan-out works with or without a
# physical crossover; split buses require the matching physical topology.
route_path = Path("NotchSixty/Audio/Routing/AudioRouteConfiguration.swift")
route = route_path.read_text()
route = replace_once(
    route,
    '''    var isC2bLiveFullRangeBus: Bool {\n        self == .leftFullRange || self == .rightFullRange\n    }\n''',
    '''    var isC2bLiveFullRangeBus: Bool {\n        isFullRangeBus\n    }\n\n    var isFullRangeBus: Bool {\n        self == .leftFullRange || self == .rightFullRange\n    }\n''',
    "C4 full-range bus helper",
)
append_route = r'''

extension SameDeviceOutputRoutePlan {
    func validateForC4LiveTransport(
        selectedOutputUID: String,
        crossoverMode: SpeakerCrossoverMode?
    ) throws {
        guard deviceUID == selectedOutputUID else {
            throw MultiOutputRoutingError.liveTransportOutputMismatch(
                selected: selectedOutputUID,
                routed: deviceUID
            )
        }
        for route in routes {
            if route.bus.isFullRangeBus { continue }
            guard let crossoverMode, crossoverMode.supports(bus: route.bus) else {
                throw MultiOutputRoutingError.liveTransportBusUnavailable(route.bus)
            }
        }
    }
}

extension AggregateDeviceOutputRoutePlan {
    func validateForC4LiveTransport(
        selectedOutputUID: String,
        crossoverMode: SpeakerCrossoverMode?
    ) throws {
        guard selectedOutputUID == referenceDeviceUID else {
            throw MultiOutputRoutingError.aggregateReferenceOutputMismatch(
                selected: selectedOutputUID,
                reference: referenceDeviceUID
            )
        }
        for mapped in mappedRoutes {
            if mapped.route.bus.isFullRangeBus { continue }
            guard let crossoverMode, crossoverMode.supports(bus: mapped.route.bus) else {
                throw MultiOutputRoutingError.liveTransportBusUnavailable(mapped.route.bus)
            }
        }
    }
}
'''
if "validateForC4LiveTransport" in route:
    raise SystemExit("C4 live route validator already present")
route = route.rstrip() + append_route + "\n"
# Make old error description no longer claim C2b is the final capability.
route = route.replace(
    'return "\\(bus.displayName) is not live-routable yet. C2b only routes the final post-DSP Left/Right Full Range buses."',
    'return "\\(bus.displayName) is not valid for the selected physical crossover topology."'
)
route_path.write_text(route)


# 5. CoreAudio session configures the immutable physical splitter before IO starts.
core_path = Path("NotchSixty/Audio/CoreAudio/CoreAudioError.swift")
core = core_path.read_text()
core = replace_once(
    core,
    '''    case aggregateDeviceNotReady\n''',
    '''    case aggregateDeviceNotReady\n    case speakerBusSplitterConfigurationFailed\n''',
    "C4 transport splitter error",
)
core = replace_once(
    core,
    '''        case .aggregateDeviceNotReady:\n            return "Core Audio created the private multi-output aggregate device but it did not become ready for IO."\n''',
    '''        case .aggregateDeviceNotReady:\n            return "Core Audio created the private multi-output aggregate device but it did not become ready for IO."\n        case .speakerBusSplitterConfigurationFailed:\n            return "Unable to configure the immutable physical speaker crossover before audio callbacks start."\n''',
    "C4 transport splitter error description",
)
core = replace_once(
    core,
    '''        sameDeviceOutputPlan: SameDeviceOutputRoutePlan? = nil,\n        aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan? = nil\n    ) throws {\n''',
    '''        sameDeviceOutputPlan: SameDeviceOutputRoutePlan? = nil,\n        aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan? = nil,\n        speakerCrossoverMode: SpeakerCrossoverMode? = nil,\n        speakerBusSplitterSnapshot: N60SpeakerBusSplitterSnapshot? = nil\n    ) throws {\n''',
    "C4 session splitter initializer args",
)
# Use C4 route validators and configure splitter after map setup.
core = core.replace(
    "try sameDeviceOutputPlan.validateForC2bLiveTransport(selectedOutputUID: selectedOutput.uid)",
    "try sameDeviceOutputPlan.validateForC4LiveTransport(selectedOutputUID: selectedOutput.uid, crossoverMode: speakerCrossoverMode)"
)
core = core.replace(
    "try aggregateDeviceOutputPlan.validateForC3LiveTransport(selectedOutputUID: selectedOutput.uid)",
    "try aggregateDeviceOutputPlan.validateForC4LiveTransport(selectedOutputUID: selectedOutput.uid, crossoverMode: speakerCrossoverMode)"
)
unity_anchor = '''            let unityGraph = N60DSPGraphSnapshotMakeUnity(outputFormat.sampleRate)\n'''
splitter_config = '''            if let speakerBusSplitterSnapshot {\n                guard N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(\n                    newBridge, speakerBusSplitterSnapshot\n                ) else {\n                    throw CoreAudioTransportError.speakerBusSplitterConfigurationFailed\n                }\n            }\n\n'''
core = replace_once(core, unity_anchor, splitter_config + unity_anchor, "C4 session splitter configuration")
core_path.write_text(core)


# 6. Engine transport builder designs the splitter only when any physical split
# bus is routed; ordinary full-range fan-out remains bit-for-bit C2b behavior.
engine = engine_path.read_text()
old_session_build = '''        let session = try CoreAudioTransportSession(\n            selectedOutput: output,\n            sameDeviceOutputPlan: sameDeviceOutputPlan,\n            aggregateDeviceOutputPlan: aggregateDeviceOutputPlan\n        )\n'''
new_session_build = '''        let speakerCrossoverMode: SpeakerCrossoverMode?\n        let speakerBusSplitterSnapshot: N60SpeakerBusSplitterSnapshot?\n        if physicalSpeakerBusRoutingActive {\n            speakerCrossoverMode = bassManagementConfiguration.physicalOutputMode\n            speakerBusSplitterSnapshot = try bassManagementConfiguration.makeSpeakerBusSplitterSnapshot(\n                sampleRate: output.nominalSampleRate\n            )\n        } else {\n            speakerCrossoverMode = nil\n            speakerBusSplitterSnapshot = nil\n        }\n        if let plan = sameDeviceOutputPlan {\n            try plan.validateForC4LiveTransport(\n                selectedOutputUID: output.uid,\n                crossoverMode: speakerCrossoverMode\n            )\n        }\n        if let plan = aggregateDeviceOutputPlan {\n            try plan.validateForC4LiveTransport(\n                selectedOutputUID: output.uid,\n                crossoverMode: speakerCrossoverMode\n            )\n        }\n        let session = try CoreAudioTransportSession(\n            selectedOutput: output,\n            sameDeviceOutputPlan: sameDeviceOutputPlan,\n            aggregateDeviceOutputPlan: aggregateDeviceOutputPlan,\n            speakerCrossoverMode: speakerCrossoverMode,\n            speakerBusSplitterSnapshot: speakerBusSplitterSnapshot\n        )\n'''
engine = replace_once(engine, old_session_build, new_session_build, "C4 engine splitter transport")
engine_path.write_text(engine)


# 7. Permanent C regression: prove the actual IOProc produces physical mains/sub
# crossover buses after the shared render kernel while full-range remains intact.
validator_path = Path("ci/validate_pr41_same_device_output_map.c")
validator = validator_path.read_text()
main_anchor = '''int main(void) {\n'''
split_test = r'''static int validate_live_mains_sub_splitter(void) {
    const uint32_t frames = 4096;
    N60RealtimeAudioBridge *bridge = N60RealtimeAudioBridgeCreate(frames + 64);
    if (bridge == NULL) return 40;

    N60SpeakerOutputRouteDescriptor routes[4] = {
        {N60SpeakerOutputBusLeftHigh, 0},
        {N60SpeakerOutputBusRightHigh, 1},
        {N60SpeakerOutputBusSubMono, 2},
        {N60SpeakerOutputBusLeftFullRange, 3},
    };
    N60SameDeviceOutputMap map = {0};
    if (!N60SameDeviceOutputMapCompile(4, routes, 4, &map)
        || !N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(bridge, map)) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 41;
    }
    N60SpeakerBusSplitterSnapshot splitter = {0};
    if (!N60SpeakerBusSplitterSnapshotMake(
            48000.0,
            N60SpeakerCrossoverModeMainsSub,
            200.0,
            N60CrossoverTopologyLinkwitzRiley24,
            2000.0,
            N60CrossoverTopologyLinkwitzRiley24,
            1.0f,
            false,
            false,
            200.0,
            0.7,
            &splitter)
        || !N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(bridge, splitter)) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 42;
    }
    N60DSPGraphSnapshot graph = N60DSPGraphSnapshotMakeUnity(48000.0);
    if (!N60RealtimeAudioBridgePublishDSPGraph(bridge, graph)) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return 43;
    }

    float *inputSamples = calloc((size_t)frames * 2u, sizeof(float));
    float *outputSamples = calloc((size_t)frames * 4u, sizeof(float));
    if (inputSamples == NULL || outputSamples == NULL) {
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return 44;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
        inputSamples[frame * 2u] = 0.5f;
        inputSamples[frame * 2u + 1u] = 0.5f;
    }
    AudioBufferList input = {0};
    input.mNumberBuffers = 1;
    input.mBuffers[0].mNumberChannels = 2;
    input.mBuffers[0].mDataByteSize = frames * 2u * (uint32_t)sizeof(float);
    input.mBuffers[0].mData = inputSamples;
    AudioBufferList output = {0};
    output.mNumberBuffers = 1;
    output.mBuffers[0].mNumberChannels = 4;
    output.mBuffers[0].mDataByteSize = frames * 4u * (uint32_t)sizeof(float);
    output.mBuffers[0].mData = outputSamples;
    AudioTimeStamp timestamp = {0};
    if (N60CaptureIOProc(0, &timestamp, &input, &timestamp, &input, &timestamp, bridge) != noErr
        || N60OutputIOProc(0, &timestamp, &input, &timestamp, &output, &timestamp, bridge) != noErr) {
        free(inputSamples);
        free(outputSamples);
        N60RealtimeAudioBridgeDestroy(bridge);
        return 45;
    }

    uint32_t base = (frames - 1u) * 4u;
    float mainsLeft = outputSamples[base];
    float mainsRight = outputSamples[base + 1u];
    float sub = outputSamples[base + 2u];
    float fullRange = outputSamples[base + 3u];
    int result = 0;
    if (fabsf(mainsLeft) > 0.01f || fabsf(mainsRight) > 0.01f) result = 46;
    if (fabsf(sub - 0.5f) > 0.01f) result = 47;
    if (fabsf(fullRange - 0.5f) > 1.0e-6f) result = 48;

    free(inputSamples);
    free(outputSamples);
    N60RealtimeAudioBridgeDestroy(bridge);
    return result;
}

'''
validator = replace_once(validator, main_anchor, split_test + main_anchor, "C4 C validator insertion")
validator = replace_once(
    validator,
    '''    result = validate_live_output_ioproc();\n    if (result != 0) return result;\n    puts("PR41 same-device output map and live IOProc validation passed");\n''',
    '''    result = validate_live_output_ioproc();\n    if (result != 0) return result;\n    result = validate_live_mains_sub_splitter();\n    if (result != 0) return result;\n    puts("PR41 output map, live IOProc, and physical speaker-bus splitter validation passed");\n''',
    "C4 C validator invocation",
)
validator_path.write_text(validator)


# 8. Swift focused tests for all physical modes and route compatibility.
tests_path = Path("NotchSixtyTests/RoomCorrectionProjectControllerTests.swift")
tests = tests_path.read_text()
if not tests.endswith("\n}\n"):
    raise SystemExit("Unexpected RoomCorrectionProjectControllerTests.swift ending")
tests_add = r'''
    func testPhysicalSpeakerCrossoverDesignsAtNativeRateMatrix() throws {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0, 192_000.0, 384_000.0] {
            var mainsSub = BassManagementConfiguration()
            mainsSub.enabled = true
            mainsSub.physicalOutputMode = .mainsSub
            mainsSub.frequencyHz = 80
            mainsSub.topology = .linkwitzRiley24
            var snapshot = try mainsSub.makeSpeakerBusSplitterSnapshot(sampleRate: sampleRate)
            XCTAssertTrue(snapshot.enabled)
            XCTAssertEqual(snapshot.mode, N60SpeakerCrossoverModeMainsSub)
            XCTAssertEqual(snapshot.lowerSectionCount, 2)

            var biAmp = BassManagementConfiguration()
            biAmp.enabled = true
            biAmp.physicalOutputMode = .biAmp
            biAmp.frequencyHz = 2_000
            biAmp.topology = .linkwitzRiley48
            snapshot = try biAmp.makeSpeakerBusSplitterSnapshot(sampleRate: sampleRate)
            XCTAssertEqual(snapshot.mode, N60SpeakerCrossoverModeBiAmp)
            XCTAssertEqual(snapshot.lowerSectionCount, 4)

            var triAmp = BassManagementConfiguration()
            triAmp.enabled = true
            triAmp.physicalOutputMode = .triAmp
            triAmp.frequencyHz = 300
            triAmp.topology = .linkwitzRiley24
            triAmp.upperFrequencyHz = 3_000
            triAmp.upperTopology = .linkwitzRiley48
            snapshot = try triAmp.makeSpeakerBusSplitterSnapshot(sampleRate: sampleRate)
            XCTAssertEqual(snapshot.mode, N60SpeakerCrossoverModeTriAmp)
            XCTAssertEqual(snapshot.lowerSectionCount, 2)
            XCTAssertEqual(snapshot.upperSectionCount, 4)
        }
    }

    func testPhysicalSpeakerRouteCompatibilityMatchesTopology() throws {
        let device = AudioOutputDevice(
            deviceID: 801,
            uid: "speaker-dac",
            name: "Speaker DAC",
            nominalSampleRate: 96_000,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 192_000)],
            outputChannelCount: 8
        )
        func plan(_ buses: [SpeakerOutputBus]) throws -> SameDeviceOutputRoutePlan {
            let routing = MultiOutputRoutingConfiguration(
                enabled: true,
                routes: buses.enumerated().map { index, bus in
                    SpeakerOutputRoute(
                        name: bus.displayName,
                        bus: bus,
                        destination: PhysicalOutputEndpoint(
                            deviceUID: device.uid,
                            channelIndex: UInt32(index)
                        )
                    )
                }
            )
            return try routing.makeSameDevicePlan(
                availableDevices: [device],
                sampleRate: 96_000
            )
        }

        XCTAssertNoThrow(try plan([.leftHigh, .rightHigh, .subMono]).validateForC4LiveTransport(
            selectedOutputUID: device.uid,
            crossoverMode: .mainsSub
        ))
        XCTAssertNoThrow(try plan([.leftLow, .rightLow, .leftHigh, .rightHigh]).validateForC4LiveTransport(
            selectedOutputUID: device.uid,
            crossoverMode: .biAmp
        ))
        XCTAssertNoThrow(try plan([.leftLow, .rightLow, .leftMid, .rightMid, .leftHigh, .rightHigh]).validateForC4LiveTransport(
            selectedOutputUID: device.uid,
            crossoverMode: .triAmp
        ))
        XCTAssertThrowsError(try plan([.leftMid, .rightMid]).validateForC4LiveTransport(
            selectedOutputUID: device.uid,
            crossoverMode: .biAmp
        )) { error in
            XCTAssertEqual(error as? MultiOutputRoutingError, .liveTransportBusUnavailable(.leftMid))
        }
        XCTAssertNoThrow(try plan([.leftFullRange, .rightFullRange]).validateForC4LiveTransport(
            selectedOutputUID: device.uid,
            crossoverMode: nil
        ))
    }

    func testTriAmpRequiresOrderedUpperCrossover() throws {
        var configuration = BassManagementConfiguration()
        configuration.enabled = true
        configuration.physicalOutputMode = .triAmp
        configuration.frequencyHz = 2_000
        configuration.upperFrequencyHz = 1_000
        XCTAssertThrowsError(try configuration.makeSpeakerBusSplitterSnapshot(sampleRate: 48_000)) { error in
            XCTAssertEqual(error as? BassManagementConfigurationError, .invalidUpperFrequency(1_000))
        }
    }
'''
tests = tests[:-3] + "\n" + tests_add + "}\n"
tests_path.write_text(tests)

print("PR41 Slice C4 core patch applied")
