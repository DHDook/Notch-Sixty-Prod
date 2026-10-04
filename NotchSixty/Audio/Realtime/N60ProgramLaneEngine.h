#ifndef N60ProgramLaneEngine_h
#define N60ProgramLaneEngine_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60Biquad.h"
#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_PROGRAM_LANE_MAX_EQ_SECTIONS 16u
#define N60_PROGRAM_LANE_DELAY_CAPACITY_FRAMES 65536u
#define N60_PROGRAM_LANE_MAX_DELAY_FRAMES (N60_PROGRAM_LANE_DELAY_CAPACITY_FRAMES - 1u)

typedef struct {
    bool muted;
    bool polarityInverted;
    float gainLinear;
    uint32_t userDelayFrames;
    /// Latency already incurred by channel-specific processing immediately
    /// upstream of this lane stage (for example a future per-channel FIR).
    /// Finalization adds compensating delay to faster lanes.
    uint32_t upstreamProcessingLatencyFrames;
    uint32_t eqSectionCount;
    N60BiquadBandSnapshot eqSections[N60_PROGRAM_LANE_MAX_EQ_SECTIONS];
} N60ProgramLaneSnapshot;

typedef struct {
    double sampleRate;
    N60ProgramChannelLayout layout;
    uint32_t coherenceLatencyFrames;
    N60ProgramLaneSnapshot lanes[N60_MAX_PROGRAM_CHANNELS];
} N60ProgramLaneGraphSnapshot;

typedef struct {
    uint16_t channelMask;
} N60ProgramChannelGroup;

typedef struct {
    uint32_t channelCount;
    uint64_t frames;
    float peak[N60_MAX_PROGRAM_CHANNELS];
    double squareSum[N60_MAX_PROGRAM_CHANNELS];
    uint64_t overRangeSamples[N60_MAX_PROGRAM_CHANNELS];
} N60ProgramLaneMeterAccumulator;

typedef struct {
    uint32_t channelCount;
    float peak[N60_MAX_PROGRAM_CHANNELS];
    float rms[N60_MAX_PROGRAM_CHANNELS];
    uint64_t overRangeSamples[N60_MAX_PROGRAM_CHANNELS];
} N60ProgramLaneMeterReading;

typedef struct N60ProgramLaneRuntime {
    N60BiquadState eqStates[N60_MAX_PROGRAM_CHANNELS][N60_PROGRAM_LANE_MAX_EQ_SECTIONS];
    float *delayBuffers[N60_MAX_PROGRAM_CHANNELS];
    uint32_t delayWriteIndex;
    N60ProgramChannelLayout preparedLayout;
    bool prepared;
} N60ProgramLaneRuntime;

static inline bool N60ProgramChannelLayoutsEqual(
    const N60ProgramChannelLayout * _Nullable lhs,
    const N60ProgramChannelLayout * _Nullable rhs
) {
    if (lhs == NULL || rhs == NULL || lhs->channelCount != rhs->channelCount) return false;
    for (uint32_t index = 0; index < lhs->channelCount; ++index) {
        if (lhs->channels[index] != rhs->channels[index]) return false;
    }
    return true;
}

static inline N60ProgramLaneGraphSnapshot N60ProgramLaneGraphSnapshotMakeUnity(
    double sampleRate,
    N60ProgramChannelLayout layout
) {
    N60ProgramLaneGraphSnapshot graph = {0};
    if (!isfinite(sampleRate) || sampleRate <= 0.0 || !N60ProgramChannelLayoutIsValid(&layout)) {
        return graph;
    }
    graph.sampleRate = sampleRate;
    graph.layout = layout;
    for (uint32_t channel = 0; channel < layout.channelCount; ++channel) {
        graph.lanes[channel].gainLinear = 1.0f;
    }
    return graph;
}

static inline bool N60ProgramLaneGraphSetGain(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex,
    float gainLinear
) {
    if (graph == NULL
        || channelIndex >= graph->layout.channelCount
        || !isfinite(gainLinear)
        || gainLinear < 0.0f
        || gainLinear > 16.0f) {
        return false;
    }
    graph->lanes[channelIndex].gainLinear = gainLinear;
    return true;
}

static inline bool N60ProgramLaneGraphSetMute(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex,
    bool muted
) {
    if (graph == NULL || channelIndex >= graph->layout.channelCount) return false;
    graph->lanes[channelIndex].muted = muted;
    return true;
}

static inline bool N60ProgramLaneGraphSetPolarityInverted(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex,
    bool inverted
) {
    if (graph == NULL || channelIndex >= graph->layout.channelCount) return false;
    graph->lanes[channelIndex].polarityInverted = inverted;
    return true;
}

static inline bool N60ProgramLaneGraphSetDelayFrames(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex,
    uint32_t delayFrames
) {
    if (graph == NULL
        || channelIndex >= graph->layout.channelCount
        || delayFrames > N60_PROGRAM_LANE_MAX_DELAY_FRAMES) {
        return false;
    }
    graph->lanes[channelIndex].userDelayFrames = delayFrames;
    return true;
}

static inline bool N60ProgramLaneGraphSetDelayMs(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex,
    double delayMs
) {
    if (graph == NULL
        || !isfinite(graph->sampleRate)
        || graph->sampleRate <= 0.0
        || !isfinite(delayMs)
        || delayMs < 0.0) {
        return false;
    }
    const double frames = graph->sampleRate * delayMs * 0.001;
    if (!isfinite(frames) || frames > (double)N60_PROGRAM_LANE_MAX_DELAY_FRAMES) return false;
    return N60ProgramLaneGraphSetDelayFrames(graph, channelIndex, (uint32_t)llround(frames));
}

static inline bool N60ProgramLaneGraphSetUpstreamProcessingLatency(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex,
    uint32_t latencyFrames
) {
    if (graph == NULL
        || channelIndex >= graph->layout.channelCount
        || latencyFrames > N60_PROGRAM_LANE_MAX_DELAY_FRAMES) {
        return false;
    }
    graph->lanes[channelIndex].upstreamProcessingLatencyFrames = latencyFrames;
    return true;
}

static inline bool N60ProgramLaneGraphSetEQBand(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
) {
    if (graph == NULL
        || channelIndex >= graph->layout.channelCount
        || bandIndex >= N60_PROGRAM_LANE_MAX_EQ_SECTIONS) {
        return false;
    }
    N60BiquadBandSnapshot band = {0};
    if (!N60BiquadBandSnapshotMake(
            type,
            graph->sampleRate,
            frequencyHz,
            gainDB,
            q,
            enabled,
            &band)) {
        return false;
    }
    graph->lanes[channelIndex].eqSections[bandIndex] = band;
    if (graph->lanes[channelIndex].eqSectionCount <= bandIndex) {
        graph->lanes[channelIndex].eqSectionCount = bandIndex + 1u;
    }
    return true;
}

static inline bool N60ProgramLaneGraphFinalize(
    N60ProgramLaneGraphSnapshot * _Nonnull graph
) {
    if (graph == NULL
        || !isfinite(graph->sampleRate)
        || graph->sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&graph->layout)) {
        return false;
    }

    uint32_t coherenceLatency = 0u;
    for (uint32_t channel = 0; channel < graph->layout.channelCount; ++channel) {
        N60ProgramLaneSnapshot *lane = &graph->lanes[channel];
        if (!isfinite(lane->gainLinear)
            || lane->gainLinear < 0.0f
            || lane->gainLinear > 16.0f
            || lane->userDelayFrames > N60_PROGRAM_LANE_MAX_DELAY_FRAMES
            || lane->upstreamProcessingLatencyFrames > N60_PROGRAM_LANE_MAX_DELAY_FRAMES
            || lane->eqSectionCount > N60_PROGRAM_LANE_MAX_EQ_SECTIONS) {
            return false;
        }
        if (lane->upstreamProcessingLatencyFrames > coherenceLatency) {
            coherenceLatency = lane->upstreamProcessingLatencyFrames;
        }
        for (uint32_t section = 0; section < lane->eqSectionCount; ++section) {
            const N60BiquadBandSnapshot band = lane->eqSections[section];
            if (band.enabled && !N60BiquadCoefficientsAreFinite(band.coefficients)) return false;
        }
    }

    for (uint32_t channel = 0; channel < graph->layout.channelCount; ++channel) {
        const N60ProgramLaneSnapshot lane = graph->lanes[channel];
        const uint32_t compensation = coherenceLatency - lane.upstreamProcessingLatencyFrames;
        if (lane.userDelayFrames > N60_PROGRAM_LANE_MAX_DELAY_FRAMES - compensation) {
            return false;
        }
    }

    graph->coherenceLatencyFrames = coherenceLatency;
    return true;
}

static inline bool N60ProgramLaneGraphIsValid(
    const N60ProgramLaneGraphSnapshot * _Nullable graph
) {
    if (graph == NULL) return false;
    N60ProgramLaneGraphSnapshot copy = *graph;
    if (!N60ProgramLaneGraphFinalize(&copy)) return false;
    return copy.coherenceLatencyFrames == graph->coherenceLatencyFrames;
}

static inline uint32_t N60ProgramLaneGraphEffectiveDelayFrames(
    const N60ProgramLaneGraphSnapshot * _Nonnull graph,
    uint32_t channelIndex
) {
    if (graph == NULL || channelIndex >= graph->layout.channelCount) return 0u;
    const N60ProgramLaneSnapshot lane = graph->lanes[channelIndex];
    return lane.userDelayFrames
        + (graph->coherenceLatencyFrames - lane.upstreamProcessingLatencyFrames);
}

static inline bool N60ProgramChannelGroupMake(
    const N60ProgramChannelLayout * _Nonnull layout,
    const N60ProgramChannelRole * _Nonnull roles,
    uint32_t roleCount,
    N60ProgramChannelGroup * _Nonnull groupOut
) {
    if (layout == NULL
        || roles == NULL
        || groupOut == NULL
        || !N60ProgramChannelLayoutIsValid(layout)
        || roleCount == 0u
        || roleCount > layout->channelCount) {
        return false;
    }

    uint16_t mask = 0u;
    for (uint32_t roleIndex = 0; roleIndex < roleCount; ++roleIndex) {
        const int32_t channel = N60ProgramChannelLayoutIndexOfRole(layout, roles[roleIndex]);
        if (channel < 0) return false;
        const uint16_t bit = (uint16_t)(1u << (uint32_t)channel);
        if ((mask & bit) != 0u) return false;
        mask |= bit;
    }
    groupOut->channelMask = mask;
    return true;
}

static inline bool N60ProgramChannelGroupContains(
    N60ProgramChannelGroup group,
    uint32_t channelIndex
) {
    return channelIndex < N60_MAX_PROGRAM_CHANNELS
        && (group.channelMask & (uint16_t)(1u << channelIndex)) != 0u;
}

static inline bool N60ProgramLaneGraphSetGroupGain(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    N60ProgramChannelGroup group,
    float gainLinear
) {
    if (graph == NULL || group.channelMask == 0u) return false;
    for (uint32_t channel = 0; channel < graph->layout.channelCount; ++channel) {
        if (N60ProgramChannelGroupContains(group, channel)
            && !N60ProgramLaneGraphSetGain(graph, channel, gainLinear)) {
            return false;
        }
    }
    return true;
}

static inline bool N60ProgramLaneGraphSetGroupMute(
    N60ProgramLaneGraphSnapshot * _Nonnull graph,
    N60ProgramChannelGroup group,
    bool muted
) {
    if (graph == NULL || group.channelMask == 0u) return false;
    for (uint32_t channel = 0; channel < graph->layout.channelCount; ++channel) {
        if (N60ProgramChannelGroupContains(group, channel)) {
            graph->lanes[channel].muted = muted;
        }
    }
    return true;
}

static inline N60ProgramLaneRuntime * _Nullable N60ProgramLaneRuntimeCreate(void) {
    N60ProgramLaneRuntime *runtime = (N60ProgramLaneRuntime *)calloc(1u, sizeof(N60ProgramLaneRuntime));
    if (runtime == NULL) return NULL;

    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        runtime->delayBuffers[channel] = (float *)calloc(
            N60_PROGRAM_LANE_DELAY_CAPACITY_FRAMES,
            sizeof(float)
        );
        if (runtime->delayBuffers[channel] == NULL) {
            for (uint32_t cleanup = 0; cleanup < channel; ++cleanup) {
                free(runtime->delayBuffers[cleanup]);
            }
            free(runtime);
            return NULL;
        }
    }
    return runtime;
}

static inline void N60ProgramLaneRuntimeDestroy(
    N60ProgramLaneRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        free(runtime->delayBuffers[channel]);
        runtime->delayBuffers[channel] = NULL;
    }
    free(runtime);
}

/// Control-plane reset/preparation. This clears delay and EQ history and must not
/// be called from the realtime callback.
static inline bool N60ProgramLaneRuntimePrepare(
    N60ProgramLaneRuntime * _Nonnull runtime,
    const N60ProgramLaneGraphSnapshot * _Nonnull graph
) {
    if (runtime == NULL || graph == NULL || !N60ProgramLaneGraphIsValid(graph)) return false;
    memset(runtime->eqStates, 0, sizeof(runtime->eqStates));
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        if (runtime->delayBuffers[channel] == NULL) return false;
        memset(
            runtime->delayBuffers[channel],
            0,
            N60_PROGRAM_LANE_DELAY_CAPACITY_FRAMES * sizeof(float)
        );
    }
    runtime->delayWriteIndex = 0u;
    runtime->preparedLayout = graph->layout;
    runtime->prepared = true;
    return true;
}

static inline bool N60ProgramLaneRuntimeIsPreparedForGraph(
    const N60ProgramLaneRuntime * _Nullable runtime,
    const N60ProgramLaneGraphSnapshot * _Nullable graph
) {
    return runtime != NULL
        && graph != NULL
        && runtime->prepared
        && N60ProgramChannelLayoutsEqual(&runtime->preparedLayout, &graph->layout);
}

static inline void N60ProgramLaneMeterAccumulatorReset(
    N60ProgramLaneMeterAccumulator * _Nonnull meter,
    uint32_t channelCount
) {
    if (meter == NULL) return;
    memset(meter, 0, sizeof(*meter));
    meter->channelCount = channelCount <= N60_MAX_PROGRAM_CHANNELS ? channelCount : 0u;
}

static inline void N60ProgramLaneMeterAccumulatorAccumulate(
    N60ProgramLaneMeterAccumulator * _Nullable meter,
    const float * _Nonnull samples,
    uint32_t channelCount
) {
    if (meter == NULL
        || samples == NULL
        || meter->channelCount != channelCount
        || channelCount == 0u
        || channelCount > N60_MAX_PROGRAM_CHANNELS) {
        return;
    }
    for (uint32_t channel = 0; channel < channelCount; ++channel) {
        const float magnitude = fabsf(samples[channel]);
        if (magnitude > meter->peak[channel]) meter->peak[channel] = magnitude;
        meter->squareSum[channel] += (double)samples[channel] * (double)samples[channel];
        if (magnitude > 1.0f) meter->overRangeSamples[channel] += 1u;
    }
    meter->frames += 1u;
}

static inline N60ProgramLaneMeterReading N60ProgramLaneMeterAccumulatorReading(
    const N60ProgramLaneMeterAccumulator * _Nullable meter
) {
    N60ProgramLaneMeterReading reading = {0};
    if (meter == NULL || meter->channelCount == 0u || meter->channelCount > N60_MAX_PROGRAM_CHANNELS) {
        return reading;
    }
    reading.channelCount = meter->channelCount;
    for (uint32_t channel = 0; channel < meter->channelCount; ++channel) {
        reading.peak[channel] = meter->peak[channel];
        reading.rms[channel] = meter->frames > 0u
            ? (float)sqrt(meter->squareSum[channel] / (double)meter->frames)
            : 0.0f;
        reading.overRangeSamples[channel] = meter->overRangeSamples[channel];
    }
    return reading;
}

/// Realtime primitive. `input` and `output` must each provide at least
/// graph->layout.channelCount samples. Graph construction/finalization and
/// runtime preparation happen off the callback.
static inline bool N60ProgramLaneProcessFrame(
    N60ProgramLaneRuntime * _Nonnull runtime,
    const N60ProgramLaneGraphSnapshot * _Nonnull graph,
    const float * _Nonnull input,
    float * _Nonnull output,
    N60ProgramLaneMeterAccumulator * _Nullable meter
) {
    if (runtime == NULL
        || graph == NULL
        || input == NULL
        || output == NULL
        || !N60ProgramLaneRuntimeIsPreparedForGraph(runtime, graph)) {
        return false;
    }

    const uint32_t channelCount = graph->layout.channelCount;
    const uint32_t writeIndex = runtime->delayWriteIndex;

    for (uint32_t channel = 0; channel < channelCount; ++channel) {
        const N60ProgramLaneSnapshot *lane = &graph->lanes[channel];
        float sample = isfinite(input[channel]) ? input[channel] : 0.0f;
        if (lane->polarityInverted) sample = -sample;
        sample *= lane->gainLinear;

        for (uint32_t section = 0; section < lane->eqSectionCount; ++section) {
            const N60BiquadBandSnapshot band = lane->eqSections[section];
            if (band.enabled) {
                sample = N60BiquadProcessSample(
                    band.coefficients,
                    &runtime->eqStates[channel][section],
                    sample
                );
            }
        }

        runtime->delayBuffers[channel][writeIndex] = sample;
        const uint32_t delayFrames = N60ProgramLaneGraphEffectiveDelayFrames(graph, channel);
        if (delayFrames > 0u) {
            const uint32_t readIndex = (
                writeIndex + N60_PROGRAM_LANE_DELAY_CAPACITY_FRAMES - delayFrames
            ) % N60_PROGRAM_LANE_DELAY_CAPACITY_FRAMES;
            sample = runtime->delayBuffers[channel][readIndex];
        }

        output[channel] = lane->muted ? 0.0f : sample;
    }

    runtime->delayWriteIndex = (writeIndex + 1u) % N60_PROGRAM_LANE_DELAY_CAPACITY_FRAMES;
    N60ProgramLaneMeterAccumulatorAccumulate(meter, output, channelCount);
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
