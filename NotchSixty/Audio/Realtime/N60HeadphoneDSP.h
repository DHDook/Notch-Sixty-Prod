#ifndef N60HeadphoneDSP_h
#define N60HeadphoneDSP_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60Biquad.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_HEADPHONE_CHANNEL_COUNT 2u
#define N60_HEADPHONE_MAX_EQ_SECTIONS 16u
#define N60_HEADPHONE_DELAY_CAPACITY_FRAMES 4096u
#define N60_HEADPHONE_MAX_DELAY_FRAMES (N60_HEADPHONE_DELAY_CAPACITY_FRAMES - 1u)
#define N60_HEADPHONE_SPEED_OF_SOUND_MPS 343.0

typedef enum {
    N60HeadphoneTargetCurveNeutral = 0,
    N60HeadphoneTargetCurveDiffuseField = 1,
    N60HeadphoneTargetCurveCustom = 2,
} N60HeadphoneTargetCurveKind;

typedef struct {
    float gainLinear;
    bool polarityInverted;
    uint32_t delayFrames;
    uint32_t eqSectionCount;
    N60BiquadBandSnapshot eqSections[N60_HEADPHONE_MAX_EQ_SECTIONS];
} N60HeadphoneChannelCorrectionSnapshot;

typedef struct {
    bool enabled;
    /// User strength 0...1. Internally maps to at most a 50% low-frequency
    /// contralateral blend so the low band approaches mono without swapping.
    float amount;
    double virtualSpeakerAngleDegrees;
    double headRadiusMeters;
    double headShadowFrequencyHz;
    uint32_t contralateralDelayFrames;
    float lowBandMix;
    float lowPassAlpha;
} N60HeadphoneCrossfeedSnapshot;

typedef struct {
    double sampleRate;
    float headroomGainLinear;
    N60HeadphoneTargetCurveKind targetCurveKind;
    N60HeadphoneChannelCorrectionSnapshot channels[N60_HEADPHONE_CHANNEL_COUNT];
    N60HeadphoneCrossfeedSnapshot crossfeed;
} N60HeadphoneDSPSnapshot;

typedef struct N60HeadphoneDSPRuntime {
    N60BiquadState eqStates[N60_HEADPHONE_CHANNEL_COUNT][N60_HEADPHONE_MAX_EQ_SECTIONS];
    float channelDelay[N60_HEADPHONE_CHANNEL_COUNT][N60_HEADPHONE_DELAY_CAPACITY_FRAMES];
    float crossfeedDelay[N60_HEADPHONE_CHANNEL_COUNT][N60_HEADPHONE_DELAY_CAPACITY_FRAMES];
    uint32_t channelDelayWriteIndex;
    uint32_t crossfeedDelayWriteIndex;
    float localLow[N60_HEADPHONE_CHANNEL_COUNT];
    float delayedLow[N60_HEADPHONE_CHANNEL_COUNT];
    bool prepared;
    double preparedSampleRate;
} N60HeadphoneDSPRuntime;

static inline N60HeadphoneChannelCorrectionSnapshot N60HeadphoneChannelCorrectionMakeUnity(void) {
    N60HeadphoneChannelCorrectionSnapshot correction = {0};
    correction.gainLinear = 1.0f;
    return correction;
}

static inline N60HeadphoneCrossfeedSnapshot N60HeadphoneCrossfeedMakeBypassed(void) {
    N60HeadphoneCrossfeedSnapshot crossfeed = {0};
    crossfeed.virtualSpeakerAngleDegrees = 30.0;
    crossfeed.headRadiusMeters = 0.0875;
    crossfeed.headShadowFrequencyHz = 700.0;
    return crossfeed;
}

static inline N60HeadphoneDSPSnapshot N60HeadphoneDSPSnapshotMakeUnity(double sampleRate) {
    N60HeadphoneDSPSnapshot snapshot = {0};
    if (!isfinite(sampleRate) || sampleRate <= 0.0) return snapshot;
    snapshot.sampleRate = sampleRate;
    snapshot.headroomGainLinear = 1.0f;
    snapshot.targetCurveKind = N60HeadphoneTargetCurveNeutral;
    snapshot.channels[0] = N60HeadphoneChannelCorrectionMakeUnity();
    snapshot.channels[1] = N60HeadphoneChannelCorrectionMakeUnity();
    snapshot.crossfeed = N60HeadphoneCrossfeedMakeBypassed();
    return snapshot;
}

static inline bool N60HeadphoneDSPSetTargetCurveKind(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    N60HeadphoneTargetCurveKind targetCurveKind
) {
    if (snapshot == NULL
        || targetCurveKind < N60HeadphoneTargetCurveNeutral
        || targetCurveKind > N60HeadphoneTargetCurveCustom) {
        return false;
    }
    snapshot->targetCurveKind = targetCurveKind;
    return true;
}

static inline bool N60HeadphoneDSPSetHeadroomAttenuationDB(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    double attenuationDB
) {
    if (snapshot == NULL
        || !isfinite(attenuationDB)
        || attenuationDB < 0.0
        || attenuationDB > 30.0) {
        return false;
    }
    snapshot->headroomGainLinear = (float)pow(10.0, -attenuationDB / 20.0);
    return isfinite(snapshot->headroomGainLinear) && snapshot->headroomGainLinear > 0.0f;
}

static inline bool N60HeadphoneDSPSetChannelGain(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    uint32_t channelIndex,
    float gainLinear
) {
    if (snapshot == NULL
        || channelIndex >= N60_HEADPHONE_CHANNEL_COUNT
        || !isfinite(gainLinear)
        || gainLinear < 0.0f
        || gainLinear > 4.0f) {
        return false;
    }
    snapshot->channels[channelIndex].gainLinear = gainLinear;
    return true;
}

static inline bool N60HeadphoneDSPSetChannelPolarityInverted(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    uint32_t channelIndex,
    bool inverted
) {
    if (snapshot == NULL || channelIndex >= N60_HEADPHONE_CHANNEL_COUNT) return false;
    snapshot->channels[channelIndex].polarityInverted = inverted;
    return true;
}

static inline bool N60HeadphoneDSPSetChannelDelayFrames(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    uint32_t channelIndex,
    uint32_t delayFrames
) {
    if (snapshot == NULL
        || channelIndex >= N60_HEADPHONE_CHANNEL_COUNT
        || delayFrames > N60_HEADPHONE_MAX_DELAY_FRAMES) {
        return false;
    }
    snapshot->channels[channelIndex].delayFrames = delayFrames;
    return true;
}

static inline bool N60HeadphoneDSPSetChannelDelayMs(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    uint32_t channelIndex,
    double delayMs
) {
    if (snapshot == NULL
        || channelIndex >= N60_HEADPHONE_CHANNEL_COUNT
        || !isfinite(snapshot->sampleRate)
        || snapshot->sampleRate <= 0.0
        || !isfinite(delayMs)
        || delayMs < 0.0) {
        return false;
    }
    const double frames = snapshot->sampleRate * delayMs * 0.001;
    if (!isfinite(frames) || frames > (double)N60_HEADPHONE_MAX_DELAY_FRAMES) return false;
    return N60HeadphoneDSPSetChannelDelayFrames(snapshot, channelIndex, (uint32_t)llround(frames));
}

static inline bool N60HeadphoneDSPSetChannelEQBand(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    uint32_t channelIndex,
    uint32_t bandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
) {
    if (snapshot == NULL
        || channelIndex >= N60_HEADPHONE_CHANNEL_COUNT
        || bandIndex >= N60_HEADPHONE_MAX_EQ_SECTIONS) {
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
    N60HeadphoneChannelCorrectionSnapshot *channel = &snapshot->channels[channelIndex];
    channel->eqSections[bandIndex] = band;
    if (channel->eqSectionCount <= bandIndex) channel->eqSectionCount = bandIndex + 1u;
    return true;
}

/// Control-plane design for frequency-dependent acoustic crossfeed.
///
/// This is intentionally not an HRTF/binaural renderer. It models the two cues
/// a simple speaker crossfeed needs: a low-frequency contralateral path and an
/// interaural time difference derived from virtual speaker angle/head radius.
/// PR57 owns full SOFA/HRTF/BRIR binaural rendering.
static inline bool N60HeadphoneDSPSetCrossfeed(
    N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    float amount,
    double virtualSpeakerAngleDegrees,
    double headRadiusMeters,
    double headShadowFrequencyHz,
    bool enabled
) {
    if (snapshot == NULL
        || !isfinite(snapshot->sampleRate)
        || snapshot->sampleRate <= 0.0
        || !isfinite(amount)
        || amount < 0.0f
        || amount > 1.0f
        || !isfinite(virtualSpeakerAngleDegrees)
        || virtualSpeakerAngleDegrees < 15.0
        || virtualSpeakerAngleDegrees > 90.0
        || !isfinite(headRadiusMeters)
        || headRadiusMeters < 0.06
        || headRadiusMeters > 0.12
        || !isfinite(headShadowFrequencyHz)
        || headShadowFrequencyHz < 200.0
        || headShadowFrequencyHz >= snapshot->sampleRate * 0.5) {
        return false;
    }

    const double radians = virtualSpeakerAngleDegrees * (3.14159265358979323846 / 180.0);
    const double delaySeconds = (headRadiusMeters / N60_HEADPHONE_SPEED_OF_SOUND_MPS) * sin(radians);
    const double delayFrames = snapshot->sampleRate * delaySeconds;
    if (!isfinite(delayFrames) || delayFrames > (double)N60_HEADPHONE_MAX_DELAY_FRAMES) return false;

    const double alpha = 1.0 - exp(-2.0 * 3.14159265358979323846 * headShadowFrequencyHz / snapshot->sampleRate);
    if (!isfinite(alpha) || alpha <= 0.0 || alpha > 1.0) return false;

    snapshot->crossfeed.enabled = enabled;
    snapshot->crossfeed.amount = amount;
    snapshot->crossfeed.virtualSpeakerAngleDegrees = virtualSpeakerAngleDegrees;
    snapshot->crossfeed.headRadiusMeters = headRadiusMeters;
    snapshot->crossfeed.headShadowFrequencyHz = headShadowFrequencyHz;
    snapshot->crossfeed.contralateralDelayFrames = (uint32_t)llround(delayFrames);
    snapshot->crossfeed.lowBandMix = 0.5f * amount;
    snapshot->crossfeed.lowPassAlpha = (float)alpha;
    return true;
}

static inline bool N60HeadphoneDSPSnapshotIsValid(
    const N60HeadphoneDSPSnapshot * _Nullable snapshot
) {
    if (snapshot == NULL
        || !isfinite(snapshot->sampleRate)
        || snapshot->sampleRate <= 0.0
        || !isfinite(snapshot->headroomGainLinear)
        || snapshot->headroomGainLinear <= 0.0f
        || snapshot->headroomGainLinear > 1.0f
        || snapshot->targetCurveKind < N60HeadphoneTargetCurveNeutral
        || snapshot->targetCurveKind > N60HeadphoneTargetCurveCustom) {
        return false;
    }

    for (uint32_t channelIndex = 0; channelIndex < N60_HEADPHONE_CHANNEL_COUNT; ++channelIndex) {
        const N60HeadphoneChannelCorrectionSnapshot channel = snapshot->channels[channelIndex];
        if (!isfinite(channel.gainLinear)
            || channel.gainLinear < 0.0f
            || channel.gainLinear > 4.0f
            || channel.delayFrames > N60_HEADPHONE_MAX_DELAY_FRAMES
            || channel.eqSectionCount > N60_HEADPHONE_MAX_EQ_SECTIONS) {
            return false;
        }
        for (uint32_t section = 0; section < channel.eqSectionCount; ++section) {
            if (channel.eqSections[section].enabled
                && !N60BiquadCoefficientsAreFinite(channel.eqSections[section].coefficients)) {
                return false;
            }
        }
    }

    const N60HeadphoneCrossfeedSnapshot crossfeed = snapshot->crossfeed;
    if (!isfinite(crossfeed.amount)
        || crossfeed.amount < 0.0f
        || crossfeed.amount > 1.0f
        || !isfinite(crossfeed.virtualSpeakerAngleDegrees)
        || crossfeed.virtualSpeakerAngleDegrees < 15.0
        || crossfeed.virtualSpeakerAngleDegrees > 90.0
        || !isfinite(crossfeed.headRadiusMeters)
        || crossfeed.headRadiusMeters < 0.06
        || crossfeed.headRadiusMeters > 0.12
        || !isfinite(crossfeed.headShadowFrequencyHz)
        || crossfeed.headShadowFrequencyHz < 200.0
        || crossfeed.headShadowFrequencyHz >= snapshot->sampleRate * 0.5
        || crossfeed.contralateralDelayFrames > N60_HEADPHONE_MAX_DELAY_FRAMES
        || !isfinite(crossfeed.lowBandMix)
        || crossfeed.lowBandMix < 0.0f
        || crossfeed.lowBandMix > 0.5f
        || !isfinite(crossfeed.lowPassAlpha)
        || crossfeed.lowPassAlpha < 0.0f
        || crossfeed.lowPassAlpha > 1.0f) {
        return false;
    }
    return true;
}

static inline N60HeadphoneDSPRuntime * _Nullable N60HeadphoneDSPRuntimeCreate(void) {
    return (N60HeadphoneDSPRuntime *)calloc(1u, sizeof(N60HeadphoneDSPRuntime));
}

static inline void N60HeadphoneDSPRuntimeDestroy(N60HeadphoneDSPRuntime * _Nullable runtime) {
    free(runtime);
}

/// Control-plane preparation only. Clears EQ, delay, and crossfeed history.
static inline bool N60HeadphoneDSPRuntimePrepare(
    N60HeadphoneDSPRuntime * _Nonnull runtime,
    const N60HeadphoneDSPSnapshot * _Nonnull snapshot
) {
    if (runtime == NULL || snapshot == NULL || !N60HeadphoneDSPSnapshotIsValid(snapshot)) return false;
    memset(runtime, 0, sizeof(*runtime));
    runtime->prepared = true;
    runtime->preparedSampleRate = snapshot->sampleRate;
    return true;
}

static inline bool N60HeadphoneDSPRuntimeIsPreparedForSnapshot(
    const N60HeadphoneDSPRuntime * _Nullable runtime,
    const N60HeadphoneDSPSnapshot * _Nullable snapshot
) {
    return runtime != NULL
        && snapshot != NULL
        && runtime->prepared
        && runtime->preparedSampleRate == snapshot->sampleRate;
}

static inline float N60HeadphoneSanitizeSample(float sample) {
    return isfinite(sample) ? sample : 0.0f;
}

static inline void N60HeadphoneCrossfeedProcess(
    N60HeadphoneDSPRuntime * _Nonnull runtime,
    const N60HeadphoneCrossfeedSnapshot * _Nonnull crossfeed,
    float inputLeft,
    float inputRight,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
) {
    if (!crossfeed->enabled || crossfeed->lowBandMix <= 0.0f) {
        *outputLeft = inputLeft;
        *outputRight = inputRight;
        return;
    }

    const uint32_t writeIndex = runtime->crossfeedDelayWriteIndex;
    runtime->crossfeedDelay[0][writeIndex] = inputLeft;
    runtime->crossfeedDelay[1][writeIndex] = inputRight;
    const uint32_t readIndex = (
        writeIndex + N60_HEADPHONE_DELAY_CAPACITY_FRAMES - crossfeed->contralateralDelayFrames
    ) % N60_HEADPHONE_DELAY_CAPACITY_FRAMES;
    const float delayedLeft = runtime->crossfeedDelay[0][readIndex];
    const float delayedRight = runtime->crossfeedDelay[1][readIndex];

    const float alpha = crossfeed->lowPassAlpha;
    runtime->localLow[0] += alpha * (inputLeft - runtime->localLow[0]);
    runtime->localLow[1] += alpha * (inputRight - runtime->localLow[1]);
    runtime->delayedLow[0] += alpha * (delayedLeft - runtime->delayedLow[0]);
    runtime->delayedLow[1] += alpha * (delayedRight - runtime->delayedLow[1]);

    const float highLeft = inputLeft - runtime->localLow[0];
    const float highRight = inputRight - runtime->localLow[1];
    const float mix = crossfeed->lowBandMix;
    *outputLeft = highLeft + (1.0f - mix) * runtime->localLow[0] + mix * runtime->delayedLow[1];
    *outputRight = highRight + (1.0f - mix) * runtime->localLow[1] + mix * runtime->delayedLow[0];
    runtime->crossfeedDelayWriteIndex = (writeIndex + 1u) % N60_HEADPHONE_DELAY_CAPACITY_FRAMES;
}

static inline float N60HeadphoneApplyChannelCorrection(
    N60HeadphoneDSPRuntime * _Nonnull runtime,
    const N60HeadphoneChannelCorrectionSnapshot * _Nonnull channel,
    uint32_t channelIndex,
    float sample
) {
    for (uint32_t section = 0; section < channel->eqSectionCount; ++section) {
        const N60BiquadBandSnapshot band = channel->eqSections[section];
        if (band.enabled) {
            sample = N60BiquadProcessSample(
                band.coefficients,
                &runtime->eqStates[channelIndex][section],
                sample
            );
        }
    }
    sample *= channel->gainLinear;
    if (channel->polarityInverted) sample = -sample;

    const uint32_t writeIndex = runtime->channelDelayWriteIndex;
    runtime->channelDelay[channelIndex][writeIndex] = sample;
    if (channel->delayFrames > 0u) {
        const uint32_t readIndex = (
            writeIndex + N60_HEADPHONE_DELAY_CAPACITY_FRAMES - channel->delayFrames
        ) % N60_HEADPHONE_DELAY_CAPACITY_FRAMES;
        sample = runtime->channelDelay[channelIndex][readIndex];
    }
    return sample;
}

/// Realtime-safe stereo headphone stage. Crossfeed is applied before device
/// correction so the hardware/profile correction remains the final linear
/// compensation layer. The app's existing protection/true-peak stage should
/// remain downstream when this processor is integrated into the live graph.
static inline bool N60HeadphoneDSPProcessStereoFrame(
    N60HeadphoneDSPRuntime * _Nonnull runtime,
    const N60HeadphoneDSPSnapshot * _Nonnull snapshot,
    float inputLeft,
    float inputRight,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
) {
    if (runtime == NULL
        || snapshot == NULL
        || outputLeft == NULL
        || outputRight == NULL
        || !N60HeadphoneDSPRuntimeIsPreparedForSnapshot(runtime, snapshot)) {
        return false;
    }

    float left = N60HeadphoneSanitizeSample(inputLeft) * snapshot->headroomGainLinear;
    float right = N60HeadphoneSanitizeSample(inputRight) * snapshot->headroomGainLinear;
    float spatialLeft = left;
    float spatialRight = right;
    N60HeadphoneCrossfeedProcess(
        runtime,
        &snapshot->crossfeed,
        left,
        right,
        &spatialLeft,
        &spatialRight
    );

    left = N60HeadphoneApplyChannelCorrection(runtime, &snapshot->channels[0], 0u, spatialLeft);
    right = N60HeadphoneApplyChannelCorrection(runtime, &snapshot->channels[1], 1u, spatialRight);
    runtime->channelDelayWriteIndex =
        (runtime->channelDelayWriteIndex + 1u) % N60_HEADPHONE_DELAY_CAPACITY_FRAMES;

    *outputLeft = N60HeadphoneSanitizeSample(left);
    *outputRight = N60HeadphoneSanitizeSample(right);
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
