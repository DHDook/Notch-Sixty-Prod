#ifndef N60UnifiedGraphEligibility_h
#define N60UnifiedGraphEligibility_h

// E6 S8: decides, on the control thread, whether a kernel DSP snapshot can be rendered
// by libn60core without changing what the listener hears. Anything the core stages do
// not yet reproduce keeps the kernel path (the stereo callback falls back per snapshot).
// Pure function of the snapshot; no allocation; never called from the audio callback.

#include <stdbool.h>
#include <stdint.h>

#include "../Realtime/N60RenderKernel.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    N60UnifiedGraphSupported = 0,
    N60UnifiedGraphUnsupportedBypassOrAudition = 1,
    N60UnifiedGraphUnsupportedMidSideOrMixedPhase = 2,
    N60UnifiedGraphUnsupportedEQSection = 3,
    N60UnifiedGraphUnsupportedSpatial = 4,
    N60UnifiedGraphUnsupportedCrossover = 5,
    N60UnifiedGraphUnsupportedDynamics = 6,
    N60UnifiedGraphUnsupportedProtection = 7,
    N60UnifiedGraphUnsupportedConvolution = 8,
    N60UnifiedGraphUnsupportedAmbientOrANC = 9,
    N60UnifiedGraphUnsupportedDelay = 10,
    N60UnifiedGraphUnsupportedGain = 11,
} N60UnifiedGraphUnsupportedReason;

static inline N60UnifiedGraphUnsupportedReason N60UnifiedGraphSnapshotUnsupportedReason(
    const N60DSPGraphSnapshot * _Nonnull s
) {
    if (s->bypassed || s->auditionMode != N60AuditionModeProcessed) {
        return N60UnifiedGraphUnsupportedBypassOrAudition;
    }
    if (s->eqMidSideMode || s->mixedPhaseEnabled) {
        return N60UnifiedGraphUnsupportedMidSideOrMixedPhase;
    }
    if (s->eqBandCount > N60_MAX_EQ_RENDER_SLOTS) return N60UnifiedGraphUnsupportedEQSection;
    uint32_t perLane[2] = {0u, 0u};
    for (uint32_t i = 0; i < s->eqBandCount; ++i) {
        const N60BiquadBandSnapshot *b = &s->eqBands[i];
        if (!b->enabled) continue;
        const int type = (int)b->type;
        // The core PEQ implements types 0..7 only, +-24 dB, with 16 sections per lane.
        if (type < 0 || type > 7 || !(b->gainDB >= -24.0 && b->gainDB <= 24.0)) {
            return N60UnifiedGraphUnsupportedEQSection;
        }
        const uint8_t mask = s->eqBandChannelMasks[i];
        if (mask & N60_EQ_CHANNEL_LEFT) perLane[0] += 1u;
        if (mask & N60_EQ_CHANNEL_RIGHT) perLane[1] += 1u;
    }
    if (perLane[0] > 16u || perLane[1] > 16u) return N60UnifiedGraphUnsupportedEQSection;
    if (s->symmetryBalance.enabled || s->speakerCrossfeed.enabled
            || s->crosstalkCancellation.enabled) {
        return N60UnifiedGraphUnsupportedSpatial;
    }
    if (s->crossover.enabled) return N60UnifiedGraphUnsupportedCrossover;
    if (s->interChannelDelay.enabled) return N60UnifiedGraphUnsupportedDelay;
    const N60DynamicsSnapshot *d = &s->dynamics;
    if (d->stereoMode.mode != N60StereoModeStereo || d->stereoWidener.enabled
            || d->dcOffsetFilter.enabled || d->infrasonicFilter.enabled
            || d->mainsNotch.enabled || d->mainsHumDetector.enabled
            || d->spectralDenoiser.enabled || d->loudnessMatch.enabled
            || d->loudnessContour.enabled || d->dialogueLeveler.enabled
            || d->dynamicEQ.enabled || d->deHarsh.enabled || d->deEsser.enabled
            || d->multibandCompressor.enabled || d->compressor.enabled
            || d->expander.enabled || d->pauseGate.enabled) {
        return N60UnifiedGraphUnsupportedDynamics;
    }
    if (s->protection.softClipperEnabled || s->protection.gainRiderEnabled) {
        return N60UnifiedGraphUnsupportedProtection;
    }
    if (s->convolution.enabled || s->roomCorrection.enabled || s->speakerIR.enabled) {
        return N60UnifiedGraphUnsupportedConvolution;
    }
    if (s->ambientCompensation.enabled || s->activeQuietZone.enabled) {
        return N60UnifiedGraphUnsupportedAmbientOrANC;
    }
    const float gains[7] = {
        s->inputGainLinear, s->headroomGainLinear, s->outputGainLinear, s->masterGainLinear,
        s->balanceGainLeftLinear, s->balanceGainRightLinear, 1.0f
    };
    for (int i = 0; i < 6; ++i) {
        if (!(gains[i] > 0.0f && gains[i] <= 10000.0f)) return N60UnifiedGraphUnsupportedGain;
    }
    return N60UnifiedGraphSupported;
}


typedef struct {
    bool enabled;
    int32_t type;
    double frequencyHz;
    double gainDB;
    double q;
    uint8_t channelMask;
} N60UnifiedGraphBand;

// Reads EQ band `index` of the snapshot into a flat struct so Swift need not index the
// snapshot's fixed arrays. Returns false when `index` is out of range.
static inline bool N60UnifiedGraphReadBand(
    const N60DSPGraphSnapshot * _Nonnull s, uint32_t index, N60UnifiedGraphBand * _Nonnull out
) {
    if (index >= s->eqBandCount || index >= N60_MAX_EQ_RENDER_SLOTS) return false;
    const N60BiquadBandSnapshot *b = &s->eqBands[index];
    out->enabled = b->enabled;
    out->type = (int32_t)b->type;
    out->frequencyHz = b->frequencyHz;
    out->gainDB = b->gainDB;
    out->q = b->q;
    out->channelMask = s->eqBandChannelMasks[index];
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
