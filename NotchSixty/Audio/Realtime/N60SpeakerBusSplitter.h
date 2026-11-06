#ifndef N60SpeakerBusSplitter_h
#define N60SpeakerBusSplitter_h

/*
 * E26 S7b: the speaker bus splitter (mains / sub / tri-amp tree), shared by the Core Audio bridge and the
 * Quiet Zone lane feed so that the path the sweeps measure (N60SpeakerBusRenderFeed) is the path the live
 * anti-noise plays. No Apple framework. Moved from N60RealtimeAudioBridge.c unchanged.
 *
 * Realtime contract: Process never allocates, locks or logs. The runtime is plain state the owner zeroes to
 * reset. Frames are one stereo pair in, N60_SPLITTER_BUS_COUNT values out (indexes below equal
 * N60SpeakerOutputBus). Latency 0. Any sample rate the snapshot was designed for.
 */

#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#include "N60Crossover.h"

#ifdef __cplusplus
extern "C" {
#endif

enum {
    N60_SPLITTER_BUS_LEFT_FULL = 0,
    N60_SPLITTER_BUS_RIGHT_FULL = 1,
    N60_SPLITTER_BUS_LEFT_LOW = 2,
    N60_SPLITTER_BUS_RIGHT_LOW = 3,
    N60_SPLITTER_BUS_LEFT_MID = 4,
    N60_SPLITTER_BUS_RIGHT_MID = 5,
    N60_SPLITTER_BUS_LEFT_HIGH = 6,
    N60_SPLITTER_BUS_RIGHT_HIGH = 7,
    N60_SPLITTER_BUS_SUB_MONO = 8,
    N60_SPLITTER_BUS_COUNT = 9
};

typedef struct {
    N60SpeakerBusSplitterSnapshot snapshot;
    N60CrossoverPreciseState lowerLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerLowMono[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowerHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState upperHighRight[N60_MAX_CROSSOVER_SECTIONS];
    // Tri-amp phase compensation: the low band passes through the upper
    // crossover's all-pass (LP2 + HP2) so the three bands sum flat.
    N60CrossoverPreciseState lowAllPassLowLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowAllPassLowRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowAllPassHighLeft[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState lowAllPassHighRight[N60_MAX_CROSSOVER_SECTIONS];
    N60CrossoverPreciseState subPhaseAlignment;
} N60SpeakerBusSplitterRuntime;

/* A non-finite value leaves the bus at 0, as N60SpeakerBusFrameSet always did. */
static inline void N60SplitterSet(float *values, uint32_t bus, float value) {
    if (isfinite(value)) values[bus] = value;
}

static inline float N60SplitterProcessSections(
    const N60CrossoverPreciseCoefficients *coefficients,
    N60CrossoverPreciseState *states,
    uint32_t count,
    float input
) {
    float output = input;
    for (uint32_t index = 0; index < count; ++index) {
        output = N60CrossoverPreciseProcessSample(coefficients[index], &states[index], output);
    }
    return output;
}

static inline void N60SpeakerBusSplitterProcess(
    N60SpeakerBusSplitterRuntime *runtime,
    float left,
    float right,
    float *values
) {
    for (uint32_t bus = 0; bus < N60_SPLITTER_BUS_COUNT; ++bus) values[bus] = 0.0f;
    N60SplitterSet(values, N60_SPLITTER_BUS_LEFT_FULL, left);
    N60SplitterSet(values, N60_SPLITTER_BUS_RIGHT_FULL, right);
    if (!runtime->snapshot.enabled) return;

    const N60SpeakerBusSplitterSnapshot *snapshot = &runtime->snapshot;
    if (snapshot->mode == N60SpeakerCrossoverModeMainsSub) {
        float mainsLeft = N60SplitterProcessSections(
            snapshot->lowerHighPass, runtime->lowerHighLeft,
            snapshot->lowerSectionCount, left
        );
        float mainsRight = N60SplitterProcessSections(
            snapshot->lowerHighPass, runtime->lowerHighRight,
            snapshot->lowerSectionCount, right
        );
        float subMono = 0.5f * (left + right);
        subMono = N60SplitterProcessSections(
            snapshot->lowerLowPass, runtime->lowerLowMono,
            snapshot->lowerSectionCount, subMono
        );
        if (snapshot->subPhaseAlignmentEnabled) {
            subMono = N60CrossoverPreciseProcessSample(
                snapshot->subPhaseAlignmentAllPass,
                &runtime->subPhaseAlignment,
                subMono
            );
        }
        subMono *= snapshot->subGainLinear;
        if (snapshot->subPolarityInverted) subMono = -subMono;
        N60SplitterSet(values, N60_SPLITTER_BUS_LEFT_HIGH, mainsLeft);
        N60SplitterSet(values, N60_SPLITTER_BUS_RIGHT_HIGH, mainsRight);
        N60SplitterSet(values, N60_SPLITTER_BUS_SUB_MONO, subMono);
        return;
    }

    float lowLeft = N60SplitterProcessSections(
        snapshot->lowerLowPass, runtime->lowerLowLeft,
        snapshot->lowerSectionCount, left
    );
    float lowRight = N60SplitterProcessSections(
        snapshot->lowerLowPass, runtime->lowerLowRight,
        snapshot->lowerSectionCount, right
    );

    if (snapshot->mode == N60SpeakerCrossoverModeBiAmp) {
        N60SplitterSet(values, N60_SPLITTER_BUS_LEFT_LOW, lowLeft);
        N60SplitterSet(values, N60_SPLITTER_BUS_RIGHT_LOW, lowRight);
        float highLeft = N60SplitterProcessSections(
            snapshot->lowerHighPass, runtime->lowerHighLeft,
            snapshot->lowerSectionCount, left
        );
        float highRight = N60SplitterProcessSections(
            snapshot->lowerHighPass, runtime->lowerHighRight,
            snapshot->lowerSectionCount, right
        );
        N60SplitterSet(values, N60_SPLITTER_BUS_LEFT_HIGH, highLeft);
        N60SplitterSet(values, N60_SPLITTER_BUS_RIGHT_HIGH, highRight);
        return;
    }

    // Tri-amp Linkwitz-Riley tree:
    //   low  = LP1 · (LP2 + HP2)   (upper all-pass compensation)
    //   mid  = HP1 · LP2
    //   high = HP1 · HP2
    // so low + mid + high = AP1 · AP2, an all-pass with flat magnitude.
    lowLeft = N60SplitterProcessSections(
            snapshot->upperLowPass, runtime->lowAllPassLowLeft,
            snapshot->upperSectionCount, lowLeft
        )
        + N60SplitterProcessSections(
            snapshot->upperHighPass, runtime->lowAllPassHighLeft,
            snapshot->upperSectionCount, lowLeft
        );
    lowRight = N60SplitterProcessSections(
            snapshot->upperLowPass, runtime->lowAllPassLowRight,
            snapshot->upperSectionCount, lowRight
        )
        + N60SplitterProcessSections(
            snapshot->upperHighPass, runtime->lowAllPassHighRight,
            snapshot->upperSectionCount, lowRight
        );
    N60SplitterSet(values, N60_SPLITTER_BUS_LEFT_LOW, lowLeft);
    N60SplitterSet(values, N60_SPLITTER_BUS_RIGHT_LOW, lowRight);

    const float upperLeft = N60SplitterProcessSections(
        snapshot->lowerHighPass, runtime->lowerHighLeft,
        snapshot->lowerSectionCount, left
    );
    const float upperRight = N60SplitterProcessSections(
        snapshot->lowerHighPass, runtime->lowerHighRight,
        snapshot->lowerSectionCount, right
    );
    const float midLeft = N60SplitterProcessSections(
        snapshot->upperLowPass, runtime->upperLowLeft,
        snapshot->upperSectionCount, upperLeft
    );
    const float midRight = N60SplitterProcessSections(
        snapshot->upperLowPass, runtime->upperLowRight,
        snapshot->upperSectionCount, upperRight
    );
    const float highLeft = N60SplitterProcessSections(
        snapshot->upperHighPass, runtime->upperHighLeft,
        snapshot->upperSectionCount, upperLeft
    );
    const float highRight = N60SplitterProcessSections(
        snapshot->upperHighPass, runtime->upperHighRight,
        snapshot->upperSectionCount, upperRight
    );
    N60SplitterSet(values, N60_SPLITTER_BUS_LEFT_MID, midLeft);
    N60SplitterSet(values, N60_SPLITTER_BUS_RIGHT_MID, midRight);
    N60SplitterSet(values, N60_SPLITTER_BUS_LEFT_HIGH, highLeft);
    N60SplitterSet(values, N60_SPLITTER_BUS_RIGHT_HIGH, highRight);
}


#ifdef __cplusplus
}
#endif

#endif
