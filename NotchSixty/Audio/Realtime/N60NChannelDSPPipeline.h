#ifndef N60NChannelDSPPipeline_h
#define N60NChannelDSPPipeline_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60ProgramLaneEngine.h"
#include "N60MultichannelBassManagement.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    double sampleRate;
    N60ProgramChannelLayout layout;
    N60ProgramLaneGraphSnapshot laneGraph;
    bool bassManagementEnabled;
    N60MultichannelBassManagementSnapshot bassManagement;
} N60NChannelDSPPipelineSnapshot;

typedef struct {
    N60ProgramChannelLayout layout;
    uint32_t subwooferCount;
    float programSpeakers[N60_MAX_PROGRAM_CHANNELS];
    float subwoofers[N60_MAX_SUBWOOFER_OUTPUTS];
} N60AcousticOutputFrame;

typedef struct N60NChannelDSPPipelineRuntime {
    N60ProgramLaneRuntime * _Nullable laneRuntime;
    N60MultichannelBassManagementRuntime * _Nullable bassRuntime;
    N60ProgramLaneMeterAccumulator meter;
    N60ProgramChannelLayout preparedLayout;
    uint32_t preparedSubwooferCount;
    bool preparedBassManagement;
    bool prepared;
} N60NChannelDSPPipelineRuntime;

static inline bool N60NChannelLayoutContainsLFE(const N60ProgramChannelLayout * _Nullable layout) {
    return layout != NULL
        && N60ProgramChannelLayoutIndexOfRole(layout, N60ProgramChannelRoleLowFrequencyEffects) >= 0;
}

static inline bool N60NChannelDSPPipelineSnapshotIsValid(
    const N60NChannelDSPPipelineSnapshot * _Nullable snapshot
) {
    if (snapshot == NULL
        || !isfinite(snapshot->sampleRate)
        || snapshot->sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&snapshot->layout)
        || !N60ProgramLaneGraphIsValid(&snapshot->laneGraph)
        || !N60ProgramChannelLayoutsEqual(&snapshot->layout, &snapshot->laneGraph.layout)
        || fabs(snapshot->sampleRate - snapshot->laneGraph.sampleRate) >= 0.5) {
        return false;
    }

    if (!snapshot->bassManagementEnabled) {
        // A semantic LFE lane must never be emitted as though it were a normal
        // full-range program speaker. Layouts containing LFE require the PR55
        // physical-sub routing stage, even when no redirected bass is enabled.
        return !N60NChannelLayoutContainsLFE(&snapshot->layout);
    }

    return N60MultichannelBassManagementSnapshotIsValid(&snapshot->bassManagement)
        && N60ProgramChannelLayoutsEqual(&snapshot->layout, &snapshot->bassManagement.programLayout)
        && fabs(snapshot->sampleRate - snapshot->bassManagement.sampleRate) < 0.5;
}

static inline N60NChannelDSPPipelineRuntime * _Nullable N60NChannelDSPPipelineRuntimeCreate(void) {
    N60NChannelDSPPipelineRuntime * _Nullable runtime =
        (N60NChannelDSPPipelineRuntime *)calloc(1u, sizeof(N60NChannelDSPPipelineRuntime));
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

static inline void N60NChannelDSPPipelineRuntimeDestroy(
    N60NChannelDSPPipelineRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    N60ProgramLaneRuntimeDestroy(runtime->laneRuntime);
    N60MultichannelBassManagementRuntimeDestroy(runtime->bassRuntime);
    runtime->laneRuntime = NULL;
    runtime->bassRuntime = NULL;
    free(runtime);
}

/// Control-plane preparation. All allocation and history clearing happens here,
/// while the future output callback is stopped.
static inline bool N60NChannelDSPPipelineRuntimePrepare(
    N60NChannelDSPPipelineRuntime * _Nonnull runtime,
    const N60NChannelDSPPipelineSnapshot * _Nonnull snapshot
) {
    if (runtime == NULL
        || snapshot == NULL
        || runtime->laneRuntime == NULL
        || runtime->bassRuntime == NULL
        || !N60NChannelDSPPipelineSnapshotIsValid(snapshot)
        || !N60ProgramLaneRuntimePrepare(runtime->laneRuntime, &snapshot->laneGraph)) {
        return false;
    }
    if (snapshot->bassManagementEnabled
        && !N60MultichannelBassManagementRuntimePrepare(
            runtime->bassRuntime,
            &snapshot->bassManagement)) {
        return false;
    }
    N60ProgramLaneMeterAccumulatorReset(&runtime->meter, snapshot->layout.channelCount);
    runtime->preparedLayout = snapshot->layout;
    runtime->preparedSubwooferCount = snapshot->bassManagementEnabled
        ? snapshot->bassManagement.subwooferCount
        : 0u;
    runtime->preparedBassManagement = snapshot->bassManagementEnabled;
    runtime->prepared = true;
    return true;
}

static inline bool N60NChannelDSPPipelineRuntimeIsPreparedForSnapshot(
    const N60NChannelDSPPipelineRuntime * _Nullable runtime,
    const N60NChannelDSPPipelineSnapshot * _Nullable snapshot
) {
    return runtime != NULL
        && snapshot != NULL
        && runtime->prepared
        && runtime->preparedBassManagement == snapshot->bassManagementEnabled
        && runtime->preparedSubwooferCount == (
            snapshot->bassManagementEnabled ? snapshot->bassManagement.subwooferCount : 0u
        )
        && N60ProgramChannelLayoutsEqual(&runtime->preparedLayout, &snapshot->layout)
        && N60ProgramLaneRuntimeIsPreparedForGraph(runtime->laneRuntime, &snapshot->laneGraph)
        && (!snapshot->bassManagementEnabled
            || N60MultichannelBassManagementRuntimeIsPreparedForSnapshot(
                runtime->bassRuntime,
                &snapshot->bassManagement));
}

/// Realtime primitive. Input is always canonical semantic program order. Output
/// separates non-LFE program-speaker feeds from physical Sub N feeds so native
/// LFE can never be confused with the physical subwoofer destination.
static inline bool N60NChannelDSPPipelineProcessFrame(
    N60NChannelDSPPipelineRuntime * _Nonnull runtime,
    const N60NChannelDSPPipelineSnapshot * _Nonnull snapshot,
    const float * _Nonnull canonicalProgramInput,
    N60AcousticOutputFrame * _Nonnull acousticOutput
) {
    if (runtime == NULL
        || snapshot == NULL
        || canonicalProgramInput == NULL
        || acousticOutput == NULL
        || !N60NChannelDSPPipelineRuntimeIsPreparedForSnapshot(runtime, snapshot)) {
        return false;
    }

    float laneOutput[N60_MAX_PROGRAM_CHANNELS] = {0};
    if (!N60ProgramLaneProcessFrame(
            runtime->laneRuntime,
            &snapshot->laneGraph,
            canonicalProgramInput,
            laneOutput,
            &runtime->meter)) {
        return false;
    }

    N60AcousticOutputFrame output = {0};
    output.layout = snapshot->layout;
    if (snapshot->bassManagementEnabled) {
        output.subwooferCount = snapshot->bassManagement.subwooferCount;
        if (!N60MultichannelBassManagementProcessFrame(
                runtime->bassRuntime,
                &snapshot->bassManagement,
                laneOutput,
                output.programSpeakers,
                output.subwoofers)) {
            return false;
        }
    } else {
        memcpy(
            output.programSpeakers,
            laneOutput,
            snapshot->layout.channelCount * sizeof(float)
        );
    }
    *acousticOutput = output;
    return true;
}

static inline N60ProgramLaneMeterReading N60NChannelDSPPipelineMeterReading(
    const N60NChannelDSPPipelineRuntime * _Nullable runtime
) {
    return runtime == NULL
        ? (N60ProgramLaneMeterReading){0}
        : N60ProgramLaneMeterAccumulatorReading(&runtime->meter);
}

#ifdef __cplusplus
}
#endif

#endif
