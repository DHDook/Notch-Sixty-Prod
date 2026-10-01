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
    N60BiquadCoefficients subPhaseAlignmentAllPass;
    uint32_t sectionCount;
    N60BiquadCoefficients mainsHighPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients subLowPass[N60_MAX_CROSSOVER_SECTIONS];
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
    snapshot.subPhaseAlignmentAllPass = N60BiquadCoefficientsMakeIdentity();
    snapshot.sectionCount = 0;
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.mainsHighPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.subLowPass[index] = N60BiquadCoefficientsMakeIdentity();
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

    for (uint32_t index = 0; index < sectionCount; ++index) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeHighPass,
                sampleRate,
                frequencyHz,
                0.0,
                qValues[index],
                &designed.mainsHighPass[index])) {
            return false;
        }
        if (!N60BiquadDesign(
                N60BiquadFilterTypeLowPass,
                sampleRate,
                frequencyHz,
                0.0,
                qValues[index],
                &designed.subLowPass[index])) {
            return false;
        }
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

    N60BiquadCoefficients coefficients = N60BiquadCoefficientsMakeIdentity();
    if (enabled && !N60BiquadDesign(
            N60BiquadFilterTypeAllPass,
            sampleRate,
            frequencyHz,
            0.0,
            q,
            &coefficients)) {
        return false;
    }

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
    N60BiquadCoefficients subPhaseAlignmentAllPass;
    uint32_t lowerSectionCount;
    uint32_t upperSectionCount;
    N60BiquadCoefficients lowerLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients lowerHighPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients upperLowPass[N60_MAX_CROSSOVER_SECTIONS];
    N60BiquadCoefficients upperHighPass[N60_MAX_CROSSOVER_SECTIONS];
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
    snapshot.subPhaseAlignmentAllPass = N60BiquadCoefficientsMakeIdentity();
    for (uint32_t index = 0; index < N60_MAX_CROSSOVER_SECTIONS; ++index) {
        snapshot.lowerLowPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.lowerHighPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.upperLowPass[index] = N60BiquadCoefficientsMakeIdentity();
        snapshot.upperHighPass[index] = N60BiquadCoefficientsMakeIdentity();
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

    for (uint32_t index = 0; index < lowerCount; ++index) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeLowPass, sampleRate, lowerFrequencyHz,
                0.0, lowerQ[index], &designed.lowerLowPass[index])
            || !N60BiquadDesign(
                N60BiquadFilterTypeHighPass, sampleRate, lowerFrequencyHz,
                0.0, lowerQ[index], &designed.lowerHighPass[index])) {
            return false;
        }
    }

    if (mode == N60SpeakerCrossoverModeTriAmp) {
        double upperQ[N60_MAX_CROSSOVER_SECTIONS] = {0};
        uint32_t upperCount = 0;
        if (!N60CrossoverTopologyQValues(upperTopology, upperQ, &upperCount)) return false;
        designed.upperSectionCount = upperCount;
        for (uint32_t index = 0; index < upperCount; ++index) {
            if (!N60BiquadDesign(
                    N60BiquadFilterTypeLowPass, sampleRate, upperFrequencyHz,
                    0.0, upperQ[index], &designed.upperLowPass[index])
                || !N60BiquadDesign(
                    N60BiquadFilterTypeHighPass, sampleRate, upperFrequencyHz,
                    0.0, upperQ[index], &designed.upperHighPass[index])) {
                return false;
            }
        }
    }

    if (designed.subPhaseAlignmentEnabled) {
        if (!N60BiquadDesign(
                N60BiquadFilterTypeAllPass,
                sampleRate,
                subPhaseAlignmentFrequencyHz,
                0.0,
                subPhaseAlignmentQ,
                &designed.subPhaseAlignmentAllPass)) {
            return false;
        }
    }

    *snapshot = designed;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
