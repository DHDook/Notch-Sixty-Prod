/*
 * E4 S14: behavioural harness for the anti-noise dead-man lease in the render kernel.
 * At the eight standard rates, a live tone is rendered with silent program audio. With no lease
 * it plays. With a lease it plays until the deadline, then fades to exact silence with no click
 * and counts one expiry; a renewal fades it back in; Release stops enforcement.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60RenderKernel.h"

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

#define BLOCK 128u

/* Renders `frames` of silent input in BLOCK-sized callbacks; reports peak and the largest
 * sample-to-sample step of the left output. `last` carries the previous sample across calls. */
static void render(N60RenderKernel *k, uint64_t frames, float *last, float *peak, float *maxStep) {
    *peak = 0.0f;
    *maxStep = 0.0f;
    uint64_t done = 0;
    while (done < frames) {
        const uint32_t n = (uint32_t)(frames - done < BLOCK ? frames - done : BLOCK);
        N60RenderKernelRenderContext ctx = N60RenderKernelBeginRender(k);
        for (uint32_t i = 0; i < n; ++i) {
            float l = 0.0f, r = 0.0f;
            N60RenderKernelProcessStereoFrameInContext(k, &ctx, 0.0f, 0.0f, &l, &r);
            const float a = fabsf(l);
            if (a > *peak) *peak = a;
            const float step = fabsf(l - *last);
            if (step > *maxStep) *maxStep = step;
            *last = l;
        }
        N60RenderKernelEndRender(k, &ctx, n);
        done += n;
    }
}

static bool publishTone(N60RenderKernel *k, double rate) {
    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(rate);
    N60ActiveQuietZoneToneSnapshot tone = {0};
    tone.frequencyHz = 60.0;
    tone.leftReal = 0.04f;
    tone.rightReal = 0.04f;
    if (!N60DSPGraphSnapshotSetActiveQuietZone(&snapshot, &tone, 1u, 64u, true)) return false;
    return N60RenderKernelPublishSnapshot(k, snapshot);
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const double rate = kRates[r];
        const uint64_t second = (uint64_t)rate;
        N60RenderKernel *k = N60RenderKernelCreate();
        CHECK(k != NULL, "create at %.0f", rate);
        if (k == NULL) continue;
        CHECK(publishTone(k, rate), "publish at %.0f", rate);

        float last = 0.0f, peak = 0.0f, step = 0.0f;
        /* No lease: plays. */
        render(k, second / 2u, &last, &peak, &step);
        CHECK(peak > 0.02f, "rate %.0f: no-lease tone peak %f", rate, peak);
        CHECK(N60RenderKernelActiveQuietZoneLeaseExpiryCount(k) == 0u, "rate %.0f: spurious expiry", rate);

        /* Lease of 1 s: still plays in the first half second. */
        N60RenderKernelRenewActiveQuietZoneLease(k, second);
        render(k, second / 2u, &last, &peak, &step);
        CHECK(peak > 0.02f, "rate %.0f: leased tone peak %f", rate, peak);
        CHECK(N60RenderKernelActiveQuietZoneLeaseExpiryCount(k) == 0u, "rate %.0f: early expiry", rate);

        /* Past the deadline (0.5 s left, then 0.1 s more): fades out, no click. */
        render(k, second / 2u - 2u * BLOCK, &last, &peak, &step);
        CHECK(N60RenderKernelActiveQuietZoneLeaseExpiryCount(k) == 0u, "rate %.0f: expired before deadline", rate);
        render(k, (uint64_t)(rate * 0.1) + 2u * BLOCK, &last, &peak, &step);
        CHECK(N60RenderKernelActiveQuietZoneLeaseExpiryCount(k) == 1u, "rate %.0f: expiry count %llu", rate,
              (unsigned long long)N60RenderKernelActiveQuietZoneLeaseExpiryCount(k));
        CHECK(step < 0.01f, "rate %.0f: lease fade click, max step %f", rate, step);
        render(k, second / 4u, &last, &peak, &step);
        CHECK(peak == 0.0f, "rate %.0f: still audible after expiry, peak %g", rate, peak);
        CHECK(N60RenderKernelActiveQuietZoneLeaseExpiryCount(k) == 1u, "rate %.0f: expiry counted twice", rate);

        /* Renewal brings it back, smoothly. */
        N60RenderKernelRenewActiveQuietZoneLease(k, 4u * second);
        render(k, second / 2u, &last, &peak, &step);
        CHECK(peak > 0.02f, "rate %.0f: no recovery after renewal, peak %f", rate, peak);
        CHECK(step < 0.01f, "rate %.0f: fade-in click, max step %f", rate, step);

        /* Release: enforcement off, never expires however long it runs. */
        N60RenderKernelReleaseActiveQuietZoneLease(k);
        render(k, 5u * second, &last, &peak, &step);
        CHECK(peak > 0.02f, "rate %.0f: silent after release, peak %f", rate, peak);
        CHECK(N60RenderKernelActiveQuietZoneLeaseExpiryCount(k) == 1u, "rate %.0f: expiry after release", rate);
        N60RenderKernelDestroy(k);
    }
    if (failures == 0) puts("e4_engine_lease: PASS");
    return failures == 0 ? 0 : 1;
}
