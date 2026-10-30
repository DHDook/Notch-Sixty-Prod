/*
 * E4 S20: behavioural harness for the render-side earned-cap ceiling and the attempt-cap fix.
 * At the eight standard rates:
 *  - a record asking for -18 dBFS from an initial -40 raises the ceiling by at most 3 dB per 5 s
 *    of rendered frames, and the played peak never exceeds the ceiling;
 *  - a lower request applies in the same callback and does not lower the ceiling;
 *  - regression: the per-sample clamp follows the attempt cap up as well as down (it used to stay
 *    at the lowest value ever asked for until the next graph publish), with and without a ceiling;
 *  - a new arm generation (and Reset) returns the ceiling to the initial cap; a republish within
 *    the same arm keeps it; a disabled snapshot drops it.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "N60ActiveQuietZone.h"

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

#define GEN 9u

static float lin(double db) { return (float)pow(10.0, db / 20.0); }
static double db(float x) { return 20.0 * log10((double)x); }

typedef struct {
    N60ActiveQuietZoneSnapshot snapshot;
    N60ActiveQuietZoneRuntime runtime;
    N60ActiveQuietZoneGainMailbox *mailbox;
    double rate;
} Rig;

static bool rigInit(Rig *r, double rate, double snapshotCapDB, double initialDB) {
    memset(r, 0, sizeof *r);
    r->rate = rate;
    N60ActiveQuietZoneToneSnapshot t[1] = {{0}};
    t[0].frequencyHz = 60.0;
    t[0].leftReal = 0.05f;   /* well above every cap used here, so the clamp is what limits */
    t[0].rightReal = 0.05f;
    r->snapshot = N60ActiveQuietZoneSnapshotMakeBypassed();
    if (!N60ActiveQuietZoneSnapshotSet(&r->snapshot, t, 1u, 64u, rate, true)) return false;
    if (!N60ActiveQuietZoneSnapshotSetPeakCap(&r->snapshot, lin(snapshotCapDB))) return false;
    r->snapshot.armGeneration = GEN;
    r->snapshot.initialCapLinear = initialDB > -200.0 ? lin(initialDB) : 0.0f;
    N60ActiveQuietZoneRuntimeReset(&r->runtime, rate);
    if (!N60ActiveQuietZoneRuntimeSchedule(&r->runtime, &r->snapshot, rate)) return false;
    r->mailbox = N60ActiveQuietZoneGainMailboxCreate();
    return r->mailbox != NULL;
}

static void publish(Rig *r, double attemptCapDB) {
    N60ActiveQuietZoneGainRecord rec;
    memset(&rec, 0, sizeof rec);
    rec.armGeneration = GEN;
    rec.toneCount = 1u;
    rec.frequencyHz[0] = 60.0;
    rec.gain[0][0] = 0.05f;
    rec.gain[0][2] = 0.05f;
    rec.attemptCapLinear = attemptCapDB > -200.0 ? lin(attemptCapDB) : 0.0f;
    N60ActiveQuietZoneGainMailboxPublish(r->mailbox, &rec);
    N60ActiveQuietZoneRuntimeApplyMailbox(&r->runtime, r->mailbox, &r->snapshot, r->rate);
}

/* Renders `frames` frames; returns the largest absolute sample seen. */
static float render(Rig *r, uint64_t frames) {
    float peak = 0.0f;
    for (uint64_t i = 0; i < frames; ++i) {
        float l = 0.0f, rr = 0.0f;
        N60ActiveQuietZoneRuntimeProcessFrame(&r->runtime, &l, &rr);
        if (fabsf(l) > peak) peak = fabsf(l);
        if (fabsf(rr) > peak) peak = fabsf(rr);
    }
    return peak;
}

static void testCeilingRise(double rate) {
    Rig r;
    CHECK(rigInit(&r, rate, -18.0, -40.0), "rig %.0f", rate);
    CHECK(fabs(db(r.runtime.ceilingLinear) + 40.0) < 0.01, "%.0f: ceiling starts at -40, got %.3f", rate, db(r.runtime.ceilingLinear));
    publish(&r, -200.0); /* no attempt cap: asks for the snapshot cap, -18 */
    const uint64_t five = (uint64_t)floor(rate * 5.0 + 0.5);
    float peak = render(&r, five - 100u);
    CHECK(db(r.runtime.ceilingLinear) < -39.9, "%.0f: ceiling rose before 5 s (%.2f)", rate, db(r.runtime.ceilingLinear));
    CHECK(peak <= lin(-40.0) * 1.001f, "%.0f: peak %.4f over -40 dBFS", rate, peak);
    render(&r, 200u);
    CHECK(fabs(db(r.runtime.ceilingLinear) + 37.0) < 0.05, "%.0f: one step after 5 s, got %.2f", rate, db(r.runtime.ceilingLinear));
    render(&r, five);
    CHECK(fabs(db(r.runtime.ceilingLinear) + 34.0) < 0.1, "%.0f: two steps after 10 s, got %.2f", rate, db(r.runtime.ceilingLinear));
    render(&r, five * 10u);
    CHECK(fabs(db(r.runtime.ceilingLinear) + 18.0) < 0.01, "%.0f: ends exactly at -18, got %.3f", rate, db(r.runtime.ceilingLinear));
    CHECK(r.runtime.peakCapLinear <= lin(-18.0) * 1.0001f, "%.0f: clamp over -18", rate);
    float after = render(&r, 2000u);
    CHECK(after <= lin(-18.0) * 1.001f, "%.0f: played %.4f over -18", rate, after);
}

static void testLowerAppliesAtOnce(double rate) {
    Rig r;
    CHECK(rigInit(&r, rate, -18.0, -25.0), "rig %.0f", rate);
    publish(&r, -35.0);
    CHECK(fabs(db(r.runtime.peakCapLinear) + 35.0) < 0.01, "%.0f: lower request not applied at once (%.2f)", rate, db(r.runtime.peakCapLinear));
    CHECK(fabs(db(r.runtime.ceilingLinear) + 25.0) < 0.01, "%.0f: ceiling lowered by a lower request", rate);
    /* The step back is not throttled: the ceiling already sits at the pre-move level. */
    publish(&r, -30.0);
    CHECK(fabs(db(r.runtime.peakCapLinear) + 30.0) < 0.01, "%.0f: step-back to -30 (%.2f)", rate, db(r.runtime.peakCapLinear));
    publish(&r, -25.0);
    CHECK(fabs(db(r.runtime.peakCapLinear) + 25.0) < 0.01, "%.0f: step-back to -25 (%.2f)", rate, db(r.runtime.peakCapLinear));
    publish(&r, -200.0);
    CHECK(fabs(db(r.runtime.peakCapLinear) + 25.0) < 0.01, "%.0f: clamp over the ceiling (%.2f)", rate, db(r.runtime.peakCapLinear));
}

/* Regression: the clamp used to stay at the lowest attempt cap until the next graph publish. */
static void testClampFollowsAttemptCapUp(double rate) {
    Rig r;
    CHECK(rigInit(&r, rate, -40.0, -200.0), "rig %.0f", rate);
    publish(&r, -50.0);
    CHECK(fabs(db(r.runtime.peakCapLinear) + 50.0) < 0.01, "%.0f: down to -50", rate);
    publish(&r, -45.0);
    CHECK(fabs(db(r.runtime.peakCapLinear) + 45.0) < 0.01, "%.0f: REGRESSION clamp stuck after a rise (%.2f)", rate, db(r.runtime.peakCapLinear));
    publish(&r, -200.0);
    CHECK(fabs(db(r.runtime.peakCapLinear) + 40.0) < 0.01, "%.0f: REGRESSION clamp not back at the snapshot cap (%.2f)", rate, db(r.runtime.peakCapLinear));
    float peak = render(&r, (uint64_t)(0.3 * rate));
    CHECK(peak > lin(-45.0), "%.0f: played peak %.5f never reached the restored -40 cap", rate, peak);
    CHECK(peak <= lin(-40.0) * 1.001f, "%.0f: played peak %.5f over -40", rate, peak);
}

static void testGenerationAndReset(double rate) {
    Rig r;
    CHECK(rigInit(&r, rate, -18.0, -40.0), "rig %.0f", rate);
    publish(&r, -200.0);
    render(&r, (uint64_t)(rate * 6.0));
    CHECK(db(r.runtime.ceilingLinear) > -38.0, "%.0f: ceiling did not rise", rate);
    /* A republish within the same arm keeps the earned ceiling. */
    CHECK(N60ActiveQuietZoneRuntimeSchedule(&r.runtime, &r.snapshot, rate), "reschedule");
    CHECK(db(r.runtime.ceilingLinear) > -38.0, "%.0f: republish dropped the ceiling", rate);
    /* A new arm generation starts again from the initial cap. */
    r.snapshot.armGeneration = GEN + 1u;
    CHECK(N60ActiveQuietZoneRuntimeSchedule(&r.runtime, &r.snapshot, rate), "reschedule gen");
    CHECK(fabs(db(r.runtime.ceilingLinear) + 40.0) < 0.01, "%.0f: new generation ceiling %.2f", rate, db(r.runtime.ceilingLinear));
    /* Reset clears it; the next Schedule starts from the initial cap. */
    publish(&r, -200.0);
    N60ActiveQuietZoneRuntimeReset(&r.runtime, rate);
    CHECK(!r.runtime.ceilingActive, "%.0f: Reset left the ceiling active", rate);
    CHECK(N60ActiveQuietZoneRuntimeSchedule(&r.runtime, &r.snapshot, rate), "reschedule after reset");
    CHECK(fabs(db(r.runtime.ceilingLinear) + 40.0) < 0.01, "%.0f: ceiling after Reset %.2f", rate, db(r.runtime.ceilingLinear));
    /* A disabled snapshot (disarm) drops the ceiling. */
    r.snapshot.enabled = false;
    CHECK(N60ActiveQuietZoneRuntimeSchedule(&r.runtime, &r.snapshot, rate), "reschedule disabled");
    CHECK(!r.runtime.ceilingActive, "%.0f: disarm left the ceiling active", rate);
}

int main(void) {
    for (size_t i = 0; i < sizeof kRates / sizeof kRates[0]; ++i) {
        testCeilingRise(kRates[i]);
        testLowerAppliesAtOnce(kRates[i]);
        testClampFollowsAttemptCapUp(kRates[i]);
        testGenerationAndReset(kRates[i]);
    }
    if (failures == 0) printf("harness_e4_earned_cap: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
