#ifndef N60Crossover_h
#define N60Crossover_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#include "N60Biquad.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MAX_CROSSOVER_SECTIONS 4

// Dedicated double-precision crossover SOS and states. At 384 kHz with an
// 80 Hz cutoff, float feedback coefficients near +/-2 and 1 lose enough
// significant digits to corrupt the bass response. Keep unrelated EQ ABI
// and processing unchanged. Design exclusively on the control plane.
typedef struct {
    double b0, b1, b2, a1, a2;
} N60CrossoverPreciseCoefficients;

typedef struct {
    double z1, z2;
} N60CrossoverPreciseState;

static inline N60CrossoverPreciseCoefficients N60CrossoverPreciseIdentity(void) {
    const N60CrossoverPreciseCoefficients c = {
        .b0 = 1.0, .b1 = 0.0, .b2 = 0.0, .a1 = 0.0, .a2 = 0.0
    };
    return c;
}

static inline bool N60CrossoverPreciseDesign(
    N60BiquadFilterType type, double rate, double hz, double q,
    N60CrossoverPreciseCoefficients * _Nonnull out
) {
    if (!out || !isfinite(rate) || rate <= 0.0
        || !isfinite(hz) || hz <= 0.0 || hz >= 0.5 * rate
        || !isfinite(q) || q <= 0.0) return false;
    const double omega = 2.0 * M_PI * hz / rate;
    const double cosine = cos(omega);
    const double alpha = sin(omega) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    if (!isfinite(a0) || fabs(a0) < 1e-20) return false;
    N60CrossoverPreciseCoefficients c = {0};
    c.a1 = (-2.0 * cosine) / a0;
    c.a2 = (1.0 - alpha) / a0;
    switch (type) {
    case N60BiquadFilterTypeLowPass:
        c.b0 = (1.0 - cosine) / (2.0 * a0);
        c.b1 = 2.0 * c.b0;
        c.b2 = c.b0;
        break;
    case N60BiquadFilterTypeHighPass:
        c.b0 = (1.0 + cosine) / (2.0 * a0);
        c.b1 = -2.0 * c.b0;
        c.b2 = c.b0;
        break;
    case N60BiquadFilterTypeAllPass:
        c.b0 = (1.0 - alpha) / a0;
        c.b1 = (-2.0 * cosine) / a0;
        c.b2 = 1.0;
        break;
    default:
        return false;
    }
    if (!isfinite(c.b0) || !isfinite(c.b1) || !isfinite(c.b2)
        || !isfinite(c.a1) || !isfinite(c.a2)) return false;
    *out = c;
    return true;
}

// Realtime-safe, float input/output with double filter state. Never allocate,
// calculate coefficients, or lock in the audio render callback.
static inline float N60CrossoverPreciseProcessSample(
    N60CrossoverPreciseCoefficients c,
    N60CrossoverPreciseState * _Nonnull state, float input
) {
    const double x = (double)input;
    const double y = c.b0 * x + state->z1;
    state->z1 = c.b1 * x - c.a1 * y + state->z2;
    state->z2 = c.b2 * x - c.a2 * y;
    return (float)y;
}


typedef enum {
    N60CrossoverTopologyLinkwitzRiley24 = 0,
    N60CrossoverTopologyLinkwitzRiley48 = 1,
} N60CrossoverTopology;

typedef enum {
    N60CrossoverMonitorModeRecombined = 0,
    N60CrossoverMonitorModeMainsOnly = 1,
    N60CrossoverMonitorModeSubOnly = 2,
} N60CrossoverMonitorMode;

typedef struct {
    bool enabled;
    double frequencyHz;
    N60CrossoverTopology topology;
    N60CrossoverMonitorMode monitorMode;
    float subGainLinear;
    bool subPolarityInverted;
    bool subPhaseAlignmentEnabled;
    double subPhaseAlignmentFrequencyHz;
    double subPhaseAlignmentQ;
    N60CrossoverPreciseCoefficients subPhaseAlignmentAllPass;
    uint32_t sectionCount;
    N60CrossoverPreciseCoefficients mainsHighPass[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseCoefficients subLowPass[N60_MAX_CROSSOVER_SECTIONS];
} N60CrossoverSnapshot;

static inline N60CrossoverSnapshot N60CrossoverSnapshotMakeBypassed(void) {
    N60CrossoverSnapshot snapshot = {0};
    snapshot.enabled = false;
    snapshot.frequencyHz = 80.0;
    snapshot.topology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.monitorMode = N60CrossoverMonitorModeRecombined;
    snapshot.subGainLinear = 1.0f;
    snapshot.subPolarityInverted = false;
    snapshot.subPhaseAlignmentEnabled = false;
    snapshot.subPhaseAlignmentFrequencyHz = 80.0;
    snapshot.subPhaseAlignmentQ = 0.7;
    snapshot.subPhaseAlignmentAllPass = N60CrossoverPreciseIdentity();
    snapshot.sectionCount = 0;
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.mainsHighPass[index] = N60CrossoverPreciseIdentity();
        snapshot.subLowPass[index] = N60CrossoverPreciseIdentity();
    }
    return snapshot;
}

static inline bool N60CrossoverTopologyQValues(
    N60CrossoverTopology topology,
    double * _Nonnull qValues,
    uint32_t * _Nonnull sectionCount
) {
    if (qValues == NULL || sectionCount == NULL) {
        return false;
    }

    switch (topology) {
    case N60CrossoverTopologyLinkwitzRiley24:
        // Linkwitz-Riley 4th order = two cascaded 2nd-order Butterworth sections.
        qValues[0] = 0.7071067811865476;
        qValues[1] = 0.7071067811865476;
        *sectionCount = 2;
        return true;
    case N60CrossoverTopologyLinkwitzRiley48:
        // Linkwitz-Riley 8th order = two cascaded 4th-order Butterworth filters.
        qValues[0] = 0.5411961001461970;
        qValues[1] = 1.3065629648763766;
        qValues[2] = 0.5411961001461970;
        qValues[3] = 1.3065629648763766;
        *sectionCount = 4;
        return true;
    default:
        return false;
    }
}

// Control-plane only. Designs complementary low/high-pass legs for one logical
// crossover. The realtime path consumes only the precomputed coefficients.
static inline bool N60CrossoverSnapshotMake(
    double sampleRate,
    double frequencyHz,
    N60CrossoverTopology topology,
    N60CrossoverMonitorMode monitorMode,
    float subGainLinear,
    bool subPolarityInverted,
    bool enabled,
    N60CrossoverSnapshot * _Nonnull snapshot
) {
    if (snapshot == NULL) {
        return false;
    }

    if (!enabled) {
        *snapshot = N60CrossoverSnapshotMakeBypassed();
        snapshot->frequencyHz = frequencyHz;
        snapshot->topology = topology;
        snapshot->monitorMode = monitorMode;
        snapshot->subGainLinear = subGainLinear;
        snapshot->subPolarityInverted = subPolarityInverted;
        return isfinite(frequencyHz)
            && frequencyHz > 0.0
            && isfinite(subGainLinear)
            && subGainLinear >= 0.0f;
    }

    if (!isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(subGainLinear) || subGainLinear < 0.0f
        || monitorMode < N60CrossoverMonitorModeRecombined
        || monitorMode > N60CrossoverMonitorModeSubOnly) {
        return false;
    }

    double qValues[N60_MAX_CROSSOVER_SECTIONS] = {0};
    uint32_t sectionCount = 0;
    if (!N60CrossoverTopologyQValues(topology, qValues, &sectionCount)) {
        return false;
    }

    N60CrossoverSnapshot designed = N60CrossoverSnapshotMakeBypassed();
    designed.enabled = true;
    designed.frequencyHz = frequencyHz;
    designed.topology = topology;
    designed.monitorMode = monitorMode;
    designed.subGainLinear = subGainLinear;
    designed.subPolarityInverted = subPolarityInverted;
    designed.sectionCount = sectionCount;

    for (uint32_t i = 0; i < sectionCount; ++i) {
        if (!N60CrossoverPreciseDesign(
                N60BiquadFilterTypeHighPass, sampleRate, frequencyHz,
                qValues[i], &designed.mainsHighPass[i])
            || !N60CrossoverPreciseDesign(
                N60BiquadFilterTypeLowPass, sampleRate, frequencyHz,
                qValues[i], &designed.subLowPass[i])) return false;
    }

    *snapshot = designed;
    return true;
}


static inline bool N60CrossoverSnapshotSetSubPhaseAlignment(
    double sampleRate,
    double frequencyHz,
    double q,
    bool enabled,
    N60CrossoverSnapshot * _Nonnull snapshot
) {
    if (snapshot == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(frequencyHz) || frequencyHz <= 0.0 || frequencyHz >= sampleRate * 0.5
        || !isfinite(q) || q <= 0.0) {
        return false;
    }

    N60CrossoverPreciseCoefficients coefficients =
        N60CrossoverPreciseIdentity();
    if (enabled && !N60CrossoverPreciseDesign(
            N60BiquadFilterTypeAllPass, sampleRate, frequencyHz, q,
            &coefficients)) return false;

    snapshot->subPhaseAlignmentEnabled = enabled;
    snapshot->subPhaseAlignmentFrequencyHz = frequencyHz;
    snapshot->subPhaseAlignmentQ = q;
    snapshot->subPhaseAlignmentAllPass = coefficients;
    return true;
}


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
    N60CrossoverPreciseCoefficients subPhaseAlignmentAllPass;
    uint32_t lowerSectionCount;
    uint32_t upperSectionCount;
    N60CrossoverPreciseCoefficients lowerLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseCoefficients lowerHighPass[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseCoefficients upperLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseCoefficients upperHighPass[N60_MAX_CROSSOVER_SECTIONS];
} N60SpeakerBusSplitterSnapshot;

static inline N60SpeakerBusSplitterSnapshot N60SpeakerBusSplitterSnapshotMakeBypassed(void) {
    N60SpeakerBusSplitterSnapshot snapshot = {0};
    snapshot.enabled = false;
    snapshot.mode = N60SpeakerCrossoverModeMainsSub;
    snapshot.lowerFrequencyHz = 80.0;
    snapshot.lowerTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.upperFrequencyHz = 2000.0;
    snapshot.upperTopology = N60CrossoverTopologyLinkwitzRiley24;
    snapshot.subGainLinear = 1.0f;
    snapshot.subPhaseAlignmentFrequencyHz = 80.0;
    snapshot.subPhaseAlignmentQ = 0.7;
    snapshot.subPhaseAlignmentAllPass = N60CrossoverPreciseIdentity();
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.lowerLowPass[index] = N60CrossoverPreciseIdentity();
        snapshot.lowerHighPass[index] = N60CrossoverPreciseIdentity();
        snapshot.upperLowPass[index] = N60CrossoverPreciseIdentity();
        snapshot.upperHighPass[index] = N60CrossoverPreciseIdentity();
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

    for (uint32_t i = 0; i < lowerCount; ++i) {
        if (!N60CrossoverPreciseDesign(
                N60BiquadFilterTypeLowPass, sampleRate, lowerFrequencyHz,
                lowerQ[i], &designed.lowerLowPass[i])
            || !N60CrossoverPreciseDesign(
                N60BiquadFilterTypeHighPass, sampleRate, lowerFrequencyHz,
                lowerQ[i], &designed.lowerHighPass[i])) return false;
    }

    if (mode == N60SpeakerCrossoverModeTriAmp) {
        double upperQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
        uint32_t upperCount = 0;
        if (!N60CrossoverTopologyQValues(upperTopology, upperQ, &upperCount)) return false;
        designed.upperSectionCount = upperCount;
        for (uint32_t i = 0; i < upperCount; ++i) {
            if (!N60CrossoverPreciseDesign(
                    N60BiquadFilterTypeLowPass, sampleRate, upperFrequencyHz,
                    upperQ[i], &designed.upperLowPass[i])
                || !N60CrossoverPreciseDesign(
                    N60BiquadFilterTypeHighPass, sampleRate, upperFrequencyHz,
                    upperQ[i], &designed.upperHighPass[i])) return false;
        }
    }

    if (designed.subPhaseAlignmentEnabled) {
        if (!N60CrossoverPreciseDesign(
                N60BiquadFilterTypeAllPass, sampleRate,
                subPhaseAlignmentFrequencyHz, subPhaseAlignmentQ,
                &designed.subPhaseAlignmentAllPass)) return false;
    }

    *snapshot = designed;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
