/* E33 S20 part 3 (G77), S27: the production linear-phase designer (the core's n60_eq_linear_phase_design) behind a
 * C-callable function. bands = count triples (frequencyHz, gainDB, q), all peaking. Returns the tap count, or 0 on failure. */
#include <stdint.h>
#include "n60/graph.h"

uint32_t e33_lab_design(double rate, const double *bands, uint32_t count, float *taps, uint32_t capacity, uint32_t *latency) {
    float sections[8 * 5];
    if (count > 8) return 0;
    for (uint32_t i = 0; i < count; ++i) {
        double c[5];
        if (n60_eq_design_section(0, rate, bands[3 * i], bands[3 * i + 1], bands[3 * i + 2], c) != 1) return 0;
        for (int k = 0; k < 5; ++k) sections[5 * i + k] = (float)c[k];
    }
    /* The default length: rate / 46.875 frames, between 512 and 8192 (EQLinearPhaseLength.ms21). */
    double want = rate / 46.875 + 0.5;
    uint32_t delay = (uint32_t)(want < 512.0 ? 512.0 : (want > 8192.0 ? 8192.0 : want));
    n60_eq_linear_phase_report report;
    if (n60_eq_linear_phase_design(rate, delay, sections, count, taps, capacity, &report) != 1) return 0;
    *latency = report.groupDelayFrames;
    return report.tapCount;
}
