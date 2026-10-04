#ifndef N60LiveNChannelRenderCore_h
#define N60LiveNChannelRenderCore_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60MultichannelBassManagement.h"
#include "N60ProgramLaneEngine.h"
#include "N60ProgramTransportCore.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_LIVE_MAX_PHYSICAL_CHANNELS 32u
#define N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED UINT32_MAX

typedef struct {
    bool valid;
    uint32_t physicalChannelCount;
    N60ProgramChannelLayout programLayout;
    bool bassManagementEnabled;
    uint32_t subwooferCount;
    uint32_t physicalChannelForProgram[N60_MAX_PROGRAM_CHANNELS];
    uint32_t physicalChannelForSubwoofer[N60_MAX_SUBWOOFER_OUTPUTS];
} N60LiveNChannelOutputMap;

typedef struct {
    double sampleRate;
    N60ProgramChannelLayout programLayout;
    N60ProgramLaneGraphSnapshot laneGraph;
    bool bassManagementEnabled;
    N60MultichannelBassManagementSnapshot bassManagement;
    N60LiveNChannelOutputMap outputMap;
} N60LiveNChannelRenderGraph;

typedef struct {
    uint32_t physicalChannelCount;
    float values[N60_LIVE_MAX_PHYSICAL_CHANNELS];
} N60LiveNChannelPhysicalFrame;

typedef struct N60LiveNChannelRenderRuntime {
    N60ProgramLaneRuntime * _Nullable laneRuntime;
    N60MultichannelBassManagementRuntime * _Nullable bassRuntime;
    N60ProgramChannelLayout preparedLayout;
    bool preparedBassManagement;
    bool prepared;
} N60LiveNChannelRenderRuntime;

static inline bool N60LiveNChannelLayoutsEqual(
    const N60ProgramChannelLayout * _Nullable lhs,
    const N60ProgramChannelLayout * _Nullable rhs
) {
    return N60ProgramChannelLayoutsEqual(lhs, rhs);
}

/// Compile the final program/sub -> physical-device map.
///
/// With bass management disabled every semantic program lane, including LFE,
/// must map to one unique physical channel and `subwooferCount` must be zero.
/// With bass management enabled the semantic LFE program lane MUST be unmapped:
/// PR55 consumes it into the explicit LFE->Sub routing matrix. Every non-LFE
/// speaker and every physical Sub N destination must map uniquely instead.
static inline bool N60LiveNChannelOutputMapCompile(
    N60ProgramChannelLayout programLayout,
    uint32_t physicalChannelCount,
    const uint32_t * _Nonnull physicalChannelForProgram,
    bool bassManagementEnabled,
    uint32_t subwooferCount,
    const uint32_t * _Nullable physicalChannelForSubwoofer,
    N60LiveNChannelOutputMap * _Nonnull mapOut
) {
    if (mapOut == NULL
        || physicalChannelForProgram == NULL
        || !N60ProgramChannelLayoutIsValid(&programLayout)
        || physicalChannelCount == 0u
        || physicalChannelCount > N60_LIVE_MAX_PHYSICAL_CHANNELS
        || subwooferCount > N60_MAX_SUBWOOFER_OUTPUTS) {
        return false;
    }
    if (bassManagementEnabled) {
        if (subwooferCount == 0u || physicalChannelForSubwoofer == NULL) return false;
    } else if (subwooferCount != 0u) {
        return false;
    }

    N60LiveNChannelOutputMap result = {0};
    result.physicalChannelCount = physicalChannelCount;
    result.programLayout = programLayout;
    result.bassManagementEnabled = bassManagementEnabled;
    result.subwooferCount = subwooferCount;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        result.physicalChannelForProgram[channel] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    for (uint32_t sub = 0; sub < N60_MAX_SUBWOOFER_OUTPUTS; ++sub) {
        result.physicalChannelForSubwoofer[sub] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }

    bool used[N60_LIVE_MAX_PHYSICAL_CHANNELS] = {false};
    for (uint32_t program = 0; program < programLayout.channelCount; ++program) {
        const N60ProgramChannelRole role = programLayout.channels[program];
        const uint32_t physical = physicalChannelForProgram[program];
        if (bassManagementEnabled && role == N60ProgramChannelRoleLowFrequencyEffects) {
            if (physical != N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED) return false;
            continue;
        }
        if (physical == N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED
            || physical >= physicalChannelCount
            || used[physical]) {
            return false;
        }
        used[physical] = true;
        result.physicalChannelForProgram[program] = physical;
    }

    if (bassManagementEnabled) {
        for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
            const uint32_t physical = physicalChannelForSubwoofer[sub];
            if (physical == N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED
                || physical >= physicalChannelCount
                || used[physical]) {
                return false;
            }
            used[physical] = true;
            result.physicalChannelForSubwoofer[sub] = physical;
        }
    }

    result.valid = true;
    *mapOut = result;
    return true;
}

static inline bool N60LiveNChannelOutputMapIsValid(
    const N60LiveNChannelOutputMap * _Nullable map
) {
    if (map == NULL || !map->valid) return false;
    N60LiveNChannelOutputMap copy = {0};
    return N60LiveNChannelOutputMapCompile(
        map->programLayout,
        map->physicalChannelCount,
        map->physicalChannelForProgram,
        map->bassManagementEnabled,
        map->subwooferCount,
        map->bassManagementEnabled ? map->physicalChannelForSubwoofer : NULL,
        &copy
    );
}

static inline bool N60LiveNChannelRenderGraphIsValid(
    const N60LiveNChannelRenderGraph * _Nullable graph
) {
    if (graph == NULL
        || !isfinite(graph->sampleRate)
        || graph->sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&graph->programLayout)
        || !N60ProgramLaneGraphIsValid(&graph->laneGraph)
        || !N60LiveNChannelOutputMapIsValid(&graph->outputMap)
        || fabs(graph->laneGraph.sampleRate - graph->sampleRate) >= 0.5
        || !N60LiveNChannelLayoutsEqual(&graph->programLayout, &graph->laneGraph.layout)
        || !N60LiveNChannelLayoutsEqual(&graph->programLayout, &graph->outputMap.programLayout)
        || graph->bassManagementEnabled != graph->outputMap.bassManagementEnabled) {
        return false;
    }

    if (!graph->bassManagementEnabled) {
        return graph->outputMap.subwooferCount == 0u;
    }

    return N60MultichannelBassManagementSnapshotIsValid(&graph->bassManagement)
        && fabs(graph->bassManagement.sampleRate - graph->sampleRate) < 0.5
        && N60LiveNChannelLayoutsEqual(
            &graph->programLayout,
            &graph->bassManagement.programLayout
        )
        && graph->bassManagement.subwooferCount == graph->outputMap.subwooferCount;
}

static inline bool N60LiveNChannelRenderGraphMake(
    double sampleRate,
    N60ProgramChannelLayout programLayout,
    N60ProgramLaneGraphSnapshot laneGraph,
    bool bassManagementEnabled,
    N60MultichannelBassManagementSnapshot bassManagement,
    N60LiveNChannelOutputMap outputMap,
    N60LiveNChannelRenderGraph * _Nonnull graphOut
) {
    if (graphOut == NULL) return false;
    N60LiveNChannelRenderGraph graph = {
        .sampleRate = sampleRate,
        .programLayout = programLayout,
        .laneGraph = laneGraph,
        .bassManagementEnabled = bassManagementEnabled,
        .bassManagement = bassManagement,
        .outputMap = outputMap,
    };
    if (!N60LiveNChannelRenderGraphIsValid(&graph)) return false;
    *graphOut = graph;
    return true;
}

static inline N60LiveNChannelRenderRuntime * _Nullable N60LiveNChannelRenderRuntimeCreate(void) {
    N60LiveNChannelRenderRuntime * _Nullable runtime =
        (N60LiveNChannelRenderRuntime *)calloc(1u, sizeof(N60LiveNChannelRenderRuntime));
    if (runtime == NULL) return NULL;
    runtime->laneRuntime = N60ProgramLaneRuntimeCreate();
    runtime->bassRuntime = N60MultichannelBassManagementRuntimeCreate();
    if (runtime->laneRuntime == NULL || runtime->bassRuntime == NULL) {
        N60ProgramLaneRuntimeDestroy(runtime->laneRuntime);
        N60MultichannelBassManagementRuntimeDestroy(runtime->bassRuntime);
        free(runtime);
        return NULL;
    }
    return runtime;
}

static inline void N60LiveNChannelRenderRuntimeDestroy(
    N60LiveNChannelRenderRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    N60ProgramLaneRuntimeDestroy(runtime->laneRuntime);
    N60MultichannelBassManagementRuntimeDestroy(runtime->bassRuntime);
    runtime->laneRuntime = NULL;
    runtime->bassRuntime = NULL;
    free(runtime);
}

/// Control-plane preparation only. Live graph changes intentionally require the
/// opt-in N-channel session to stop/reprepare in PR61; the shipping stereo graph
/// publication path remains untouched.
static inline bool N60LiveNChannelRenderRuntimePrepare(
    N60LiveNChannelRenderRuntime * _Nonnull runtime,
    const N60LiveNChannelRenderGraph * _Nonnull graph
) {
    if (runtime == NULL
        || graph == NULL
        || runtime->laneRuntime == NULL
        || runtime->bassRuntime == NULL
        || !N60LiveNChannelRenderGraphIsValid(graph)
        || !N60ProgramLaneRuntimePrepare(runtime->laneRuntime, &graph->laneGraph)) {
        return false;
    }
    if (graph->bassManagementEnabled
        && !N60MultichannelBassManagementRuntimePrepare(
            runtime->bassRuntime,
            &graph->bassManagement)) {
        return false;
    }
    runtime->preparedLayout = graph->programLayout;
    runtime->preparedBassManagement = graph->bassManagementEnabled;
    runtime->prepared = true;
    return true;
}

static inline bool N60LiveNChannelRenderRuntimeIsPrepared(
    const N60LiveNChannelRenderRuntime * _Nullable runtime,
    const N60LiveNChannelRenderGraph * _Nullable graph
) {
    return runtime != NULL
        && graph != NULL
        && runtime->prepared
        && runtime->preparedBassManagement == graph->bassManagementEnabled
        && N60LiveNChannelLayoutsEqual(&runtime->preparedLayout, &graph->programLayout)
        && N60ProgramLaneRuntimeIsPreparedForGraph(runtime->laneRuntime, &graph->laneGraph)
        && (!graph->bassManagementEnabled
            || N60MultichannelBassManagementRuntimeIsPreparedForSnapshot(
                runtime->bassRuntime,
                &graph->bassManagement));
}

/// Realtime composite: semantic program frame -> PR54 channel lanes -> optional
/// PR55 bass management -> explicit physical device frame. Program LFE and Sub N
/// remain different domains throughout. No allocation, locking, logging or I/O.
static inline bool N60LiveNChannelRenderProcessFrame(
    N60LiveNChannelRenderRuntime * _Nonnull runtime,
    const N60LiveNChannelRenderGraph * _Nonnull graph,
    const N60ProgramTransportFrame * _Nonnull input,
    N60LiveNChannelPhysicalFrame * _Nonnull physicalOutput,
    N60ProgramLaneMeterAccumulator * _Nullable laneMeter
) {
    if (runtime == NULL
        || graph == NULL
        || input == NULL
        || physicalOutput == NULL
        || !N60LiveNChannelRenderRuntimeIsPrepared(runtime, graph)) {
        return false;
    }

    float laneOutput[N60_MAX_PROGRAM_CHANNELS] = {0};
    if (!N60ProgramLaneProcessFrame(
            runtime->laneRuntime,
            &graph->laneGraph,
            input->channels,
            laneOutput,
            laneMeter)) {
        return false;
    }

    float speakerOutput[N60_MAX_PROGRAM_CHANNELS] = {0};
    float subwooferOutput[N60_MAX_SUBWOOFER_OUTPUTS] = {0};
    if (graph->bassManagementEnabled) {
        if (!N60MultichannelBassManagementProcessFrame(
                runtime->bassRuntime,
                &graph->bassManagement,
                laneOutput,
                speakerOutput,
                subwooferOutput)) {
            return false;
        }
    } else {
        memcpy(
            speakerOutput,
            laneOutput,
            graph->programLayout.channelCount * sizeof(float)
        );
    }

    N60LiveNChannelPhysicalFrame result = {0};
    result.physicalChannelCount = graph->outputMap.physicalChannelCount;
    for (uint32_t program = 0; program < graph->programLayout.channelCount; ++program) {
        const uint32_t physical = graph->outputMap.physicalChannelForProgram[program];
        if (physical == N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED) continue;
        if (physical >= result.physicalChannelCount) return false;
        const float value = speakerOutput[program];
        result.values[physical] = isfinite(value) ? value : 0.0f;
    }
    if (graph->bassManagementEnabled) {
        for (uint32_t sub = 0; sub < graph->outputMap.subwooferCount; ++sub) {
            const uint32_t physical = graph->outputMap.physicalChannelForSubwoofer[sub];
            if (physical == N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED
                || physical >= result.physicalChannelCount) {
                return false;
            }
            const float value = subwooferOutput[sub];
            result.values[physical] = isfinite(value) ? value : 0.0f;
        }
    }
    *physicalOutput = result;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
