/* E33 S20 part 3 (G77): the production linear-phase designer (N60LinearPhaseEQ.h, C) behind a C++-callable function.
 * bands = count triples (frequencyHz, gainDB, q), all peaking. Returns the tap count, or 0 on failure. */
#include <stdint.h>
#include "N60LinearPhaseEQ.h"

uint32_t e33_lab_design(double rate, const double *bands, uint32_t count, float *taps, uint32_t capacity, uint32_t *latency) {
    N60LinearPhaseEQBand b[8];
    if (count > 8) return 0;
    for (uint32_t i = 0; i < count; ++i) {
        b[i].enabled = true;
        b[i].type = N60BiquadFilterTypePeaking;
        b[i].frequencyHz = bands[3 * i];
        b[i].gainDB = bands[3 * i + 1];
        b[i].q = bands[3 * i + 2];
        b[i].usesPreparedCoefficients = false;
        b[i].preparedCoefficients = (N60BiquadCoefficients){0};
    }
    N60LinearPhaseEQDesignInfo info = {0};
    if (!N60LinearPhaseEQDesign(rate, b, count, taps, capacity, &info)) return 0;
    *latency = info.groupDelayFrames;
    return info.tapCount;
}
