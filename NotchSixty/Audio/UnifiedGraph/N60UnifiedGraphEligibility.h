#ifndef N60UnifiedGraphEligibility_h
#define N60UnifiedGraphEligibility_h

// E6 S8: decides, on the control thread, whether a kernel DSP snapshot can be rendered
// by libn60core without changing what the listener hears. Anything the core stages do
// not yet reproduce keeps the kernel path (the stereo callback falls back per snapshot).
// Pure function of the snapshot; no allocation; never called from the audio callback.

#include <stdbool.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

#include "../Realtime/N60RenderKernel.h"

#ifdef __cplusplus
extern "C" {
#endif

// Mirrors N60_GRAPH_MAX_DELAY_FRAMES in core/include/n60/graph.h without including it here.
#define N60_GRAPH_MAX_DELAY_FRAMES_C 4194304u

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

// ---- verified parameter recovery ---------------------------------------------------------
// The kernel snapshot stores filter coefficients and smoothing poles, not the user's numbers.
// Each function below recovers the numbers, rebuilds the kernel's own snapshot from them with
// the kernel's own setter and accepts only a match (to float rounding), so a snapshot the core
// cannot reproduce keeps the kernel path instead of being approximated.

static inline bool N60UnifiedGraphClose(float a, float b) {
    return fabsf(a - b) <= 1.0e-6f * fmaxf(1.0f, fmaxf(fabsf(a), fabsf(b)));
}

// Time constant in ms of a one-pole coefficient exp(-1 / (rate * ms / 1000)). The float pole
// cannot pin the time down exactly at high rates, so a round value (0.01 ms grid) that yields
// the very same float pole wins over the raw inverse.
static inline bool N60UnifiedGraphMsFromPole(double rate, float pole, float * _Nonnull ms) {
    if (!(pole > 0.0f && pole < 1.0f)) return false;
    const double value = -1000.0 / (rate * log((double)pole));
    if (!isfinite(value)) return false;
    const double snapped = floor(value * 100.0 + 0.5) / 100.0;
    if (snapped >= 0.01 && (float)exp(-1.0 / (rate * snapped / 1000.0)) == pole) {
        *ms = (float)snapped;
    } else {
        *ms = (float)value;
    }
    return true;
}

static inline bool N60UnifiedGraphCoefficientsClose(N60BiquadCoefficients a, N60BiquadCoefficients b) {
    return N60UnifiedGraphClose(a.b0, b.b0) && N60UnifiedGraphClose(a.b1, b.b1)
        && N60UnifiedGraphClose(a.b2, b.b2) && N60UnifiedGraphClose(a.a1, b.a1)
        && N60UnifiedGraphClose(a.a2, b.a2);
}

// Sidechain high-pass back to Hz; 0 when it is the identity. The float coefficients cannot be
// inverted precisely at high rates, so the kernel's own design is searched on a 0.5 Hz grid and
// only an exact match is accepted.
static inline bool N60UnifiedGraphSidechainHz(double rate, N60BiquadCoefficients c, float * _Nonnull hz) {
    if (c.b0 == 1.0f && c.b1 == 0.0f && c.b2 == 0.0f && c.a1 == 0.0f && c.a2 == 0.0f) {
        *hz = 0.0f;
        return true;
    }
    for (int k = 1; k <= 600; ++k) {
        const double f = 0.5 * (double)k;
        if (f >= rate * 0.45) break;
        N60BiquadCoefficients t;
        if (!N60BiquadDesign(N60BiquadFilterTypeHighPass, rate, f, 0.0, 0.7071067811865476, &t)) continue;
        if (t.b0 == c.b0 && t.b1 == c.b1 && t.b2 == c.b2 && t.a1 == c.a1 && t.a2 == c.a2) {
            *hz = (float)f;
            return true;
        }
    }
    return false;
}

// Compressor, in core parameter order: threshold dB, ratio, knee dB, attack ms, release ms,
// makeup dB, topology, program-dependent release, sidechain Hz, linked.
static inline bool N60UnifiedGraphCompressorParams(
    const N60DSPGraphSnapshot * _Nonnull s, float out[_Nonnull 10]
) {
    const N60CompressorSnapshot *c = &s->dynamics.compressor;
    const double rate = s->sampleRate;
    float attack = 0.0f, release = 0.0f, hz = 0.0f;
    if (!N60UnifiedGraphMsFromPole(rate, c->attackCoefficient, &attack)
        || !N60UnifiedGraphMsFromPole(rate, c->releaseCoefficient, &release)
        || !N60UnifiedGraphSidechainHz(rate, c->sidechainHighPass, &hz)) return false;
    N60DynamicsSnapshot rebuilt = {0};
    if (!N60DynamicsSnapshotSetCompressorAdvanced(
            &rebuilt, rate, true, c->thresholdDB, c->ratio, c->kneeWidthDB, attack, release,
            c->makeupGainDB, c->topology, c->programDependentRelease, hz)) return false;
    const N60CompressorSnapshot *r = &rebuilt.compressor;
    if (!N60UnifiedGraphClose(r->attackCoefficient, c->attackCoefficient)
        || !N60UnifiedGraphClose(r->releaseCoefficient, c->releaseCoefficient)
        || !N60UnifiedGraphClose(r->releaseFastCoefficient, c->releaseFastCoefficient)
        || !N60UnifiedGraphClose(r->releaseSlowCoefficient, c->releaseSlowCoefficient)
        || !N60UnifiedGraphCoefficientsClose(r->sidechainHighPass, c->sidechainHighPass)) return false;
    out[0] = c->thresholdDB; out[1] = c->ratio; out[2] = c->kneeWidthDB;
    out[3] = attack; out[4] = release; out[5] = c->makeupGainDB;
    out[6] = (float)c->topology; out[7] = c->programDependentRelease ? 1.0f : 0.0f;
    out[8] = hz; out[9] = 1.0f;
    return true;
}

// Expander: threshold dB, ratio, range dB, attack ms, release ms, linked.
static inline bool N60UnifiedGraphExpanderParams(
    const N60DSPGraphSnapshot * _Nonnull s, float out[_Nonnull 6]
) {
    const N60ExpanderSnapshot *e = &s->dynamics.expander;
    const double rate = s->sampleRate;
    float attack = 0.0f, release = 0.0f;
    if (!N60UnifiedGraphMsFromPole(rate, e->attackCoefficient, &attack)
        || !N60UnifiedGraphMsFromPole(rate, e->releaseCoefficient, &release)) return false;
    N60DynamicsSnapshot rebuilt = {0};
    if (!N60DynamicsSnapshotSetExpander(&rebuilt, rate, true, e->thresholdDB, e->ratio, e->rangeDB,
                                        attack, release)) return false;
    if (!N60UnifiedGraphClose(rebuilt.expander.attackCoefficient, e->attackCoefficient)
        || !N60UnifiedGraphClose(rebuilt.expander.releaseCoefficient, e->releaseCoefficient)) return false;
    out[0] = e->thresholdDB; out[1] = e->ratio; out[2] = e->rangeDB;
    out[3] = attack; out[4] = release; out[5] = 1.0f;
    return true;
}

// Pause gate: threshold dBFS, hysteresis dB, hold ms, fade-out ms, fade-in ms. The kernel gates
// after its output gain but before its master gain; the core folds the master gain into the
// output gain, so the threshold moves with it (the gate sees the same level relative to it).
static inline bool N60UnifiedGraphPauseGateParams(
    const N60DSPGraphSnapshot * _Nonnull s, float out[_Nonnull 5]
) {
    const N60PauseGateSnapshot *g = &s->dynamics.pauseGate;
    const double rate = s->sampleRate;
    float fadeOut = 0.0f, fadeIn = 0.0f;
    if (!N60UnifiedGraphMsFromPole(rate, g->fadeOutCoefficient, &fadeOut)
        || !N60UnifiedGraphMsFromPole(rate, g->fadeInCoefficient, &fadeIn)) return false;
    const float holdMs = (float)((double)g->holdFrames * 1000.0 / rate);
    N60DynamicsSnapshot rebuilt = {0};
    if (!N60DynamicsSnapshotSetPauseGate(&rebuilt, rate, true, g->thresholdDBFS, holdMs, fadeOut,
                                         fadeIn, g->hysteresisDB)) return false;
    const N60PauseGateSnapshot *r = &rebuilt.pauseGate;
    if (r->holdFrames != g->holdFrames
        || !N60UnifiedGraphClose(r->fadeOutCoefficient, g->fadeOutCoefficient)
        || !N60UnifiedGraphClose(r->fadeInCoefficient, g->fadeInCoefficient)
        || !N60UnifiedGraphClose(r->detectorAttackCoefficient, g->detectorAttackCoefficient)
        || !N60UnifiedGraphClose(r->detectorReleaseCoefficient, g->detectorReleaseCoefficient)) return false;
    const float threshold = g->thresholdDBFS + 20.0f * log10f(s->masterGainLinear);
    if (!(threshold >= -120.0f && threshold <= -20.0f)) return false;
    out[0] = threshold; out[1] = g->hysteresisDB; out[2] = holdMs; out[3] = fadeOut; out[4] = fadeIn;
    return true;
}

// Ambient compensation: level dB, then (Hz, dB, Q) for the low shelf, peak and high shelf. A band
// the kernel leaves off is a 0 dB band here, which the core designs as an identity.
static inline bool N60UnifiedGraphAmbientParams(
    const N60DSPGraphSnapshot * _Nonnull s, float out[_Nonnull 10]
) {
    const N60AmbientCompensationSnapshot *a = &s->ambientCompensation;
    if (!(a->levelGainLinear >= 0.001f && a->levelGainLinear <= 2.0f)) return false;
    static const N60BiquadFilterType types[3] = {
        N60BiquadFilterTypeLowShelf, N60BiquadFilterTypePeaking, N60BiquadFilterTypeHighShelf
    };
    out[0] = 20.0f * log10f(a->levelGainLinear);
    for (uint32_t k = 0; k < 3; ++k) {
        const N60BiquadBandSnapshot *b = &a->bands[k];
        if (b->type != types[k]) return false;
        const bool on = b->enabled;
        if (!(b->frequencyHz > 0.0 && b->frequencyHz < s->sampleRate * 0.5 && b->q > 0.0)) return false;
        if (on && !(b->gainDB >= -24.0 && b->gainDB <= 24.0)) return false;
        out[1 + 3 * k] = (float)b->frequencyHz;
        out[2 + 3 * k] = on ? (float)b->gainDB : 0.0f;
        out[3 + 3 * k] = (float)b->q;
    }
    return true;
}

// Inter-channel delay as whole frames per lane, or false for the fractional (Thiran) case.
static inline bool N60UnifiedGraphIntegerDelay(
    const N60DSPGraphSnapshot * _Nonnull s, uint32_t frames[_Nonnull 2]
) {
    const N60InterChannelDelaySnapshot *d = &s->interChannelDelay;
    if (d->left.order != 0u || d->right.order != 0u) return false;
    if (d->left.integerFrames > N60_GRAPH_MAX_DELAY_FRAMES_C
        || d->right.integerFrames > N60_GRAPH_MAX_DELAY_FRAMES_C) return false;
    frames[0] = d->left.integerFrames;
    frames[1] = d->right.integerFrames;
    return true;
}

// Fractional inter-channel delay (Thiran all-pass, ABI v11 FRAC_DELAY): the total delay in frames of each
// lane, recovered from the signed delay and the rate and verified by redesigning the taps and comparing
// them with the snapshot's, so any other tap source keeps the kernel.
static inline bool N60UnifiedGraphFractionalDelay(
    const N60DSPGraphSnapshot * _Nonnull s, double total[_Nonnull 2]
) {
    const N60InterChannelDelaySnapshot *d = &s->interChannelDelay;
    if (!d->enabled || d->commonLatencyFrames != N60_FRACTIONAL_DELAY_COMMON_FRAMES) return false;
    N60InterChannelDelaySnapshot rebuilt;
    if (!N60InterChannelDelaySnapshotMake(s->sampleRate, d->signedDelayMs, &rebuilt)) return false;
    const N60FractionalDelayTap *want[2] = {&rebuilt.left, &rebuilt.right};
    const N60FractionalDelayTap *have[2] = {&d->left, &d->right};
    for (int lane = 0; lane < 2; ++lane) {
        if (want[lane]->integerFrames != have[lane]->integerFrames || want[lane]->order != have[lane]->order) return false;
        for (uint32_t k = 0; k <= want[lane]->order; ++k) {
            if (want[lane]->denominator[k] != have[lane]->denominator[k]) return false;
        }
    }
    const double relative = fabs(d->signedDelayMs) * s->sampleRate / 1000.0;
    const double common = (double)N60_FRACTIONAL_DELAY_COMMON_FRAMES;
    if (!(common + relative < 8190.0)) return false;
    total[0] = d->signedDelayMs > 0.0 ? common : common + relative;
    total[1] = d->signedDelayMs > 0.0 ? common + relative : common;
    return true;
}

// Spectral denoiser, in core parameter order: tuning, quality, reduction, threshold dBFS,
// protected range on, protected low Hz, protected high Hz, profile command, profile revision.
// The kernel derives its smoothing, FFT size and latency from tuning and quality alone, and the
// core derives the same set from the same two numbers, so the rebuilt snapshot must match all of
// them exactly (an advanced-tuning override does not, and keeps the kernel). Profile commands are
// passed through: the core carries the profile and the last revision across rebuilds and hand-overs
// (ABI v9), so a command runs once per revision, as in the kernel.
static inline bool N60UnifiedGraphDenoiserParams(
    const N60DSPGraphSnapshot * _Nonnull s, float out[_Nonnull 9]
) {
    const N60SpectralDenoiserSnapshot *d = &s->dynamics.spectralDenoiser;
    if (d->profileRevision > 16777216u) return false;
    N60SpectralDenoiserSnapshot rebuilt = N60SpectralDenoiserSnapshotMakeBypassed(s->sampleRate);
    if (!N60SpectralDenoiserSnapshotConfigure(
            &rebuilt, s->sampleRate, true, d->tuning, d->quality, d->reductionAmount, d->thresholdDBFS,
            d->protectedRangeEnabled, d->protectedLowHz, d->protectedHighHz, d->profileRevision,
            d->profileCommand)) return false;
    if (rebuilt.fftSize != d->fftSize || rebuilt.hopSize != d->hopSize
        || rebuilt.latencyFrames != d->latencyFrames
        || rebuilt.minimumGain != d->minimumGain
        || rebuilt.decisionDirectedAlpha != d->decisionDirectedAlpha
        || rebuilt.suppressionAttack != d->suppressionAttack
        || rebuilt.suppressionRelease != d->suppressionRelease
        || rebuilt.spectralSmoothingRadius != d->spectralSmoothingRadius
        || rebuilt.dehissStrength != d->dehissStrength) return false;
    out[0] = (float)d->tuning; out[1] = (float)d->quality; out[2] = d->reductionAmount;
    out[3] = d->thresholdDBFS; out[4] = d->protectedRangeEnabled ? 1.0f : 0.0f;
    out[5] = d->protectedLowHz; out[6] = d->protectedHighHz;
    out[7] = (float)d->profileCommand; out[8] = (float)d->profileRevision;
    return true;
}

// What the kernel's denoiser sees while it is switched off (ABI v9 park view): FFT size of the quality
// setting, profile revision and command. The kernel keeps its profile while off, applies a Reset command
// and drops the profile on a quality change, all of which the core reproduces from these three numbers. A
// Capture command while off stays with the kernel: it keeps recording while the denoiser is off, which a
// graph without the stage cannot. Returns false when the kernel must keep the snapshot.
static inline bool N60UnifiedGraphDenoiserParkView(
    const N60DSPGraphSnapshot * _Nonnull s, uint32_t out[_Nonnull 3]
) {
    const N60SpectralDenoiserSnapshot *d = &s->dynamics.spectralDenoiser;
    if (d->profileCommand == N60DenoiserProfileCommandCapture) return false;
    if (d->profileRevision > 16777216u) return false;
    if (d->fftSize != 1024u && d->fftSize != 2048u && d->fftSize != 4096u) return false;
    out[0] = d->fftSize; out[1] = d->profileRevision; out[2] = (uint32_t)d->profileCommand;
    return true;
}

// Dynamic EQ, in core parameter order: linked, then 15 numbers per enabled band (shape, Hz, Q,
// static dB, threshold dB, ratio, range dB, attack ms, release ms, direction, boost threshold dB,
// boost ratio, max boost dB, detector mode, RMS window ms). *count is the number of floats
// written (1 + 15 per band) or 0 when no band is enabled, in which case the stage is left out.
// Linked stereo maps to the core's linked group and dual mono to per-lane detectors, but only
// when the kernel's second (right-channel) band set equals the first, which is all the core can
// express. Mid/side is not representable and keeps the kernel.
#define N60_UNIFIED_DYN_EQ_MAX_PARAMS 961u /* 1 + 15 * N60_DYNAMIC_EQ_MAX_BANDS (64) */

static inline bool N60UnifiedGraphDynamicEQBandParams(
    double rate, const N60DynamicEQBandSnapshot * _Nonnull b, float out[_Nonnull 15]
) {
    float attack = 0.0f, release = 0.0f, rms = 0.0f;
    if (!N60UnifiedGraphMsFromPole(rate, b->attackCoefficient, &attack)
        || !N60UnifiedGraphMsFromPole(rate, b->releaseCoefficient, &release)
        || !N60UnifiedGraphMsFromPole(rate, b->rmsCoefficient, &rms)) return false;
    N60DynamicEQSnapshot rebuilt = N60DynamicEQSnapshotMakeBypassed(rate);
    if (!N60DynamicEQSnapshotSetBandForLane(
            &rebuilt, rate, N60DynamicEQLanePrimary, 0u, true, b->shape, b->frequencyHz, b->q,
            b->staticGainDB, b->thresholdDB, b->ratio, b->rangeDB, attack, release, b->direction,
            b->boostThresholdDB, b->boostRatio, b->maxBoostDB, b->detectorMode, rms)) return false;
    const N60DynamicEQBandSnapshot *r = &rebuilt.bands[0];
    if (!N60UnifiedGraphClose(r->attackCoefficient, b->attackCoefficient)
        || !N60UnifiedGraphClose(r->releaseCoefficient, b->releaseCoefficient)
        || !N60UnifiedGraphClose(r->rmsCoefficient, b->rmsCoefficient)) return false;
    const N60DynamicEQBiquadCoefficients pairs[3][2] = {
        {r->analysisBandPass, b->analysisBandPass}, {r->basisPrimary, b->basisPrimary},
        {r->basisSecondary, b->basisSecondary}
    };
    for (int k = 0; k < 3; ++k) {
        if (pairs[k][0].b0 != pairs[k][1].b0 || pairs[k][0].b1 != pairs[k][1].b1
            || pairs[k][0].b2 != pairs[k][1].b2 || pairs[k][0].a1 != pairs[k][1].a1
            || pairs[k][0].a2 != pairs[k][1].a2) return false;
    }
    out[0] = (float)b->shape; out[1] = (float)b->frequencyHz; out[2] = b->q;
    out[3] = b->staticGainDB; out[4] = b->thresholdDB; out[5] = b->ratio; out[6] = b->rangeDB;
    out[7] = attack; out[8] = release; out[9] = (float)b->direction;
    out[10] = b->boostThresholdDB; out[11] = b->boostRatio; out[12] = b->maxBoostDB;
    out[13] = (float)b->detectorMode; out[14] = rms;
    return true;
}

static inline bool N60UnifiedGraphDynamicEQParams(
    const N60DSPGraphSnapshot * _Nonnull s, float out[_Nonnull N60_UNIFIED_DYN_EQ_MAX_PARAMS],
    uint32_t * _Nonnull count
) {
    const N60DynamicEQSnapshot *q = &s->dynamics.dynamicEQ;
    const double rate = s->sampleRate;
    *count = 0u;
    if (q->domain == N60DynamicEQDomainMidSide) return false;
    if (q->bandCount > N60_DYNAMIC_EQ_MAX_BANDS || q->secondaryBandCount > N60_DYNAMIC_EQ_MAX_BANDS) return false;
    const float transition = (float)exp(-1.0 / (rate * 0.005));
    if (!N60UnifiedGraphClose(q->bypassTransitionCoefficient, transition)) return false;
    const bool dual = q->domain == N60DynamicEQDomainDualMono;
    uint32_t bands = 0u;
    for (uint32_t i = 0; i < q->bandCount; ++i) {
        if (!q->bands[i].enabled) continue;
        if (!N60UnifiedGraphDynamicEQBandParams(rate, &q->bands[i], out + 1u + 15u * bands)) return false;
        bands += 1u;
    }
    if (dual) {
        uint32_t second = 0u;
        for (uint32_t i = 0; i < q->secondaryBandCount; ++i) {
            if (!q->secondaryBands[i].enabled) continue;
            float other[15];
            if (second >= bands
                || !N60UnifiedGraphDynamicEQBandParams(rate, &q->secondaryBands[i], other)
                || memcmp(other, out + 1u + 15u * second, sizeof other) != 0) return false;
            second += 1u;
        }
        if (second != bands) return false;
    }
    if (bands == 0u) return true;
    out[0] = dual ? 0.0f : 1.0f;
    *count = 1u + 15u * bands;
    return true;
}

// A convolution state the core can hold: 1..32768 taps (N60_FIR_MAX_TAPS), the kernel's 256-frame engine latency, and
// a declared latency within N60_GRAPH_MAX_DELAY_FRAMES. A disabled state is always acceptable.
static inline bool N60UnifiedGraphConvolutionState(const N60ConvolutionGraphState * _Nonnull c) {
    if (!c->enabled) return true;
    return c->programGeneration != 0 && c->tapCount >= 1u && c->tapCount <= 32768u
        && c->engineLatencyFrames == 256u && c->declaredLatencyFrames <= (1u << 22);
}

static inline N60UnifiedGraphUnsupportedReason N60UnifiedGraphSnapshotUnsupportedReason(
    const N60DSPGraphSnapshot * _Nonnull s
) {
    if (s->bypassed || s->auditionMode != N60AuditionModeProcessed) {
        return N60UnifiedGraphUnsupportedBypassOrAudition;
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
    if (s->symmetryBalance.enabled
            && !(s->symmetryBalance.position >= -1.0 && s->symmetryBalance.position <= 1.0)) {
        return N60UnifiedGraphUnsupportedSpatial;
    }
    if (s->speakerCrossfeed.enabled
            && !(s->speakerCrossfeed.amount >= 0.0f && s->speakerCrossfeed.amount <= 0.5f)) {
        return N60UnifiedGraphUnsupportedSpatial;
    }
    if (s->crosstalkCancellation.enabled
            && !(s->crosstalkCancellation.amount >= 0.0f && s->crosstalkCancellation.amount <= 1.0f
                 && s->crosstalkCancellation.headShadowFrequencyHz >= 200.0
                 && s->crosstalkCancellation.headShadowFrequencyHz <= 2000.0
                 && s->crosstalkCancellation.headShadowFrequencyHz < s->sampleRate * 0.5)) {
        return N60UnifiedGraphUnsupportedSpatial;
    }
    if (s->crossover.enabled) return N60UnifiedGraphUnsupportedCrossover;
    if (s->interChannelDelay.enabled) {
        uint32_t delayFrames[2];
        double fractional[2];
        if (!N60UnifiedGraphIntegerDelay(s, delayFrames) && !N60UnifiedGraphFractionalDelay(s, fractional)) {
            return N60UnifiedGraphUnsupportedDelay;
        }
    }
    const N60DynamicsSnapshot *d = &s->dynamics;
    if (d->stereoMode.mode != N60StereoModeStereo || d->stereoWidener.enabled
            || d->dcOffsetFilter.enabled || d->infrasonicFilter.enabled
            || d->mainsNotch.enabled || d->mainsHumDetector.enabled
            || d->loudnessMatch.enabled
            || d->loudnessContour.enabled || d->dialogueLeveler.enabled
            || d->deHarsh.enabled || d->deEsser.enabled
            || d->multibandCompressor.enabled) {
        return N60UnifiedGraphUnsupportedDynamics;
    }
    float scratch[10];
    if (d->spectralDenoiser.enabled && !N60UnifiedGraphDenoiserParams(s, scratch)) {
        return N60UnifiedGraphUnsupportedDynamics;
    }
    uint32_t parkView[3];
    if (!d->spectralDenoiser.enabled && !N60UnifiedGraphDenoiserParkView(s, parkView)) {
        return N60UnifiedGraphUnsupportedDynamics;
    }
    if (d->dynamicEQ.enabled && !s->eqBypassed) {
        // The kernel runs the dynamic EQ after the mid/side decode; the core runs it before.
        if (s->eqMidSideMode) return N60UnifiedGraphUnsupportedDynamics;
        float dynParams[N60_UNIFIED_DYN_EQ_MAX_PARAMS];
        uint32_t dynCount = 0u;
        if (!N60UnifiedGraphDynamicEQParams(s, dynParams, &dynCount)) return N60UnifiedGraphUnsupportedDynamics;
    }
    if (d->compressor.enabled && !N60UnifiedGraphCompressorParams(s, scratch)) {
        return N60UnifiedGraphUnsupportedDynamics;
    }
    if (d->expander.enabled && !N60UnifiedGraphExpanderParams(s, scratch)) {
        return N60UnifiedGraphUnsupportedDynamics;
    }
    if (d->pauseGate.enabled && !N60UnifiedGraphPauseGateParams(s, scratch)) {
        return N60UnifiedGraphUnsupportedDynamics;
    }
    // The kernel runs ambient before its dynamics, the core after the compressor and expander.
    if (s->ambientCompensation.enabled && (d->compressor.enabled || d->expander.enabled)) {
        return N60UnifiedGraphUnsupportedAmbientOrANC;
    }
    if (s->protection.softClipperEnabled || s->protection.gainRiderEnabled) {
        return N60UnifiedGraphUnsupportedProtection;
    }
    // E6 S8d: program FIR, room FIR and speaker IR. The snapshot carries no taps, so this only checks what the
    // core can hold and where the kernel runs the stage; the translator then recovers the taps by generation from
    // the control plane's retained program and verifies them against this record (see UnifiedGraphFIRProgram).
    if (s->convolution.enabled || s->roomCorrection.enabled || s->speakerIR.enabled) {
        if (!N60UnifiedGraphConvolutionState(&s->convolution) || !N60UnifiedGraphConvolutionState(&s->roomCorrection)
                || !N60UnifiedGraphConvolutionState(&s->speakerIR)) {
            return N60UnifiedGraphUnsupportedConvolution;
        }
        // The kernel runs the program convolution inside the mid/side pair and before the dynamic EQ; the core
        // runs the FIR after both.
        if (s->convolution.enabled && (s->eqMidSideMode || (d->dynamicEQ.enabled && !s->eqBypassed))) {
            return N60UnifiedGraphUnsupportedConvolution;
        }
        // The kernel runs the expander after the room and speaker convolvers; the core has no expander position
        // there (the compressor moves to CORE_DYNAMICS).
        if ((s->roomCorrection.enabled || s->speakerIR.enabled) && d->expander.enabled) {
            return N60UnifiedGraphUnsupportedConvolution;
        }
    }
    if (s->activeQuietZone.enabled) return N60UnifiedGraphUnsupportedAmbientOrANC;
    if (s->ambientCompensation.enabled && !N60UnifiedGraphAmbientParams(s, scratch)) {
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
