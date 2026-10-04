#ifndef N60MultichannelBassManagement_h
#define N60MultichannelBassManagement_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60Crossover.h"
#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MAX_SUBWOOFER_OUTPUTS 4u
#define N60_SUBWOOFER_MAX_EQ_SECTIONS 8u
#define N60_SUBWOOFER_DELAY_CAPACITY_FRAMES 65536u
#define N60_SUBWOOFER_MAX_DELAY_FRAMES (N60_SUBWOOFER_DELAY_CAPACITY_FRAMES - 1u)

typedef struct {
    bool enabled;
    N60CrossoverSnapshot crossover;
    float redirectedBassToSub[N60_MAX_SUBWOOFER_OUTPUTS];
} N60BassManagedSourceSnapshot;

typedef struct {
    bool enabled;
    float gainLinear;
    bool polarityInverted;
    uint32_t delayFrames;
    uint32_t eqSectionCount;
    N60BiquadBandSnapshot eqSections[N60_SUBWOOFER_MAX_EQ_SECTIONS];
    /// Optional last-resort sample ceiling. This is not a mastering limiter;
    /// it is an emergency protection clamp for a physical sub output.
    bool protectionEnabled;
    float protectionCeilingLinear;
} N60SubwooferOutputSnapshot;

typedef struct {
    double sampleRate;
    N60ProgramChannelLayout programLayout;
    uint32_t subwooferCount;
    N60BassManagedSourceSnapshot sources[N60_MAX_PROGRAM_CHANNELS];

    /// Native LFE routing is intentionally independent of redirected bass.
    bool lfeLowPassEnabled;
    N60CrossoverSnapshot lfeLowPass;
    float lfeGainLinear;
    float lfeToSub[N60_MAX_SUBWOOFER_OUTPUTS];

    N60SubwooferOutputSnapshot subwoofers[N60_MAX_SUBWOOFER_OUTPUTS];
} N60MultichannelBassManagementSnapshot;

typedef struct {
    N60BiquadState highPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState lowPass[N60_MAX_CROSSOVER_SECTIONS];
} N60BassManagedSourceRuntime;

typedef struct N60MultichannelBassManagementRuntime {
    N60BassManagedSourceRuntime sources[N60_MAX_PROGRAM_CHANNELS];
    N60BiquadState lfeLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadState subEQ[N60_MAX_SUBWOOFER_OUTPUTS][N60_SUBWOOFER_MAX_EQ_SECTIONS];
    float * _Nullable subDelayBuffers[N60_MAX_SUBWOOFER_OUTPUTS];
    uint32_t subDelayWriteIndex;
    uint64_t protectionClampSamples[N60_MAX_SUBWOOFER_OUTPUTS];
    N60ProgramChannelLayout preparedLayout;
    uint32_t preparedSubwooferCount;
    bool prepared;
} N60MultichannelBassManagementRuntime;

static inline N60SubwooferOutputSnapshot N60SubwooferOutputSnapshotMakeUnity(void) {
    N60SubwooferOutputSnapshot sub = {0};
    sub.enabled = true;
    sub.gainLinear = 1.0f;
    sub.protectionCeilingLinear = 1.0f;
    return sub;
}

static inline N60MultichannelBassManagementSnapshot N60MultichannelBassManagementSnapshotMake(
    double sampleRate,
    N60ProgramChannelLayout programLayout,
    uint32_t subwooferCount
) {
    N60MultichannelBassManagementSnapshot snapshot = {0};
    if (!isfinite(sampleRate)
        || sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&programLayout)
        || subwooferCount == 0u
        || subwooferCount > N60_MAX_SUBWOOFER_OUTPUTS) {
        return snapshot;
    }

    snapshot.sampleRate = sampleRate;
    snapshot.programLayout = programLayout;
    snapshot.subwooferCount = subwooferCount;
    snapshot.lfeGainLinear = 1.0f;
    snapshot.lfeLowPass = N60CrossoverSnapshotMakeBypassed();

    for (uint32_t channel = 0; channel < programLayout.channelCount; ++channel) {
        snapshot.sources[channel].crossover = N60CrossoverSnapshotMakeBypassed();
    }
    for (uint32_t sub = 0; sub < subwooferCount; ++sub) {
        snapshot.subwoofers[sub] = N60SubwooferOutputSnapshotMakeUnity();
    }
    return snapshot;
}

static inline bool N60MultichannelBassManagementSetSourceCrossover(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t channelIndex,
    double frequencyHz,
    N60CrossoverTopology topology,
    bool enabled
) {
    if (snapshot == NULL
        || channelIndex >= snapshot->programLayout.channelCount
        || snapshot->programLayout.channels[channelIndex] == N60ProgramChannelRoleLowFrequencyEffects) {
        return false;
    }

    N60CrossoverSnapshot crossover = {0};
    if (!N60CrossoverSnapshotMake(
            snapshot->sampleRate,
            frequencyHz,
            topology,
            N60CrossoverMonitorModeRecombined,
            1.0f,
            false,
            enabled,
            &crossover)) {
        return false;
    }
    snapshot->sources[channelIndex].enabled = enabled;
    snapshot->sources[channelIndex].crossover = crossover;
    return true;
}

static inline bool N60MultichannelBassManagementSetRedirectedBassRoute(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t channelIndex,
    uint32_t subwooferIndex,
    float gainLinear
) {
    if (snapshot == NULL
        || channelIndex >= snapshot->programLayout.channelCount
        || snapshot->programLayout.channels[channelIndex] == N60ProgramChannelRoleLowFrequencyEffects
        || subwooferIndex >= snapshot->subwooferCount
        || !isfinite(gainLinear)
        || gainLinear < 0.0f
        || gainLinear > 4.0f) {
        return false;
    }
    snapshot->sources[channelIndex].redirectedBassToSub[subwooferIndex] = gainLinear;
    return true;
}

static inline bool N60MultichannelBassManagementSetLFERoute(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    float gainLinear
) {
    if (snapshot == NULL
        || subwooferIndex >= snapshot->subwooferCount
        || !isfinite(gainLinear)
        || gainLinear < 0.0f
        || gainLinear > 4.0f) {
        return false;
    }
    snapshot->lfeToSub[subwooferIndex] = gainLinear;
    return true;
}

static inline bool N60MultichannelBassManagementSetLFEGain(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    float gainLinear
) {
    if (snapshot == NULL || !isfinite(gainLinear) || gainLinear < 0.0f || gainLinear > 4.0f) {
        return false;
    }
    snapshot->lfeGainLinear = gainLinear;
    return true;
}

static inline bool N60MultichannelBassManagementSetLFELowPass(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    double frequencyHz,
    N60CrossoverTopology topology,
    bool enabled
) {
    if (snapshot == NULL) return false;
    N60CrossoverSnapshot crossover = {0};
    if (!N60CrossoverSnapshotMake(
            snapshot->sampleRate,
            frequencyHz,
            topology,
            N60CrossoverMonitorModeSubOnly,
            1.0f,
            false,
            enabled,
            &crossover)) {
        return false;
    }
    snapshot->lfeLowPassEnabled = enabled;
    snapshot->lfeLowPass = crossover;
    return true;
}

static inline bool N60SubwooferOutputSetGain(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    float gainLinear
) {
    if (snapshot == NULL
        || subwooferIndex >= snapshot->subwooferCount
        || !isfinite(gainLinear)
        || gainLinear < 0.0f
        || gainLinear > 16.0f) {
        return false;
    }
    snapshot->subwoofers[subwooferIndex].gainLinear = gainLinear;
    return true;
}

static inline bool N60SubwooferOutputSetPolarityInverted(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    bool inverted
) {
    if (snapshot == NULL || subwooferIndex >= snapshot->subwooferCount) return false;
    snapshot->subwoofers[subwooferIndex].polarityInverted = inverted;
    return true;
}

static inline bool N60SubwooferOutputSetDelayFrames(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    uint32_t delayFrames
) {
    if (snapshot == NULL
        || subwooferIndex >= snapshot->subwooferCount
        || delayFrames > N60_SUBWOOFER_MAX_DELAY_FRAMES) {
        return false;
    }
    snapshot->subwoofers[subwooferIndex].delayFrames = delayFrames;
    return true;
}

static inline bool N60SubwooferOutputSetDelayMs(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    double delayMs
) {
    if (snapshot == NULL
        || !isfinite(snapshot->sampleRate)
        || snapshot->sampleRate <= 0.0
        || !isfinite(delayMs)
        || delayMs < 0.0) {
        return false;
    }
    const double frames = snapshot->sampleRate * delayMs * 0.001;
    if (!isfinite(frames) || frames > (double)N60_SUBWOOFER_MAX_DELAY_FRAMES) return false;
    return N60SubwooferOutputSetDelayFrames(snapshot, subwooferIndex, (uint32_t)llround(frames));
}

static inline bool N60SubwooferOutputSetEQBand(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
) {
    if (snapshot == NULL
        || subwooferIndex >= snapshot->subwooferCount
        || bandIndex >= N60_SUBWOOFER_MAX_EQ_SECTIONS) {
        return false;
    }
    N60BiquadBandSnapshot band = {0};
    if (!N60BiquadBandSnapshotMake(
            type,
            snapshot->sampleRate,
            frequencyHz,
            gainDB,
            q,
            enabled,
            &band)) {
        return false;
    }
    N60SubwooferOutputSnapshot *sub = &snapshot->subwoofers[subwooferIndex];
    sub->eqSections[bandIndex] = band;
    if (sub->eqSectionCount <= bandIndex) sub->eqSectionCount = bandIndex + 1u;
    return true;
}

static inline bool N60SubwooferOutputSetProtection(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    float ceilingLinear,
    bool enabled
) {
    if (snapshot == NULL
        || subwooferIndex >= snapshot->subwooferCount
        || !isfinite(ceilingLinear)
        || ceilingLinear <= 0.0f
        || ceilingLinear > 4.0f) {
        return false;
    }
    snapshot->subwoofers[subwooferIndex].protectionEnabled = enabled;
    snapshot->subwoofers[subwooferIndex].protectionCeilingLinear = ceilingLinear;
    return true;
}

static inline bool N60MultichannelBassManagementSnapshotIsValid(
    const N60MultichannelBassManagementSnapshot * _Nullable snapshot
) {
    if (snapshot == NULL
        || !isfinite(snapshot->sampleRate)
        || snapshot->sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&snapshot->programLayout)
        || snapshot->subwooferCount == 0u
        || snapshot->subwooferCount > N60_MAX_SUBWOOFER_OUTPUTS
        || !isfinite(snapshot->lfeGainLinear)
        || snapshot->lfeGainLinear < 0.0f
        || snapshot->lfeGainLinear > 4.0f) {
        return false;
    }

    for (uint32_t sub = 0; sub < snapshot->subwooferCount; ++sub) {
        if (!isfinite(snapshot->lfeToSub[sub])
            || snapshot->lfeToSub[sub] < 0.0f
            || snapshot->lfeToSub[sub] > 4.0f) {
            return false;
        }
        const N60SubwooferOutputSnapshot output = snapshot->subwoofers[sub];
        if (!isfinite(output.gainLinear)
            || output.gainLinear < 0.0f
            || output.gainLinear > 16.0f
            || output.delayFrames > N60_SUBWOOFER_MAX_DELAY_FRAMES
            || output.eqSectionCount > N60_SUBWOOFER_MAX_EQ_SECTIONS
            || !isfinite(output.protectionCeilingLinear)
            || output.protectionCeilingLinear <= 0.0f
            || output.protectionCeilingLinear > 4.0f) {
            return false;
        }
        for (uint32_t section = 0; section < output.eqSectionCount; ++section) {
            if (output.eqSections[section].enabled
                && !N60BiquadCoefficientsAreFinite(output.eqSections[section].coefficients)) {
                return false;
            }
        }
    }

    if (snapshot->lfeLowPassEnabled) {
        if (!snapshot->lfeLowPass.enabled
            || snapshot->lfeLowPass.sectionCount == 0u
            || snapshot->lfeLowPass.sectionCount > N60_MAX_CROSSOVER_SECTIONS) {
            return false;
        }
    }

    for (uint32_t channel = 0; channel < snapshot->programLayout.channelCount; ++channel) {
        const N60BassManagedSourceSnapshot source = snapshot->sources[channel];
        if (snapshot->programLayout.channels[channel] == N60ProgramChannelRoleLowFrequencyEffects) {
            if (source.enabled) return false;
            continue;
        }
        if (source.enabled
            && (!source.crossover.enabled
                || source.crossover.sectionCount == 0u
                || source.crossover.sectionCount > N60_MAX_CROSSOVER_SECTIONS)) {
            return false;
        }
        for (uint32_t sub = 0; sub < snapshot->subwooferCount; ++sub) {
            if (!isfinite(source.redirectedBassToSub[sub])
                || source.redirectedBassToSub[sub] < 0.0f
                || source.redirectedBassToSub[sub] > 4.0f) {
                return false;
            }
        }
    }
    return true;
}

static inline N60MultichannelBassManagementRuntime * _Nullable N60MultichannelBassManagementRuntimeCreate(void) {
    N60MultichannelBassManagementRuntime * _Nullable runtime =
        (N60MultichannelBassManagementRuntime *)calloc(1u, sizeof(N60MultichannelBassManagementRuntime));
    if (runtime == NULL) return NULL;

    for (uint32_t sub = 0; sub < N60_MAX_SUBWOOFER_OUTPUTS; ++sub) {
        runtime->subDelayBuffers[sub] = (float *)calloc(
            N60_SUBWOOFER_DELAY_CAPACITY_FRAMES,
            sizeof(float)
        );
        if (runtime->subDelayBuffers[sub] == NULL) {
            for (uint32_t cleanup = 0; cleanup < sub; ++cleanup) free(runtime->subDelayBuffers[cleanup]);
            free(runtime);
            return NULL;
        }
    }
    return runtime;
}

static inline void N60MultichannelBassManagementRuntimeDestroy(
    N60MultichannelBassManagementRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    for (uint32_t sub = 0; sub < N60_MAX_SUBWOOFER_OUTPUTS; ++sub) {
        free(runtime->subDelayBuffers[sub]);
        runtime->subDelayBuffers[sub] = NULL;
    }
    free(runtime);
}

/// Control-plane preparation only. Clears all filter and delay history.
static inline bool N60MultichannelBassManagementRuntimePrepare(
    N60MultichannelBassManagementRuntime * _Nonnull runtime,
    const N60MultichannelBassManagementSnapshot * _Nonnull snapshot
) {
    if (runtime == NULL || snapshot == NULL || !N60MultichannelBassManagementSnapshotIsValid(snapshot)) {
        return false;
    }
    memset(runtime->sources, 0, sizeof(runtime->sources));
    memset(runtime->lfeLowPass, 0, sizeof(runtime->lfeLowPass));
    memset(runtime->subEQ, 0, sizeof(runtime->subEQ));
    memset(runtime->protectionClampSamples, 0, sizeof(runtime->protectionClampSamples));
    for (uint32_t sub = 0; sub < N60_MAX_SUBWOOFER_OUTPUTS; ++sub) {
        if (runtime->subDelayBuffers[sub] == NULL) return false;
        memset(runtime->subDelayBuffers[sub], 0, N60_SUBWOOFER_DELAY_CAPACITY_FRAMES * sizeof(float));
    }
    runtime->subDelayWriteIndex = 0u;
    runtime->preparedLayout = snapshot->programLayout;
    runtime->preparedSubwooferCount = snapshot->subwooferCount;
    runtime->prepared = true;
    return true;
}

static inline bool N60MultichannelBassManagementRuntimeIsPreparedForSnapshot(
    const N60MultichannelBassManagementRuntime * _Nullable runtime,
    const N60MultichannelBassManagementSnapshot * _Nullable snapshot
) {
    if (runtime == NULL || snapshot == NULL || !runtime->prepared) return false;
    if (runtime->preparedSubwooferCount != snapshot->subwooferCount
        || runtime->preparedLayout.channelCount != snapshot->programLayout.channelCount) {
        return false;
    }
    for (uint32_t channel = 0; channel < snapshot->programLayout.channelCount; ++channel) {
        if (runtime->preparedLayout.channels[channel] != snapshot->programLayout.channels[channel]) return false;
    }
    return true;
}

static inline float N60BassManagementProcessCascade(
    float sample,
    const N60BiquadCoefficients * _Nonnull coefficients,
    N60BiquadState * _Nonnull states,
    uint32_t sectionCount
) {
    for (uint32_t section = 0; section < sectionCount; ++section) {
        sample = N60BiquadProcessSample(coefficients[section], &states[section], sample);
    }
    return sample;
}

/// Realtime primitive. Produces bandwidth-managed speaker feeds in the original
/// semantic program order plus up to four distinct physical subwoofer feeds.
/// The native LFE program lane is consumed into the explicit LFE→Sub matrix and
/// is zeroed in speakerOutputs; it is never treated as a physical sub channel.
static inline bool N60MultichannelBassManagementProcessFrame(
    N60MultichannelBassManagementRuntime * _Nonnull runtime,
    const N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    const float * _Nonnull programInput,
    float * _Nonnull speakerOutputs,
    float * _Nonnull subwooferOutputs
) {
    if (runtime == NULL
        || snapshot == NULL
        || programInput == NULL
        || speakerOutputs == NULL
        || subwooferOutputs == NULL
        || !N60MultichannelBassManagementRuntimeIsPreparedForSnapshot(runtime, snapshot)) {
        return false;
    }

    float subSums[N60_MAX_SUBWOOFER_OUTPUTS] = {0};

    for (uint32_t channel = 0; channel < snapshot->programLayout.channelCount; ++channel) {
        float sample = isfinite(programInput[channel]) ? programInput[channel] : 0.0f;
        const N60ProgramChannelRole role = snapshot->programLayout.channels[channel];

        if (role == N60ProgramChannelRoleLowFrequencyEffects) {
            speakerOutputs[channel] = 0.0f;
            float lfe = sample;
            if (snapshot->lfeLowPassEnabled) {
                lfe = N60BassManagementProcessCascade(
                    lfe,
                    snapshot->lfeLowPass.subLowPass,
                    runtime->lfeLowPass,
                    snapshot->lfeLowPass.sectionCount
                );
            }
            lfe *= snapshot->lfeGainLinear;
            for (uint32_t sub = 0; sub < snapshot->subwooferCount; ++sub) {
                subSums[sub] += lfe * snapshot->lfeToSub[sub];
            }
            continue;
        }

        const N60BassManagedSourceSnapshot *source = &snapshot->sources[channel];
        if (!source->enabled) {
            speakerOutputs[channel] = sample;
            continue;
        }

        N60BassManagedSourceRuntime *sourceRuntime = &runtime->sources[channel];
        const uint32_t sectionCount = source->crossover.sectionCount;
        const float high = N60BassManagementProcessCascade(
            sample,
            source->crossover.mainsHighPass,
            sourceRuntime->highPass,
            sectionCount
        );
        const float low = N60BassManagementProcessCascade(
            sample,
            source->crossover.subLowPass,
            sourceRuntime->lowPass,
            sectionCount
        );
        speakerOutputs[channel] = high;
        for (uint32_t sub = 0; sub < snapshot->subwooferCount; ++sub) {
            subSums[sub] += low * source->redirectedBassToSub[sub];
        }
    }

    const uint32_t writeIndex = runtime->subDelayWriteIndex;
    for (uint32_t sub = 0; sub < snapshot->subwooferCount; ++sub) {
        const N60SubwooferOutputSnapshot *output = &snapshot->subwoofers[sub];
        float sample = output->enabled ? subSums[sub] : 0.0f;
        sample *= output->gainLinear;
        if (output->polarityInverted) sample = -sample;

        for (uint32_t section = 0; section < output->eqSectionCount; ++section) {
            const N60BiquadBandSnapshot band = output->eqSections[section];
            if (band.enabled) {
                sample = N60BiquadProcessSample(
                    band.coefficients,
                    &runtime->subEQ[sub][section],
                    sample
                );
            }
        }

        runtime->subDelayBuffers[sub][writeIndex] = sample;
        if (output->delayFrames > 0u) {
            const uint32_t readIndex = (
                writeIndex + N60_SUBWOOFER_DELAY_CAPACITY_FRAMES - output->delayFrames
            ) % N60_SUBWOOFER_DELAY_CAPACITY_FRAMES;
            sample = runtime->subDelayBuffers[sub][readIndex];
        }

        if (output->protectionEnabled) {
            const float ceiling = output->protectionCeilingLinear;
            if (sample > ceiling) {
                sample = ceiling;
                runtime->protectionClampSamples[sub] += 1u;
            } else if (sample < -ceiling) {
                sample = -ceiling;
                runtime->protectionClampSamples[sub] += 1u;
            }
        }
        subwooferOutputs[sub] = sample;
    }
    for (uint32_t sub = snapshot->subwooferCount; sub < N60_MAX_SUBWOOFER_OUTPUTS; ++sub) {
        subwooferOutputs[sub] = 0.0f;
    }

    runtime->subDelayWriteIndex = (writeIndex + 1u) % N60_SUBWOOFER_DELAY_CAPACITY_FRAMES;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
