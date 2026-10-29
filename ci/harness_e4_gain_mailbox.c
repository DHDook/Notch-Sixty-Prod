/*
 * E4 S18a: behavioural harness for the adaptive gain mailbox, the phase-anchor telemetry ring
 * and the ambient monitor's host-time anchors. At the eight standard rates:
 *  - a valid record retargets the tone gains through the linear crossfade with no step;
 *  - stale generation, tone mismatch, non-finite values and a disabled snapshot are ignored
 *    and counted, and the gains do not change;
 *  - gains above the per-tone limit, the snapshot cap or the record's attempt cap are scaled
 *    down and counted as clamped; the sum over tones is held to the aggregate limit;
 *  - the telemetry ring returns records in order and counts drops when full;
 *  - an ambient read reports the host time of its first frame, with the offset inside a block.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60ActiveQuietZone.h"
#include "N60AmbientMonitorBridge.h"

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

#define GENERATION 7u

typedef struct {
    N60ActiveQuietZoneSnapshot snapshot;
    N60ActiveQuietZoneRuntime runtime;
    N60ActiveQuietZoneGainMailbox *mailbox;
    double rate;
} Rig;

static bool rigInit(Rig *r, double rate, uint32_t tones, float gain) {
    memset(r, 0, sizeof *r);
    r->rate = rate;
    N60ActiveQuietZoneToneSnapshot t[N60_ACTIVE_QUIET_ZONE_MAX_TONES] = {{0}};
    for (uint32_t i = 0; i < tones; ++i) {
        t[i].frequencyHz = 60.0 + 20.0 * i;
        t[i].leftReal = gain;
        t[i].rightReal = gain;
    }
    r->snapshot = N60ActiveQuietZoneSnapshotMakeBypassed();
    if (!N60ActiveQuietZoneSnapshotSet(&r->snapshot, t, tones, 64u, rate, true)) return false;
    r->snapshot.armGeneration = GENERATION;
    N60ActiveQuietZoneRuntimeReset(&r->runtime, rate);
    if (!N60ActiveQuietZoneRuntimeSchedule(&r->runtime, &r->snapshot, rate)) return false;
    r->mailbox = N60ActiveQuietZoneGainMailboxCreate();
    return r->mailbox != NULL;
}

static N60ActiveQuietZoneGainRecord record(const Rig *r, uint32_t tones, float re) {
    N60ActiveQuietZoneGainRecord rec;
    memset(&rec, 0, sizeof rec);
    rec.armGeneration = GENERATION;
    rec.toneCount = tones;
    for (uint32_t i = 0; i < tones; ++i) {
        rec.frequencyHz[i] = r->snapshot.tones[i].frequencyHz;
        rec.gain[i][0] = re;
        rec.gain[i][2] = re;
    }
    return rec;
}

/* Renders frames; returns the largest sample-to-sample step of the left output. */
static float render(Rig *r, uint64_t frames, float *last) {
    float maxStep = 0.0f;
    for (uint64_t i = 0; i < frames; ++i) {
        float l = 0.0f, rr = 0.0f;
        N60ActiveQuietZoneRuntimeProcessFrame(&r->runtime, &l, &rr);
        const float step = fabsf(l - *last);
        if (step > maxStep) maxStep = step;
        *last = l;
    }
    return maxStep;
}

static float targetMag(const Rig *r, uint32_t tone) {
    const N60ActiveQuietZoneToneRuntime *t = &r->runtime.tones[tone];
    return hypotf(t->targetLeftReal, t->targetLeftImaginary);
}

static void applyAndSettle(Rig *r, float *last) {
    N60ActiveQuietZoneRuntimeApplyMailbox(&r->runtime, r->mailbox, &r->snapshot, r->rate);
    render(r, (uint64_t)(0.15 * r->rate), last);
}

static void testMailbox(double rate) {
    Rig r;
    CHECK(rigInit(&r, rate, 1u, 0.02f), "rig at %.0f", rate);
    float last = 0.0f;
    render(&r, (uint64_t)(0.2 * rate), &last);

    /* A valid record crossfades with no step beyond the tone's own slope. */
    N60ActiveQuietZoneGainRecord rec = record(&r, 1u, 0.04f);
    CHECK(N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec) == 1u, "first sequence at %.0f", rate);
    N60ActiveQuietZoneRuntimeApplyMailbox(&r.runtime, r.mailbox, &r.snapshot, rate);
    const float slope = 0.04f * 2.0f * (float)M_PI * 60.0f / (float)rate;
    const float ramp = 0.02f / (float)(0.1 * rate);
    const float step = render(&r, (uint64_t)(0.15 * rate), &last);
    CHECK(step <= 1.2f * (slope + ramp) + 1e-6f, "%.0f Hz rate: step %.3g exceeds slope %.3g", rate, step, slope);
    CHECK(fabsf(targetMag(&r, 0) - 0.04f) < 1e-6f, "%.0f: target %.4f after valid record", rate, targetMag(&r, 0));

    /* Ignored records leave the gains alone and are counted. */
    N60ActiveQuietZoneMailboxStats before = N60ActiveQuietZoneGainMailboxStats(r.mailbox);
    rec = record(&r, 1u, 0.01f);
    rec.armGeneration = GENERATION + 1u;
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    applyAndSettle(&r, &last);
    rec = record(&r, 1u, 0.01f);
    rec.frequencyHz[0] += 0.5;
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    applyAndSettle(&r, &last);
    rec = record(&r, 1u, 0.01f);
    rec.gain[0][1] = NAN;
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    applyAndSettle(&r, &last);
    rec = record(&r, 2u, 0.01f);
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    applyAndSettle(&r, &last);
    N60ActiveQuietZoneMailboxStats after = N60ActiveQuietZoneGainMailboxStats(r.mailbox);
    CHECK(after.ignoredStaleGeneration == before.ignoredStaleGeneration + 1u, "%.0f: stale generation count", rate);
    CHECK(after.ignoredToneMismatch == before.ignoredToneMismatch + 2u, "%.0f: tone mismatch count %llu", rate,
          (unsigned long long)(after.ignoredToneMismatch - before.ignoredToneMismatch));
    CHECK(after.ignoredNonFinite == before.ignoredNonFinite + 1u, "%.0f: non-finite count", rate);
    CHECK(after.applied == before.applied, "%.0f: an ignored record was applied", rate);
    CHECK(fabsf(targetMag(&r, 0) - 0.04f) < 1e-6f, "%.0f: gains moved on ignored records", rate);

    /* Over-limit: far above the -24 dBFS per-tone peak (0.0631) is scaled down and counted. */
    before = N60ActiveQuietZoneGainMailboxStats(r.mailbox);
    rec = record(&r, 1u, 0.5f);
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    applyAndSettle(&r, &last);
    after = N60ActiveQuietZoneGainMailboxStats(r.mailbox);
    CHECK(targetMag(&r, 0) <= 0.0632f, "%.0f: tone limit exceeded: %.4f", rate, targetMag(&r, 0));
    CHECK(after.clamped == before.clamped + 1u, "%.0f: clamp count", rate);

    /* The attempt cap lowers the limit below the snapshot's. */
    rec = record(&r, 1u, 0.03f);
    rec.attemptCapLinear = 0.01f;
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    applyAndSettle(&r, &last);
    CHECK(targetMag(&r, 0) <= 0.0101f, "%.0f: attempt cap exceeded: %.4f", rate, targetMag(&r, 0));

    /* A disabled snapshot ignores everything. */
    N60ActiveQuietZoneSnapshot off = r.snapshot;
    off.enabled = false;
    before = N60ActiveQuietZoneGainMailboxStats(r.mailbox);
    rec = record(&r, 1u, 0.02f);
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    N60ActiveQuietZoneRuntimeApplyMailbox(&r.runtime, r.mailbox, &off, rate);
    after = N60ActiveQuietZoneGainMailboxStats(r.mailbox);
    CHECK(after.ignoredNotEnabled == before.ignoredNotEnabled + 1u, "%.0f: not-enabled count", rate);
    N60ActiveQuietZoneGainMailboxDestroy(r.mailbox);
}

static void testAggregate(double rate) {
    Rig r;
    CHECK(rigInit(&r, rate, 4u, 0.01f), "4-tone rig at %.0f", rate);
    float last = 0.0f;
    N60ActiveQuietZoneGainRecord rec = record(&r, 4u, 0.06f);
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    applyAndSettle(&r, &last);
    float sum = 0.0f;
    for (uint32_t i = 0; i < 4u; ++i) sum += targetMag(&r, i);
    CHECK(sum <= 0.1260f, "%.0f: aggregate %.4f above -18 dBFS", rate, sum);
    N60ActiveQuietZoneGainMailboxDestroy(r.mailbox);
}

static void testTelemetry(void) {
    N60ActiveQuietZoneTelemetry *ring = N60ActiveQuietZoneTelemetryCreate();
    CHECK(ring != NULL, "telemetry create");
    N60ActiveQuietZoneTelemetryRecord rec;
    memset(&rec, 0, sizeof rec);
    for (uint64_t i = 1; i <= 10; ++i) {
        rec.hostTime = i;
        rec.renderedFrame = i * 100;
        CHECK(N60ActiveQuietZoneTelemetryPush(ring, &rec), "push %llu", (unsigned long long)i);
    }
    for (uint64_t i = 1; i <= 10; ++i) {
        CHECK(N60ActiveQuietZoneTelemetryPop(ring, &rec) && rec.hostTime == i, "pop order at %llu", (unsigned long long)i);
    }
    CHECK(!N60ActiveQuietZoneTelemetryPop(ring, &rec), "empty ring popped");
    uint64_t pushed = 0;
    for (uint64_t i = 1; i <= N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY + 50u; ++i) {
        rec.hostTime = i;
        if (N60ActiveQuietZoneTelemetryPush(ring, &rec)) ++pushed;
    }
    CHECK(pushed < N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY + 50u, "full ring never dropped");
    CHECK(N60ActiveQuietZoneTelemetryDropped(ring) == N60_ACTIVE_QUIET_ZONE_TELEMETRY_CAPACITY + 50u - pushed,
          "drop count %llu", (unsigned long long)N60ActiveQuietZoneTelemetryDropped(ring));
    N60ActiveQuietZoneTelemetryDestroy(ring);
}

static void testAnchors(void) {
    N60AmbientMonitorBridge *b = N60AmbientMonitorBridgeCreate(4096u, 0u);
    CHECK(b != NULL, "ambient bridge create");
    if (b == NULL) return;
    float block[256];
    for (int i = 0; i < 256; ++i) block[i] = (float)i;
    N60AmbientMonitorBridgeProcessPlanarAt(b, block, 256u, 1000u);
    N60AmbientMonitorBridgeProcessPlanarAt(b, block, 256u, 2000u);
    float out[100];
    N60AmbientMonitorAnchor a;
    CHECK(N60AmbientMonitorBridgeReadFramesWithAnchor(b, out, 100u, &a) == 100u, "first read size");
    CHECK(a.valid && a.hostTime == 1000u && a.frameOffset == 0u, "first anchor %llu +%u", (unsigned long long)a.hostTime, a.frameOffset);
    CHECK(N60AmbientMonitorBridgeReadFramesWithAnchor(b, out, 100u, &a) == 100u, "second read size");
    CHECK(a.valid && a.hostTime == 1000u && a.frameOffset == 100u, "second anchor %llu +%u", (unsigned long long)a.hostTime, a.frameOffset);
    CHECK(N60AmbientMonitorBridgeReadFramesWithAnchor(b, out, 100u, &a) == 100u, "third read size");
    CHECK(a.valid && a.hostTime == 1000u && a.frameOffset == 200u, "third anchor %llu +%u", (unsigned long long)a.hostTime, a.frameOffset);
    CHECK(N60AmbientMonitorBridgeReadFramesWithAnchor(b, out, 100u, &a) == 100u, "fourth read size");
    CHECK(a.valid && a.hostTime == 2000u && a.frameOffset == 44u, "fourth anchor %llu +%u", (unsigned long long)a.hostTime, a.frameOffset);
    N60AmbientMonitorBridgeDiscardFrames(b);
    N60AmbientMonitorBridgeProcessPlanar(b, block, 256u);
    CHECK(N60AmbientMonitorBridgeReadFramesWithAnchor(b, out, 100u, &a) == 100u && !a.valid, "an unanchored block reported an anchor");
    N60AmbientMonitorBridgeDestroy(b);
}

int main(void) {
    for (size_t i = 0; i < sizeof kRates / sizeof kRates[0]; ++i) {
        testMailbox(kRates[i]);
        testAggregate(kRates[i]);
    }
    testTelemetry();
    testAnchors();
    if (failures != 0) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("e4_gain_mailbox: ok");
    return 0;
}
