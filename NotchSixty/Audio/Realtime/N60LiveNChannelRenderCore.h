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
#include "N60ProgramFIRRuntime.h"
#include "N60ProgramTransportCore.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Bounded hardware-output ceiling of the graph path (E8 S4: routed sessions, up to the graph's 64 lanes).
#define N60_LIVE_MAX_PHYSICAL_CHANNELS 64u
/// The legacy per-frame render core and the MIMO treatment keep their original ceiling: 40 leaves room for the full
/// 32-channel semantic program plus four explicit physical subwoofer outputs and margin.
#define N60_LIVE_LEGACY_MAX_PHYSICAL_CHANNELS 40u
#define N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED UINT32_MAX
/// E8 A3: sub lanes the graph path can drive (matches `UnifiedGraphConfiguration.maxSubwoofers`). The legacy kernel
/// stays at `N60_MAX_SUBWOOFER_OUTPUTS` (4, frozen).
#define N60_LIVE_MAX_GRAPH_SUBWOOFERS 8u

typedef struct {
    bool valid;
    uint32_t physicalChannelCount;
    N60ProgramChannelLayout programLayout;
    bool bassManagementEnabled;
    uint32_t subwooferCount;
    uint32_t physicalChannelForProgram[N60_MAX_PROGRAM_CHANNELS];
    uint32_t physicalChannelForSubwoofer[N60_MAX_SUBWOOFER_OUTPUTS];
    /// E8 S4: a routed session. The graph's output lanes (the lanes after the program and sub lanes) each go to one
    /// physical channel; the program and sub entries above are all unmapped. Zero for every other session.
    uint32_t routedLaneCount;
    uint32_t physicalChannelForRoutedLane[N60_LIVE_MAX_PHYSICAL_CHANNELS];
    /// E8 A3: a non-routed graph session with 5 to 8 subs. Graph sub lane i (after the program lanes) goes to
    /// `physicalChannelForGraphSub[i]`. The legacy fields above hold no subs (`bassManagementEnabled` false,
    /// `subwooferCount` 0): the legacy kernel cannot render this map and the bridge silences it without a graph.
    uint32_t graphSubLaneCount;
    uint32_t physicalChannelForGraphSub[N60_LIVE_MAX_GRAPH_SUBWOOFERS];
} N60LiveNChannelOutputMap;

typedef struct {
    double sampleRate;
    N60ProgramChannelLayout programLayout;
    bool programFIREnabled;
    N60ProgramFIRProgramInfo programFIR;
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
    N60ProgramFIRProgram * _Nullable programFIRProgram;
    N60ProgramFIRRuntime * _Nullable programFIRRuntime;
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
        || physicalChannelCount > N60_LIVE_LEGACY_MAX_PHYSICAL_CHANNELS
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

/// E8 S4: the map of a routed session. `physicalChannelForRoutedLane[i]` is the physical channel of output lane i; each
/// is unique and below `physicalChannelCount` (at most 64). Program and sub lanes are unmapped: their audio only reaches
/// the outputs through the graph's ROUTE stage.
static inline bool N60LiveNChannelOutputMapCompileRouted(
    N60ProgramChannelLayout programLayout,
    uint32_t physicalChannelCount,
    uint32_t routedLaneCount,
    const uint32_t * _Nonnull physicalChannelForRoutedLane,
    N60LiveNChannelOutputMap * _Nonnull mapOut
) {
    if (mapOut == NULL
        || physicalChannelForRoutedLane == NULL
        || !N60ProgramChannelLayoutIsValid(&programLayout)
        || physicalChannelCount == 0u
        || physicalChannelCount > N60_LIVE_MAX_PHYSICAL_CHANNELS
        || routedLaneCount == 0u
        || routedLaneCount > physicalChannelCount) {
        return false;
    }
    N60LiveNChannelOutputMap result = {0};
    result.physicalChannelCount = physicalChannelCount;
    result.programLayout = programLayout;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        result.physicalChannelForProgram[channel] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    for (uint32_t sub = 0; sub < N60_MAX_SUBWOOFER_OUTPUTS; ++sub) {
        result.physicalChannelForSubwoofer[sub] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    bool used[N60_LIVE_MAX_PHYSICAL_CHANNELS] = {false};
    result.routedLaneCount = routedLaneCount;
    for (uint32_t lane = 0; lane < routedLaneCount; ++lane) {
        const uint32_t physical = physicalChannelForRoutedLane[lane];
        if (physical >= physicalChannelCount || used[physical]) return false;
        used[physical] = true;
        result.physicalChannelForRoutedLane[lane] = physical;
    }
    result.valid = true;
    *mapOut = result;
    return true;
}

/// E8 A3: the map of a non-routed graph session whose bass management drives 5 to 8 physical subs. Program lanes map
/// as the legacy compile does with bass management on (the semantic LFE lane is unmapped: the graph's bass management
/// consumes it); sub lane i maps to `physicalChannelForSubLane[i]`. Every destination is unique.
static inline bool N60LiveNChannelOutputMapCompileGraphSubs(
    N60ProgramChannelLayout programLayout,
    uint32_t physicalChannelCount,
    const uint32_t * _Nonnull physicalChannelForProgram,
    uint32_t subwooferCount,
    const uint32_t * _Nonnull physicalChannelForSubLane,
    N60LiveNChannelOutputMap * _Nonnull mapOut
) {
    if (mapOut == NULL
        || physicalChannelForProgram == NULL
        || physicalChannelForSubLane == NULL
        || !N60ProgramChannelLayoutIsValid(&programLayout)
        || physicalChannelCount == 0u
        || physicalChannelCount > N60_LIVE_MAX_PHYSICAL_CHANNELS
        || subwooferCount <= N60_MAX_SUBWOOFER_OUTPUTS
        || subwooferCount > N60_LIVE_MAX_GRAPH_SUBWOOFERS) {
        return false;
    }
    N60LiveNChannelOutputMap result = {0};
    result.physicalChannelCount = physicalChannelCount;
    result.programLayout = programLayout;
    result.graphSubLaneCount = subwooferCount;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        result.physicalChannelForProgram[channel] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    for (uint32_t sub = 0; sub < N60_MAX_SUBWOOFER_OUTPUTS; ++sub) {
        result.physicalChannelForSubwoofer[sub] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    for (uint32_t sub = 0; sub < N60_LIVE_MAX_GRAPH_SUBWOOFERS; ++sub) {
        result.physicalChannelForGraphSub[sub] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    }
    bool used[N60_LIVE_MAX_PHYSICAL_CHANNELS] = {false};
    for (uint32_t program = 0; program < programLayout.channelCount; ++program) {
        const uint32_t physical = physicalChannelForProgram[program];
        if (programLayout.channels[program] == N60ProgramChannelRoleLowFrequencyEffects) {
            if (physical != N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED) return false;
            continue;
        }
        if (physical >= physicalChannelCount || used[physical]) return false;
        used[physical] = true;
        result.physicalChannelForProgram[program] = physical;
    }
    for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
        const uint32_t physical = physicalChannelForSubLane[sub];
        if (physical >= physicalChannelCount || used[physical]) return false;
        used[physical] = true;
        result.physicalChannelForGraphSub[sub] = physical;
    }
    result.valid = true;
    *mapOut = result;
    return true;
}

static inline bool N60LiveNChannelOutputMapIsValid(
    const N60LiveNChannelOutputMap * _Nullable map
) {
    if (map == NULL || !map->valid) return false;
    if (map->routedLaneCount > 0u) {
        N60LiveNChannelOutputMap routed = {0};
        return !map->bassManagementEnabled
            && map->subwooferCount == 0u
            && N60LiveNChannelOutputMapCompileRouted(
                map->programLayout, map->physicalChannelCount, map->routedLaneCount,
                map->physicalChannelForRoutedLane, &routed);
    }
    if (map->graphSubLaneCount > 0u) {
        N60LiveNChannelOutputMap lanes = {0};
        return !map->bassManagementEnabled
            && map->subwooferCount == 0u
            && N60LiveNChannelOutputMapCompileGraphSubs(
                map->programLayout, map->physicalChannelCount, map->physicalChannelForProgram,
                map->graphSubLaneCount, map->physicalChannelForGraphSub, &lanes);
    }
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

static inline bool N60LiveNChannelProgramFIRGraphStateIsValid(
    const N60LiveNChannelRenderGraph * _Nullable graph
) {
    if (graph == NULL) return false;
    if (!graph->programFIREnabled) {
        return !graph->programFIR.prepared
            && graph->programFIR.activeChannelMask == 0u;
    }

    const N60ProgramFIRProgramInfo info = graph->programFIR;
    if (!N60ProgramFIRProgramInfoIsValid(info)
        || info.channelCount != graph->programLayout.channelCount) {
        return false;
    }

    const uint64_t upstream64 =
        (uint64_t)info.engineLatencyFrames
        + (uint64_t)info.declaredLatencyFrames;
    if (upstream64 > N60_PROGRAM_LANE_MAX_DELAY_FRAMES) {
        return false;
    }
    const uint32_t upstream = (uint32_t)upstream64;

    for (uint32_t channel = 0u;
         channel < graph->programLayout.channelCount;
         ++channel) {
        const bool active =
            (info.activeChannelMask & (1u << channel)) != 0u;
        if (active
            && graph->programLayout.channels[channel]
                == N60ProgramChannelRoleLowFrequencyEffects) {
            return false;
        }
        const uint32_t expected = active ? upstream : 0u;
        if (graph->laneGraph.lanes[channel]
                .upstreamProcessingLatencyFrames != expected) {
            return false;
        }
    }
    return true;
}

/// Control-plane only. Binds prepared FIR metadata to the render graph and
/// programs the already-existing lane coherence contract. Taps/runtime state
/// are configured separately before callbacks start.
static inline bool N60LiveNChannelRenderGraphSetProgramFIRInfo(
    N60LiveNChannelRenderGraph * _Nonnull graph,
    N60ProgramFIRProgramInfo info,
    bool enabled
) {
    if (graph == NULL
        || !N60ProgramChannelLayoutIsValid(&graph->programLayout)) {
        return false;
    }

    N60LiveNChannelRenderGraph candidate = *graph;
    N60ProgramLaneGraphSnapshot lanes = candidate.laneGraph;

    if (!enabled) {
        for (uint32_t channel = 0u;
             channel < candidate.programLayout.channelCount;
             ++channel) {
            if (!N60ProgramLaneGraphSetUpstreamProcessingLatency(
                    &lanes, channel, 0u)) {
                return false;
            }
        }
        if (!N60ProgramLaneGraphFinalize(&lanes)) return false;
        candidate.programFIREnabled = false;
        candidate.programFIR = (N60ProgramFIRProgramInfo){0};
        candidate.laneGraph = lanes;
        if (!N60LiveNChannelProgramFIRGraphStateIsValid(&candidate)) {
            return false;
        }
        *graph = candidate;
        return true;
    }

    if (!N60ProgramFIRProgramInfoIsValid(info)
        || info.channelCount != candidate.programLayout.channelCount) {
        return false;
    }
    const uint64_t upstream64 =
        (uint64_t)info.engineLatencyFrames
        + (uint64_t)info.declaredLatencyFrames;
    if (upstream64 > N60_PROGRAM_LANE_MAX_DELAY_FRAMES) {
        return false;
    }
    const uint32_t upstream = (uint32_t)upstream64;

    for (uint32_t channel = 0u;
         channel < candidate.programLayout.channelCount;
         ++channel) {
        const bool active =
            (info.activeChannelMask & (1u << channel)) != 0u;
        if (active
            && candidate.programLayout.channels[channel]
                == N60ProgramChannelRoleLowFrequencyEffects) {
            return false;
        }
        if (!N60ProgramLaneGraphSetUpstreamProcessingLatency(
                &lanes,
                channel,
                active ? upstream : 0u)) {
            return false;
        }
    }
    if (!N60ProgramLaneGraphFinalize(&lanes)) return false;

    candidate.programFIREnabled = true;
    candidate.programFIR = info;
    candidate.laneGraph = lanes;
    if (!N60LiveNChannelProgramFIRGraphStateIsValid(&candidate)) {
        return false;
    }
    *graph = candidate;
    return true;
}

static inline bool N60LiveNChannelRenderGraphIsValid(
    const N60LiveNChannelRenderGraph * _Nullable graph
) {
    if (graph == NULL
        || !isfinite(graph->sampleRate)
        || graph->sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&graph->programLayout)
        || !N60ProgramLaneGraphIsValid(&graph->laneGraph)
        || !N60LiveNChannelProgramFIRGraphStateIsValid(graph)
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

static inline uint64_t N60LiveNChannelRenderGraphLatencyFrames(
    const N60LiveNChannelRenderGraph * _Nullable graph
) {
    if (graph == NULL || !N60LiveNChannelRenderGraphIsValid(graph)) return 0u;

    uint64_t maximumProgramDelay = 0u;
    for (uint32_t channel = 0; channel < graph->programLayout.channelCount; ++channel) {
        const uint64_t upstream =
            (uint64_t)graph->laneGraph.lanes[channel]
                .upstreamProcessingLatencyFrames;
        const uint64_t laneDelay =
            (uint64_t)N60ProgramLaneGraphEffectiveDelayFrames(
                &graph->laneGraph, channel
            );
        const uint64_t delay = upstream + laneDelay;
        if (delay > maximumProgramDelay) maximumProgramDelay = delay;
    }

    uint64_t maximumSubwooferDelay = 0u;
    if (graph->bassManagementEnabled) {
        for (uint32_t sub = 0; sub < graph->bassManagement.subwooferCount; ++sub) {
            const uint64_t delay = (uint64_t)graph->bassManagement.subwoofers[sub].delayFrames;
            if (delay > maximumSubwooferDelay) maximumSubwooferDelay = delay;
        }
    }
    return maximumProgramDelay + maximumSubwooferDelay;
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
    N60ProgramFIRRuntimeDestroy(runtime->programFIRRuntime);
    N60ProgramFIRProgramDestroy(runtime->programFIRProgram);
    N60ProgramLaneRuntimeDestroy(runtime->laneRuntime);
    N60MultichannelBassManagementRuntimeDestroy(runtime->bassRuntime);
    runtime->programFIRRuntime = NULL;
    runtime->programFIRProgram = NULL;
    runtime->laneRuntime = NULL;
    runtime->bassRuntime = NULL;
    free(runtime);
}

/// Control-plane only. Must run while audio callbacks are stopped. Creates a
/// sparse immutable FIR program/runtime and verifies that the actual prepared
/// metadata exactly matches the graph's latency/coherence contract.
static inline bool N60LiveNChannelRenderRuntimeConfigureProgramFIR(
    N60LiveNChannelRenderRuntime * _Nonnull runtime,
    const N60LiveNChannelRenderGraph * _Nonnull graph,
    const float * _Nonnull taps
) {
    if (runtime == NULL
        || graph == NULL
        || taps == NULL
        || !graph->programFIREnabled
        || !N60LiveNChannelProgramFIRGraphStateIsValid(graph)) {
        return false;
    }

    N60ProgramFIRProgram *program =
        N60ProgramFIRProgramCreate(
            graph->programFIR.channelCount,
            graph->programFIR.activeChannelMask,
            taps,
            graph->programFIR.tapCount,
            graph->programFIR.declaredLatencyFrames
        );
    if (program == NULL) return false;
    const N60ProgramFIRProgramInfo actual =
        N60ProgramFIRProgramGetInfo(program);
    if (!N60ProgramFIRProgramInfoEqual(
            actual, graph->programFIR)) {
        N60ProgramFIRProgramDestroy(program);
        return false;
    }

    N60ProgramFIRRuntime *programRuntime =
        N60ProgramFIRRuntimeCreate(program);
    if (programRuntime == NULL) {
        N60ProgramFIRProgramDestroy(program);
        return false;
    }

    N60ProgramFIRRuntimeDestroy(runtime->programFIRRuntime);
    N60ProgramFIRProgramDestroy(runtime->programFIRProgram);
    runtime->programFIRProgram = program;
    runtime->programFIRRuntime = programRuntime;
    return true;
}

static inline void N60LiveNChannelRenderRuntimeClearProgramFIR(
    N60LiveNChannelRenderRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    N60ProgramFIRRuntimeDestroy(runtime->programFIRRuntime);
    N60ProgramFIRProgramDestroy(runtime->programFIRProgram);
    runtime->programFIRRuntime = NULL;
    runtime->programFIRProgram = NULL;
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
        || (graph->programFIREnabled
            && (runtime->programFIRProgram == NULL
                || runtime->programFIRRuntime == NULL
                || !N60ProgramFIRProgramInfoEqual(
                    N60ProgramFIRProgramGetInfo(
                        runtime->programFIRProgram
                    ),
                    graph->programFIR
                )))
        || (!graph->programFIREnabled
            && (runtime->programFIRProgram != NULL
                || runtime->programFIRRuntime != NULL))
        || !N60ProgramLaneRuntimePrepare(runtime->laneRuntime, &graph->laneGraph)) {
        return false;
    }
    if (graph->bassManagementEnabled
        && !N60MultichannelBassManagementRuntimePrepare(
            runtime->bassRuntime,
            &graph->bassManagement)) {
        return false;
    }
    if (graph->programFIREnabled) {
        N60ProgramFIRRuntimeReset(runtime->programFIRRuntime);
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
        && (graph->programFIREnabled
            ? (runtime->programFIRProgram != NULL
                && runtime->programFIRRuntime != NULL
                && N60ProgramFIRProgramInfoEqual(
                    N60ProgramFIRProgramGetInfo(
                        runtime->programFIRProgram
                    ),
                    graph->programFIR
                ))
            : (runtime->programFIRProgram == NULL
                && runtime->programFIRRuntime == NULL))
        && N60ProgramLaneRuntimeIsPreparedForGraph(runtime->laneRuntime, &graph->laneGraph)
        && (!graph->bassManagementEnabled
            || N60MultichannelBassManagementRuntimeIsPreparedForSnapshot(
                runtime->bassRuntime,
                &graph->bassManagement));
}

/// Realtime composite: semantic program frame -> optional PR107 sparse
/// Speaker Optimizer FIR -> PR54 channel lanes -> optional PR55 bass management
/// -> explicit physical device frame. Program LFE and Sub N
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
        // E8 A3: 5 to 8 subs exist only on the graph path; the legacy kernel renders silence, never a truncation.
        || graph->outputMap.graphSubLaneCount > 0u
        || !N60LiveNChannelRenderRuntimeIsPrepared(runtime, graph)) {
        return false;
    }

    float firOutput[N60_MAX_PROGRAM_CHANNELS] = {0};
    const float *laneInput = input->channels;
    if (graph->programFIREnabled) {
        if (runtime->programFIRRuntime == NULL
            || !N60ProgramFIRRuntimeProcessFrame(
                runtime->programFIRRuntime,
                input->channels,
                firOutput)) {
            return false;
        }
        laneInput = firOutput;
    }

    float laneOutput[N60_MAX_PROGRAM_CHANNELS] = {0};
    if (!N60ProgramLaneProcessFrame(
            runtime->laneRuntime,
            &graph->laneGraph,
            laneInput,
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