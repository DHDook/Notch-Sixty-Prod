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

#ifdef __cplusplus
}
#endif

#endif
