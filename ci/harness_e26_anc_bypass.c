/*
 * E26 S1: on the legacy render kernel, the tonal anti-noise is added after the stereo crossover, so it bypasses the
 * mono-bass split. With bass recombined on the pair (class C) the drive already holds the bass in both channels, and
 * the anti-noise reaches only its own channel, unfiltered. This is why class C is not a subwoofer for Quiet Zone.
 * At the eight standard rates. The unified graph is pinned in core/tests/test_stereo_bass.cpp.
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

/* Renders `frames` frames of a left-only 40 Hz programme (level `program`), returns the 40 Hz amplitude of the last
 * half in `ampL`/`ampR` by a single-bin DFT. */
static void render(N60RenderKernel *k, double rate, uint64_t frames, float program, double *ampL, double *ampR) {
    double reL = 0, imL = 0, reR = 0, imR = 0, wsum = 0;
    const uint64_t start = frames / 2u, span = frames - start;
    uint64_t done = 0;
    const double w0 = 2.0 * M_PI * 40.0 / rate;
    while (done < frames) {
        const uint32_t n = (uint32_t)(frames - done < BLOCK ? frames - done : BLOCK);
        N60RenderKernelRenderContext ctx = N60RenderKernelBeginRender(k);
        for (uint32_t i = 0; i < n; ++i) {
            const uint64_t at = done + i;
            float l = 0.0f, r = 0.0f;
            N60RenderKernelProcessStereoFrameInContext(k, &ctx, program * (float)sin(w0 * (double)at), 0.0f, &l, &r);
            if (at >= start) {
                const double win = 0.5 - 0.5 * cos(2.0 * M_PI * ((double)(at - start) + 0.5) / (double)span);
                reL += win * l * cos(w0 * (double)at); imL += win * l * sin(w0 * (double)at);
                reR += win * r * cos(w0 * (double)at); imR += win * r * sin(w0 * (double)at);
                wsum += win;
            }
        }
        N60RenderKernelEndRender(k, &ctx, n);
        done += n;
    }
    *ampL = 2.0 * sqrt(reL * reL + imL * imL) / wsum;
    *ampR = 2.0 * sqrt(reR * reR + imR * imR) / wsum;
}

static N60RenderKernel *make(double rate, bool withTone) {
    N60RenderKernel *k = N60RenderKernelCreate();
    if (k == NULL) return NULL;
    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(rate);
    /* Mono bass recombined on the pair at 80 Hz, Linkwitz-Riley 24. */
    if (!N60DSPGraphSnapshotSetCrossover(&snapshot, 80.0, N60CrossoverTopologyLinkwitzRiley24,
                                         N60CrossoverMonitorModeRecombined, 1.0f, false, true)) return NULL;
    if (withTone) {
        N60ActiveQuietZoneToneSnapshot tone = {0};
        tone.frequencyHz = 40.0;
        tone.leftReal = 0.04f;
        tone.rightReal = 0.0f;
        if (!N60DSPGraphSnapshotSetActiveQuietZone(&snapshot, &tone, 1u, 64u, true)) return NULL;
    }
    if (!N60RenderKernelPublishSnapshot(k, snapshot)) return NULL;
    return k;
}

int main(void) {
    for (size_t i = 0; i < sizeof kRates / sizeof kRates[0]; ++i) {
        const double rate = kRates[i];
        const uint64_t frames = (uint64_t)rate * 2u;
        double pl, pr, tl, tr;
        N60RenderKernel *k = make(rate, false);
        CHECK(k != NULL, "rate %.0f: kernel with crossover", rate);
        if (k == NULL) continue;
        render(k, rate, frames, 0.5f, &pl, &pr);
        N60RenderKernelDestroy(k);
        /* The right input is silent, yet the drive holds the recombined bass. */
        CHECK(pr > 0.15, "rate %.0f: recombined bass on the right (%.4f)", rate, pr);

        k = make(rate, true);
        CHECK(k != NULL, "rate %.0f: kernel with crossover and tone", rate);
        if (k == NULL) continue;
        render(k, rate, frames, 0.0f, &tl, &tr);
        N60RenderKernelDestroy(k);
        /* Silent programme: the 40 Hz anti-noise is not high-passed (it would fall about 24 dB) and not summed over. */
        CHECK(tl > 0.03, "rate %.0f: anti-noise bypasses the crossover (%.4f)", rate, tl);
        CHECK(tr < 1e-6, "rate %.0f: anti-noise stays in its own channel (%.6f)", rate, tr);
    }
    if (failures == 0) puts("e26_anc_bypass: PASS");
    return failures == 0 ? 0 : 1;
}
