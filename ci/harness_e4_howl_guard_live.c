/*
 * E4 S15: behavioural harness for the live howl guard in the render kernel. At the eight standard
 * rates, with silent program audio and a live tonal canceller:
 *  - with no guard attached the output is unchanged (no trips);
 *  - a steady tone and the 3 s arm ramp-in never trip the guard;
 *  - a runaway level rise (0.004 to 0.06 linear in 30 ms, +23 dB) trips the growth check within
 *    50 ms plus one 256-frame chunk (the guard needs three growing blocks), fades the
 *    anti-noise to exact silence, counts one trip and stays latched;
 *  - Rearm brings the (steady) tone back with no second trip; Detach removes the guard.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60AncGuard.h"
#include "N60RenderKernel.h"

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

#define BLOCK 128u

/* Renders `frames` of silence in BLOCK callbacks. Reports the peak of the last 10 ms and the
 * frame (from the start of this call) at which the trip count first exceeded `tripsBefore`
 * (UINT64_MAX when it did not). */
static void render(N60RenderKernel *k, double rate, uint64_t frames, uint64_t tripsBefore,
                   float *tailPeak, uint64_t *tripFrame) {
    *tailPeak = 0.0f;
    *tripFrame = UINT64_MAX;
    const uint64_t tail = (uint64_t)(rate * 0.010);
    uint64_t done = 0;
    while (done < frames) {
        const uint32_t n = (uint32_t)(frames - done < BLOCK ? frames - done : BLOCK);
        N60RenderKernelRenderContext ctx = N60RenderKernelBeginRender(k);
        for (uint32_t i = 0; i < n; ++i) {
            float l = 0.0f, r = 0.0f;
            N60RenderKernelProcessStereoFrameInContext(k, &ctx, 0.0f, 0.0f, &l, &r);
            if (done + i + tail >= frames && fabsf(l) > *tailPeak) *tailPeak = fabsf(l);
        }
        N60RenderKernelEndRender(k, &ctx, n);
        done += n;
        if (*tripFrame == UINT64_MAX && N60RenderKernelHowlGuardTripCount(k) > tripsBefore) {
            *tripFrame = done;
        }
    }
}

static bool publishTone(N60RenderKernel *k, double rate, float amplitude, uint32_t transition) {
    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(rate);
    N60ActiveQuietZoneToneSnapshot tone = {0};
    tone.frequencyHz = 60.0;
    tone.leftReal = amplitude;
    tone.rightReal = amplitude;
    if (!N60DSPGraphSnapshotSetActiveQuietZone(&snapshot, &tone, 1u, transition, true)) return false;
    return N60RenderKernelPublishSnapshot(k, snapshot);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const double rate = kRates[r];
        const uint64_t second = (uint64_t)rate;
        float peak = 0.0f;
        uint64_t trip = 0;

        /* No guard attached: the jump plays, nothing counts. */
        N60RenderKernel *k = N60RenderKernelCreate();
        CHECK(k != NULL, "create at %.0f", rate);
        if (k == NULL) continue;
        CHECK(publishTone(k, rate, 0.004f, 64u), "publish quiet at %.0f", rate);
        render(k, rate, second / 2u, 0, &peak, &trip);
        CHECK(publishTone(k, rate, 0.06f, (uint32_t)(0.030 * rate)), "publish loud at %.0f", rate);
        render(k, rate, second / 2u, 0, &peak, &trip);
        CHECK(peak > 0.02f, "rate %.0f: unguarded jump peak %f", rate, peak);
        CHECK(N60RenderKernelHowlGuardTripCount(k) == 0u, "rate %.0f: trip without a guard", rate);
        N60RenderKernelDestroy(k);

        /* Guarded: a steady tone and a 3 s ramp-in never trip. */
        k = N60RenderKernelCreate();
        CHECK(N60RenderKernelAttachHowlGuard(k, rate), "attach at %.0f", rate);
        CHECK(N60RenderKernelAttachHowlGuard(k, rate), "re-attach at the same rate is a no-op");
        CHECK(publishTone(k, rate, 0.04f, (uint32_t)(3.0 * rate)), "publish ramp at %.0f", rate);
        render(k, rate, 4u * second, 0, &peak, &trip);
        CHECK(N60RenderKernelHowlGuardTripCount(k) == 0u, "rate %.0f: ramp-in tripped", rate);
        CHECK(peak > 0.02f, "rate %.0f: ramped tone not audible (%f)", rate, peak);
        CHECK(N60RenderKernelHowlGuardLastTrip(k) == 0u, "rate %.0f: trip kind without a trip", rate);

        /* A runaway rise trips within 50 ms plus one 256-frame chunk and mutes. */
        N60RenderKernelDestroy(k);
        k = N60RenderKernelCreate();
        CHECK(N60RenderKernelAttachHowlGuard(k, rate), "attach (2) at %.0f", rate);
        CHECK(publishTone(k, rate, 0.004f, 64u), "publish quiet (2) at %.0f", rate);
        render(k, rate, second, 0, &peak, &trip);
        CHECK(N60RenderKernelHowlGuardTripCount(k) == 0u, "rate %.0f: quiet tone tripped", rate);
        CHECK(publishTone(k, rate, 0.06f, (uint32_t)(0.030 * rate)), "publish jump at %.0f", rate);
        render(k, rate, second / 2u, 0, &peak, &trip);
        const double limit = 0.050 * rate + 256.0 + BLOCK;
        CHECK(trip != UINT64_MAX && (double)trip <= limit,
              "rate %.0f: trip at frame %llu, limit %.0f", rate, (unsigned long long)trip, limit);
        CHECK(N60RenderKernelHowlGuardTripCount(k) == 1u, "rate %.0f: trip count %llu", rate,
              (unsigned long long)N60RenderKernelHowlGuardTripCount(k));
        CHECK(N60RenderKernelHowlGuardLastTrip(k) == (uint32_t)N60AncGuardTripGrowth,
              "rate %.0f: trip kind %u", rate, N60RenderKernelHowlGuardLastTrip(k));
        CHECK(peak == 0.0f, "rate %.0f: not silent after trip (%g)", rate, peak);

        /* Latched: still silent and still one trip. */
        render(k, rate, second / 2u, 1, &peak, &trip);
        CHECK(peak == 0.0f && N60RenderKernelHowlGuardTripCount(k) == 1u,
              "rate %.0f: latch lost (peak %g)", rate, peak);

        /* Rearm: the steady tone returns and does not trip again. */
        N60RenderKernelRearmHowlGuard(k);
        render(k, rate, 2u * second, 1, &peak, &trip);
        CHECK(peak > 0.02f, "rate %.0f: no tone after rearm (%f)", rate, peak);
        CHECK(N60RenderKernelHowlGuardTripCount(k) == 1u, "rate %.0f: re-tripped after rearm", rate);

        /* Detach: no more watching. */
        N60RenderKernelDetachHowlGuard(k);
        CHECK(publishTone(k, rate, 0.004f, 64u), "publish quiet (3) at %.0f", rate);
        render(k, rate, second / 2u, 1, &peak, &trip);
        CHECK(publishTone(k, rate, 0.06f, (uint32_t)(0.030 * rate)), "publish jump (3) at %.0f", rate);
        render(k, rate, second / 2u, 1, &peak, &trip);
        CHECK(peak > 0.02f && N60RenderKernelHowlGuardTripCount(k) == 1u,
              "rate %.0f: detached guard still acting (peak %f)", rate, peak);
        N60RenderKernelDestroy(k);
    }
    if (failures == 0) printf("e4_howl_guard_live: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
