#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]

# -----------------------------------------------------------------------------
# Fixed-size realtime processor. No allocation, locking, I/O, or coefficient
# design occurs on the render callback.
# -----------------------------------------------------------------------------
driver_header = root / "NotchSixty" / "Audio" / "Realtime" / "N60SpeakerDriverProcessing.h"
driver_header.write_text(r'''#ifndef N60SpeakerDriverProcessing_h
#define N60SpeakerDriverProcessing_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#include "N60Biquad.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_SPEAKER_DRIVER_BUS_COUNT 9u
#define N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS 8u
// 50 ms at the product's validated 384 kHz ceiling, plus one guard frame.
#define N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES 19201u

typedef struct {
    bool enabled;
    uint32_t eqSectionCount;
    N60BiquadCoefficients eqSections[N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS];
    float trimLinear;
    bool polarityInverted;
    uint32_t integerDelayFrames;
    float fractionalDelay;
    float fractionalAllPassCoefficient;
    bool limiterEnabled;
    float limiterThresholdLinear;
    float limiterReleaseCoefficient;
} N60SpeakerDriverBusSnapshot;

typedef struct {
    bool valid;
    bool enabled;
    N60SpeakerDriverBusSnapshot buses[N60_SPEAKER_DRIVER_BUS_COUNT];
} N60SpeakerDriverProcessingSnapshot;

typedef struct {
    N60BiquadState eqStates[N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS];
    float delayLine[N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES];
    uint32_t delayWriteIndex;
    float fractionalInputHistory;
    float fractionalOutputHistory;
    float limiterGain;
} N60SpeakerDriverBusRuntime;

typedef struct {
    N60SpeakerDriverProcessingSnapshot snapshot;
    N60SpeakerDriverBusRuntime buses[N60_SPEAKER_DRIVER_BUS_COUNT];
} N60SpeakerDriverProcessingRuntime;

static inline N60SpeakerDriverProcessingSnapshot
N60SpeakerDriverProcessingSnapshotMakeBypassed(void) {
    N60SpeakerDriverProcessingSnapshot snapshot = {0};
    snapshot.valid = true;
    snapshot.enabled = false;
    for (uint32_t bus = 0; bus < N60_SPEAKER_DRIVER_BUS_COUNT; ++bus) {
        snapshot.buses[bus].trimLinear = 1.0f;
        snapshot.buses[bus].limiterThresholdLinear = 1.0f;
        snapshot.buses[bus].limiterReleaseCoefficient = 0.999f;
        for (uint32_t index = 0; index < N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS; ++index) {
            snapshot.buses[bus].eqSections[index] = N60BiquadCoefficientsMakeIdentity();
        }
    }
    return snapshot;
}

static inline bool N60SpeakerDriverProcessingSnapshotSetBus(
    N60SpeakerDriverProcessingSnapshot *snapshot,
    uint32_t busIndex,
    bool enabled,
    const N60BiquadCoefficients *eqSections,
    uint32_t eqSectionCount,
    float trimLinear,
    bool polarityInverted,
    uint32_t integerDelayFrames,
    float fractionalDelay,
    bool limiterEnabled,
    float limiterThresholdLinear,
    float limiterReleaseCoefficient
) {
    if (snapshot == NULL || !snapshot->valid
        || busIndex >= N60_SPEAKER_DRIVER_BUS_COUNT
        || eqSectionCount > N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS
        || (eqSectionCount > 0 && eqSections == NULL)
        || !isfinite(trimLinear) || trimLinear < 0.0f
        || integerDelayFrames >= N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES
        || !isfinite(fractionalDelay) || fractionalDelay < 0.0f || fractionalDelay >= 1.0f
        || !isfinite(limiterThresholdLinear) || limiterThresholdLinear <= 0.0f
        || limiterThresholdLinear > 1.0f
        || !isfinite(limiterReleaseCoefficient)
        || limiterReleaseCoefficient < 0.0f || limiterReleaseCoefficient >= 1.0f) {
        return false;
    }

    N60SpeakerDriverBusSnapshot configured = {0};
    configured.enabled = enabled;
    configured.eqSectionCount = eqSectionCount;
    configured.trimLinear = trimLinear;
    configured.polarityInverted = polarityInverted;
    configured.integerDelayFrames = integerDelayFrames;
    configured.fractionalDelay = fractionalDelay;
    configured.fractionalAllPassCoefficient = fractionalDelay > 1.0e-7f
        ? (1.0f - fractionalDelay) / (1.0f + fractionalDelay)
        : 0.0f;
    configured.limiterEnabled = limiterEnabled;
    configured.limiterThresholdLinear = limiterThresholdLinear;
    configured.limiterReleaseCoefficient = limiterReleaseCoefficient;
    for (uint32_t index = 0; index < N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS; ++index) {
        configured.eqSections[index] = index < eqSectionCount
            ? eqSections[index]
            : N60BiquadCoefficientsMakeIdentity();
    }

    snapshot->buses[busIndex] = configured;
    if (enabled) snapshot->enabled = true;
    return true;
}

static inline bool N60SpeakerDriverProcessingRuntimeConfigure(
    N60SpeakerDriverProcessingRuntime *runtime,
    N60SpeakerDriverProcessingSnapshot snapshot
) {
    if (runtime == NULL || !snapshot.valid) return false;
    memset(runtime, 0, sizeof(*runtime));
    runtime->snapshot = snapshot;
    for (uint32_t bus = 0; bus < N60_SPEAKER_DRIVER_BUS_COUNT; ++bus) {
        runtime->buses[bus].limiterGain = 1.0f;
    }
    return true;
}

static inline float N60SpeakerDriverProcessEQ(
    const N60SpeakerDriverBusSnapshot *snapshot,
    N60SpeakerDriverBusRuntime *runtime,
    float input
) {
    float value = input;
    for (uint32_t index = 0; index < snapshot->eqSectionCount; ++index) {
        value = N60BiquadProcessSample(
            snapshot->eqSections[index], &runtime->eqStates[index], value
        );
    }
    return value;
}

static inline float N60SpeakerDriverProcessDelay(
    const N60SpeakerDriverBusSnapshot *snapshot,
    N60SpeakerDriverBusRuntime *runtime,
    float input
) {
    float delayed = input;
    const uint32_t delayFrames = snapshot->integerDelayFrames;
    if (delayFrames > 0) {
        uint32_t index = runtime->delayWriteIndex;
        delayed = runtime->delayLine[index];
        runtime->delayLine[index] = input;
        index += 1;
        if (index >= delayFrames) index = 0;
        runtime->delayWriteIndex = index;
    }

    if (snapshot->fractionalDelay > 1.0e-7f) {
        const float coefficient = snapshot->fractionalAllPassCoefficient;
        const float output = coefficient * delayed
            + runtime->fractionalInputHistory
            - coefficient * runtime->fractionalOutputHistory;
        runtime->fractionalInputHistory = delayed;
        runtime->fractionalOutputHistory = output;
        delayed = output;
    }
    return delayed;
}

static inline float N60SpeakerDriverProcessLimiter(
    const N60SpeakerDriverBusSnapshot *snapshot,
    N60SpeakerDriverBusRuntime *runtime,
    float input
) {
    if (!snapshot->limiterEnabled) return input;
    const float magnitude = fabsf(input);
    float gain = runtime->limiterGain;
    if (magnitude > snapshot->limiterThresholdLinear && magnitude > 0.0f) {
        const float required = snapshot->limiterThresholdLinear / magnitude;
        if (required < gain) gain = required;
    } else {
        const float release = snapshot->limiterReleaseCoefficient;
        gain = release * gain + (1.0f - release);
        if (gain > 1.0f) gain = 1.0f;
    }
    runtime->limiterGain = gain;
    return input * gain;
}

static inline void N60SpeakerDriverProcessingRuntimeProcessValues(
    N60SpeakerDriverProcessingRuntime *runtime,
    float values[N60_SPEAKER_DRIVER_BUS_COUNT]
) {
    if (runtime == NULL || values == NULL || !runtime->snapshot.enabled) return;
    for (uint32_t bus = 0; bus < N60_SPEAKER_DRIVER_BUS_COUNT; ++bus) {
        const N60SpeakerDriverBusSnapshot *snapshot = &runtime->snapshot.buses[bus];
        if (!snapshot->enabled) continue;
        N60SpeakerDriverBusRuntime *busRuntime = &runtime->buses[bus];
        float value = values[bus];
        value = N60SpeakerDriverProcessEQ(snapshot, busRuntime, value);
        value = N60SpeakerDriverProcessDelay(snapshot, busRuntime, value);
        value *= snapshot->trimLinear;
        if (snapshot->polarityInverted) value = -value;
        value = N60SpeakerDriverProcessLimiter(snapshot, busRuntime, value);
        values[bus] = isfinite(value) ? value : 0.0f;
    }
}

#ifdef __cplusplus
}
#endif

#endif
''', encoding="utf-8")

# -----------------------------------------------------------------------------
# Bridge integration: splitter ALWAYS runs first, driver processing second,
# physical channel map last.
# -----------------------------------------------------------------------------
bridge_h_path = root / "NotchSixty" / "Audio" / "Realtime" / "N60RealtimeAudioBridge.h"
bridge_h = bridge_h_path.read_text(encoding="utf-8")
include_anchor = "typedef struct {\n    float values[N60SpeakerOutputBusCount];\n} N60SpeakerBusFrame;\n"
if '#include "N60SpeakerDriverProcessing.h"' not in bridge_h:
    if include_anchor not in bridge_h:
        raise SystemExit("bridge frame include anchor not found")
    bridge_h = bridge_h.replace(
        include_anchor,
        include_anchor + '\n#include "N60SpeakerDriverProcessing.h"\n',
        1,
    )
configure_anchor = "bool N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(\n    N60RealtimeAudioBridge * _Nonnull bridge,\n    N60SpeakerBusSplitterSnapshot snapshot\n);\n"
if "N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing" not in bridge_h:
    if configure_anchor not in bridge_h:
        raise SystemExit("bridge configure declaration anchor not found")
    bridge_h = bridge_h.replace(
        configure_anchor,
        configure_anchor + r'''bool N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing(
    N60RealtimeAudioBridge * _Nonnull bridge,
    N60SpeakerDriverProcessingSnapshot snapshot
);
''',
        1,
    )
bridge_h_path.write_text(bridge_h, encoding="utf-8")

bridge_c_path = root / "NotchSixty" / "Audio" / "Realtime" / "N60RealtimeAudioBridge.c"
bridge_c = bridge_c_path.read_text(encoding="utf-8")
struct_anchor = "    N60SpeakerBusSplitterRuntime speakerBusSplitter;\n"
if "N60SpeakerDriverProcessingRuntime speakerDriverProcessing;" not in bridge_c:
    if struct_anchor not in bridge_c:
        raise SystemExit("bridge runtime struct anchor not found")
    bridge_c = bridge_c.replace(
        struct_anchor,
        struct_anchor + "    N60SpeakerDriverProcessingRuntime speakerDriverProcessing;\n",
        1,
    )
configure_impl_anchor = r'''bool N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(
    N60RealtimeAudioBridge *bridge,
    N60SpeakerBusSplitterSnapshot snapshot
) {
    if (bridge == NULL || !snapshot.enabled) return false;
    memset(&bridge->speakerBusSplitter, 0, sizeof(bridge->speakerBusSplitter));
    bridge->speakerBusSplitter.snapshot = snapshot;
    return true;
}
'''
if "bool N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing(" not in bridge_c:
    if configure_impl_anchor not in bridge_c:
        raise SystemExit("bridge splitter configure implementation anchor not found")
    bridge_c = bridge_c.replace(
        configure_impl_anchor,
        configure_impl_anchor + r'''
bool N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing(
    N60RealtimeAudioBridge *bridge,
    N60SpeakerDriverProcessingSnapshot snapshot
) {
    if (bridge == NULL) return false;
    return N60SpeakerDriverProcessingRuntimeConfigure(
        &bridge->speakerDriverProcessing, snapshot
    );
}
''',
        1,
    )
process_anchor = r'''            process_speaker_bus_splitter(
                &bridge->speakerBusSplitter, finalLeft, finalRight, &busFrame
            );
            if (!N60SameDeviceOutputMapWriteFrame(
'''
if "N60SpeakerDriverProcessingRuntimeProcessValues" not in bridge_c:
    if process_anchor not in bridge_c:
        raise SystemExit("bridge output process anchor not found")
    bridge_c = bridge_c.replace(
        process_anchor,
        r'''            process_speaker_bus_splitter(
                &bridge->speakerBusSplitter, finalLeft, finalRight, &busFrame
            );
            // PR43 invariant: mandatory crossover/speaker-bus splitting happens
            // before any optional per-driver processing. Driver bypass can never
            // restore full-range content to a protected Low/Mid/High/Sub bus.
            N60SpeakerDriverProcessingRuntimeProcessValues(
                &bridge->speakerDriverProcessing, busFrame.values
            );
            if (!N60SameDeviceOutputMapWriteFrame(
''',
        1,
    )
bridge_c_path.write_text(bridge_c, encoding="utf-8")

# -----------------------------------------------------------------------------
# Swift control-plane compilation from the typed B1 Playback System model.
# -----------------------------------------------------------------------------
route_path = root / "NotchSixty" / "Audio" / "Routing" / "AudioRouteConfiguration.swift"
route = route_path.read_text(encoding="utf-8")
# Restrict shelf slopes so one UI band always maps to one bounded runtime section.
validation_anchor = r'''            guard Self.supportedEQTypes.contains(band.type) else {
                throw SpeakerDriverProcessingError.unsupportedEQShape(bus: bus, type: band.type)
            }
            guard band.firKernel == nil,
'''
if "driver shelves intentionally use one 12 dB/oct section" not in route:
    if validation_anchor not in route:
        raise SystemExit("driver EQ validation anchor not found")
    route = route.replace(
        validation_anchor,
        r'''            guard Self.supportedEQTypes.contains(band.type) else {
                throw SpeakerDriverProcessingError.unsupportedEQShape(bus: bus, type: band.type)
            }
            // Per-driver shelves intentionally use one 12 dB/oct section so an
            // eight-band UI remains an eight-section bounded realtime program.
            if (band.type == .lowShelf || band.type == .highShelf), band.slope != .db12 {
                throw SpeakerDriverProcessingError.invalidEQBand(bus: bus, index: index)
            }
            guard band.firKernel == nil,
''',
        1,
    )

if "func makeRealtimeSnapshot(sampleRate: Double) throws -> N60SpeakerDriverProcessingSnapshot" not in route:
    route += r'''

extension SpeakerOutputBus {
    var realtimeDriverIndex: UInt32 {
        switch self {
        case .leftFullRange: return 0
        case .rightFullRange: return 1
        case .leftLow: return 2
        case .rightLow: return 3
        case .leftMid: return 4
        case .rightMid: return 5
        case .leftHigh: return 6
        case .rightHigh: return 7
        case .subMono: return 8
        }
    }
}

extension SpeakerDriverProcessingConfiguration {
    func makeRealtimeSnapshot(sampleRate: Double) throws -> N60SpeakerDriverProcessingSnapshot {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= 384_000 else {
            throw SpeakerDriverProcessingError.invalidDelay(bus: .leftFullRange, value: sampleRate)
        }
        try validateStructure()
        var snapshot = N60SpeakerDriverProcessingSnapshotMakeBypassed()
        for configuration in buses {
            var coefficients: [N60BiquadCoefficients] = []
            coefficients.reserveCapacity(configuration.eqBands.count)
            for (index, band) in configuration.eqBands.enumerated() where band.enabled {
                let sections = try band.compiledSections(sampleRate: sampleRate)
                guard sections.count == 1,
                      coefficients.count < Int(N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS) else {
                    throw SpeakerDriverProcessingError.invalidEQBand(
                        bus: configuration.bus,
                        index: index
                    )
                }
                coefficients.append(sections[0].coefficients)
            }

            let exactDelay = configuration.delayMilliseconds * sampleRate / 1_000.0
            let integerDelay = floor(exactDelay)
            guard integerDelay >= 0,
                  integerDelay < Double(N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES) else {
                throw SpeakerDriverProcessingError.invalidDelay(
                    bus: configuration.bus,
                    value: configuration.delayMilliseconds
                )
            }
            let fractionalDelay = Float(exactDelay - integerDelay)
            let trim = Float(pow(10.0, configuration.trimDB / 20.0))
            let threshold = Float(pow(10.0, configuration.limiterThresholdDBFS / 20.0))
            let release = Float(exp(-1.0 / (0.050 * sampleRate)))

            let configured = coefficients.withUnsafeBufferPointer { buffer in
                N60SpeakerDriverProcessingSnapshotSetBus(
                    &snapshot,
                    configuration.bus.realtimeDriverIndex,
                    configuration.enabled,
                    buffer.baseAddress,
                    UInt32(buffer.count),
                    trim,
                    configuration.polarityInverted,
                    UInt32(integerDelay),
                    fractionalDelay,
                    configuration.limiterEnabled,
                    threshold,
                    release
                )
            }
            guard configured else {
                throw SpeakerDriverProcessingError.invalidEQBand(
                    bus: configuration.bus,
                    index: 0
                )
            }
        }
        return snapshot
    }
}
'''
route_path.write_text(route, encoding="utf-8")

# -----------------------------------------------------------------------------
# Transport config before callbacks and AudioIOEngine session wiring.
# -----------------------------------------------------------------------------
core_path = root / "NotchSixty" / "Audio" / "CoreAudio" / "CoreAudioError.swift"
core = core_path.read_text(encoding="utf-8")
error_case_anchor = "    case speakerBusSplitterConfigurationFailed\n"
if "case speakerDriverProcessingConfigurationFailed" not in core:
    if error_case_anchor not in core:
        raise SystemExit("CoreAudio error case anchor not found")
    core = core.replace(
        error_case_anchor,
        error_case_anchor + "    case speakerDriverProcessingConfigurationFailed\n",
        1,
    )
error_desc_anchor = r'''        case .speakerBusSplitterConfigurationFailed:
            return "Unable to configure the immutable physical speaker crossover before audio callbacks start."
'''
if "case .speakerDriverProcessingConfigurationFailed:" not in core:
    if error_desc_anchor not in core:
        raise SystemExit("CoreAudio error description anchor not found")
    core = core.replace(
        error_desc_anchor,
        error_desc_anchor + r'''        case .speakerDriverProcessingConfigurationFailed:
            return "Unable to configure immutable per-driver speaker processing before audio callbacks start."
''',
        1,
    )
init_param_anchor = r'''        aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan? = nil,
        speakerCrossoverMode: SpeakerCrossoverMode? = nil,
        speakerBusSplitterSnapshot: N60SpeakerBusSplitterSnapshot? = nil
'''
if "speakerDriverProcessingSnapshot: N60SpeakerDriverProcessingSnapshot?" not in core:
    if init_param_anchor not in core:
        raise SystemExit("CoreAudio session init parameter anchor not found")
    core = core.replace(
        init_param_anchor,
        r'''        aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan? = nil,
        speakerCrossoverMode: SpeakerCrossoverMode? = nil,
        speakerBusSplitterSnapshot: N60SpeakerBusSplitterSnapshot? = nil,
        speakerDriverProcessingSnapshot: N60SpeakerDriverProcessingSnapshot? = nil
''',
        1,
    )
configure_driver_anchor = r'''            if let speakerBusSplitterSnapshot {
                guard N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(
                    newBridge, speakerBusSplitterSnapshot
                ) else {
                    throw CoreAudioTransportError.speakerBusSplitterConfigurationFailed
                }
            }

            let unityGraph = N60DSPGraphSnapshotMakeUnity(outputFormat.sampleRate)
'''
if "throw CoreAudioTransportError.speakerDriverProcessingConfigurationFailed" not in core:
    if configure_driver_anchor not in core:
        raise SystemExit("CoreAudio driver configure insertion anchor not found")
    core = core.replace(
        configure_driver_anchor,
        r'''            if let speakerBusSplitterSnapshot {
                guard N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(
                    newBridge, speakerBusSplitterSnapshot
                ) else {
                    throw CoreAudioTransportError.speakerBusSplitterConfigurationFailed
                }
            }
            if let speakerDriverProcessingSnapshot {
                guard N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing(
                    newBridge, speakerDriverProcessingSnapshot
                ) else {
                    throw CoreAudioTransportError.speakerDriverProcessingConfigurationFailed
                }
            }

            let unityGraph = N60DSPGraphSnapshotMakeUnity(outputFormat.sampleRate)
''',
        1,
    )
core_path.write_text(core, encoding="utf-8")

engine_path = root / "NotchSixty" / "Audio" / "AudioIOEngine.swift"
engine = engine_path.read_text(encoding="utf-8")
session_arg_anchor = "            speakerBusSplitterSnapshot: speakerBusSplitterSnapshot\n        )"
if "speakerDriverProcessingSnapshot: speakerDriverProcessingSnapshot" not in engine:
    if session_arg_anchor not in engine:
        raise SystemExit("AudioIOEngine session argument anchor not found")
    # Compile once on the control plane immediately before session construction.
    session_start = "        let session = try CoreAudioTransportSession(\n"
    if session_start not in engine:
        raise SystemExit("AudioIOEngine session construction anchor not found")
    engine = engine.replace(
        session_start,
        r'''        let speakerDriverProcessingSnapshot = try speakerDriverProcessingConfiguration
            .makeRealtimeSnapshot(sampleRate: output.nominalSampleRate)
        let session = try CoreAudioTransportSession(
''',
        1,
    )
    engine = engine.replace(
        session_arg_anchor,
        "            speakerBusSplitterSnapshot: speakerBusSplitterSnapshot,\n            speakerDriverProcessingSnapshot: speakerDriverProcessingSnapshot\n        )",
        1,
    )
engine_path.write_text(engine, encoding="utf-8")

# -----------------------------------------------------------------------------
# Deterministic standalone C runtime validation.
# -----------------------------------------------------------------------------
validator_c = root / "ci" / "validate_pr43_driver_runtime.c"
validator_c.write_text(r'''#include <assert.h>
#include <math.h>
#include <stdio.h>

#include "../NotchSixty/Audio/Realtime/N60SpeakerDriverProcessing.h"

static int close_enough(float a, float b) {
    return fabsf(a - b) < 1.0e-5f;
}

int main(void) {
    N60SpeakerDriverProcessingSnapshot snapshot =
        N60SpeakerDriverProcessingSnapshotMakeBypassed();

    // Trim/polarity are bus-local and deterministic.
    assert(N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 2u, true, NULL, 0u, 0.5f, true,
        0u, 0.0f, false, 1.0f, 0.99f
    ));
    N60SpeakerDriverProcessingRuntime runtime;
    assert(N60SpeakerDriverProcessingRuntimeConfigure(&runtime, snapshot));
    float values[N60_SPEAKER_DRIVER_BUS_COUNT] = {0};
    values[2] = 1.0f;
    N60SpeakerDriverProcessingRuntimeProcessValues(&runtime, values);
    assert(close_enough(values[2], -0.5f));

    // Exact integer delay uses only preallocated memory.
    snapshot = N60SpeakerDriverProcessingSnapshotMakeBypassed();
    assert(N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 3u, true, NULL, 0u, 1.0f, false,
        2u, 0.0f, false, 1.0f, 0.99f
    ));
    assert(N60SpeakerDriverProcessingRuntimeConfigure(&runtime, snapshot));
    for (int n = 0; n < 3; ++n) {
        for (uint32_t i = 0; i < N60_SPEAKER_DRIVER_BUS_COUNT; ++i) values[i] = 0.0f;
        values[3] = n == 0 ? 1.0f : 0.0f;
        N60SpeakerDriverProcessingRuntimeProcessValues(&runtime, values);
        if (n < 2) assert(close_enough(values[3], 0.0f));
        else assert(close_enough(values[3], 1.0f));
    }

    // Limiter is instantaneous on attack and cannot emit above threshold.
    snapshot = N60SpeakerDriverProcessingSnapshotMakeBypassed();
    assert(N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 4u, true, NULL, 0u, 1.0f, false,
        0u, 0.0f, true, 0.25f, 0.99f
    ));
    assert(N60SpeakerDriverProcessingRuntimeConfigure(&runtime, snapshot));
    for (uint32_t i = 0; i < N60_SPEAKER_DRIVER_BUS_COUNT; ++i) values[i] = 0.0f;
    values[4] = 1.0f;
    N60SpeakerDriverProcessingRuntimeProcessValues(&runtime, values);
    assert(values[4] <= 0.25001f);

    // Delay capacity is fail-closed.
    snapshot = N60SpeakerDriverProcessingSnapshotMakeBypassed();
    assert(!N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 5u, true, NULL, 0u, 1.0f, false,
        N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES, 0.0f, false, 1.0f, 0.99f
    ));

    puts("PR43 per-driver realtime runtime: PASS");
    return 0;
}
''', encoding="utf-8")

validator_py = root / "ci" / "validate_pr43_driver_runtime.py"
validator_py.write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "NotchSixty" / "Audio" / "Realtime" / "N60SpeakerDriverProcessing.h").read_text()
BRIDGE = (ROOT / "NotchSixty" / "Audio" / "Realtime" / "N60RealtimeAudioBridge.c").read_text()
ROUTE = (ROOT / "NotchSixty" / "Audio" / "Routing" / "AudioRouteConfiguration.swift").read_text()
CORE = (ROOT / "NotchSixty" / "Audio" / "CoreAudio" / "CoreAudioError.swift").read_text()
ENGINE = (ROOT / "NotchSixty" / "Audio" / "AudioIOEngine.swift").read_text()


def fail(message: str) -> None:
    print(f"PR43 driver-runtime validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

for token in [
    "N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS 8u",
    "N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES 19201u",
    "N60SpeakerDriverProcessingRuntimeProcessValues",
    "fractionalAllPassCoefficient",
    "limiterReleaseCoefficient",
]:
    if token not in HEADER:
        fail(f"missing fixed-runtime token: {token}")
if "process_speaker_bus_splitter" not in BRIDGE or "N60SpeakerDriverProcessingRuntimeProcessValues" not in BRIDGE:
    fail("bridge does not contain splitter then driver processing")
if BRIDGE.index("process_speaker_bus_splitter") > BRIDGE.rindex("N60SpeakerDriverProcessingRuntimeProcessValues"):
    fail("driver processing is not downstream of mandatory speaker splitting")
for forbidden in ["malloc(", "calloc(", "realloc(", "free("]:
    process_tail = HEADER.split("N60SpeakerDriverProcessingRuntimeProcessValues", 1)[1]
    if forbidden in process_tail:
        fail(f"realtime driver processor contains forbidden allocation token {forbidden}")
for token in [
    "makeRealtimeSnapshot(sampleRate: Double)",
    "compiledSections(sampleRate: sampleRate)",
    "realtimeDriverIndex",
]:
    if token not in ROUTE:
        fail(f"missing Swift compile token: {token}")
for token in [
    "speakerDriverProcessingSnapshot: N60SpeakerDriverProcessingSnapshot?",
    "N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing",
]:
    if token not in CORE:
        fail(f"missing transport configuration token: {token}")
if "speakerDriverProcessingSnapshot: speakerDriverProcessingSnapshot" not in ENGINE:
    fail("AudioIOEngine does not pass the immutable driver snapshot to transport")
print("PR43 per-driver realtime architecture guard: PASS")
''', encoding="utf-8")
validator_py.chmod(0o755)

print("PR43 B2 realtime per-driver processing patch applied")
