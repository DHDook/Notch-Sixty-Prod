/*
 * E4 S21: behavioural harness for the per-tone excursion cap in the Quiet Zone runtime.
 * At the eight standard rates:
 *  - Schedule lowers each tone's offline gain to its own cap and leaves a tone with no cap alone;
 *  - a mailbox record asking for more than a tone's cap is played at that tone's cap, per tone,
 *    even when the aggregate and attempt caps would allow more;
 *  - a cap never raises a gain; zero caps leave the snapshot behaviour unchanged;
 *  - the rendered output of a 25 Hz tone with a low cap stays under that cap while a 120 Hz tone
 *    in the same snapshot is not limited by it.
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

#define GEN 4u

static float lin(double db) { return (float)pow(10.0, db / 20.0); }

typedef struct {
    N60ActiveQuietZoneSnapshot snapshot;
    N60ActiveQuietZoneRuntime runtime;
    N60ActiveQuietZoneGainMailbox *mailbox;
} Rig;

static bool rigInit(Rig *r, double rate, const float caps[2]) {
    memset(r, 0, sizeof *r);
    N60ActiveQuietZoneToneSnapshot t[2] = {{0}};
    t[0].frequencyHz = 25.0;  t[0].leftReal = 0.05f; t[0].rightReal = 0.05f;
    t[1].frequencyHz = 120.0; t[1].leftReal = 0.05f; t[1].rightReal = 0.05f;
    r->snapshot = N60ActiveQuietZoneSnapshotMakeBypassed();
    if (!N60ActiveQuietZoneSnapshotSet(&r->snapshot, t, 2u, 64u, rate, true)) return false;
    if (!N60ActiveQuietZoneSnapshotSetPeakCap(&r->snapshot, lin(-18.0))) return false;
    if (caps != NULL && !N60ActiveQuietZoneSnapshotSetToneCaps(&r->snapshot, caps, 2u)) return false;
    r->snapshot.armGeneration = GEN;
    N60ActiveQuietZoneRuntimeReset(&r->runtime, rate);
    if (!N60ActiveQuietZoneRuntimeSchedule(&r->runtime, &r->snapshot, rate)) return false;
    r->mailbox = N60ActiveQuietZoneGainMailboxCreate();
    return r->mailbox != NULL;
}

static float toneMagnitude(const Rig *r, int t, int channel) {
    const N60ActiveQuietZoneToneRuntime *tone = &r->runtime.tones[t];
    return channel == 0 ? hypotf(tone->targetLeftReal, tone->targetLeftImaginary)
                        : hypotf(tone->targetRightReal, tone->targetRightImaginary);
}

static void testScheduleCaps(double rate) {
    const float caps[2] = {lin(-40.0), 0.0f};
    Rig r;
    CHECK(rigInit(&r, rate, caps), "rig %.0f", rate);
    for (int ch = 0; ch < 2; ++ch) {
        CHECK(toneMagnitude(&r, 0, ch) <= lin(-40.0) * 1.0001f, "%.0f: 25 Hz ch%d over its cap (%.5f)", rate, ch, toneMagnitude(&r, 0, ch));
        CHECK(fabsf(toneMagnitude(&r, 0, ch) - lin(-40.0)) < 1e-6f, "%.0f: 25 Hz ch%d not lowered to the cap", rate, ch);
        CHECK(fabsf(toneMagnitude(&r, 1, ch) - 0.05f) < 1e-6f, "%.0f: uncapped 120 Hz ch%d changed (%.5f)", rate, ch, toneMagnitude(&r, 1, ch));
    }
    /* A cap above the gain never raises it. */
    const float high[2] = {1.0f, 1.0f};
    CHECK(rigInit(&r, rate, high), "rig high");
    CHECK(fabsf(toneMagnitude(&r, 0, 0) - 0.05f) < 1e-6f, "%.0f: a high cap raised the gain", rate);
    /* Invalid caps are refused. */
    float bad[2] = {-1.0f, 0.0f};
    CHECK(!N60ActiveQuietZoneSnapshotSetToneCaps(&r.snapshot, bad, 2u), "negative cap accepted");
    bad[0] = NAN;
    CHECK(!N60ActiveQuietZoneSnapshotSetToneCaps(&r.snapshot, bad, 2u), "NaN cap accepted");
    CHECK(!N60ActiveQuietZoneSnapshotSetToneCaps(&r.snapshot, bad, N60_ACTIVE_QUIET_ZONE_MAX_TONES + 1u), "oversized count accepted");
}

static void testMailboxCaps(double rate) {
    const float caps[2] = {lin(-45.0), lin(-30.0)};
    Rig r;
    CHECK(rigInit(&r, rate, caps), "rig %.0f", rate);
    N60ActiveQuietZoneGainRecord rec;
    memset(&rec, 0, sizeof rec);
    rec.armGeneration = GEN;
    rec.toneCount = 2u;
    rec.frequencyHz[0] = 25.0;
    rec.frequencyHz[1] = 120.0;
    rec.gain[0][0] = 0.1f; rec.gain[0][2] = 0.1f;
    rec.gain[1][0] = 0.1f; rec.gain[1][2] = 0.1f;
    rec.attemptCapLinear = lin(-20.0);
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    N60ActiveQuietZoneRuntimeApplyMailbox(&r.runtime, r.mailbox, &r.snapshot, rate);
    for (int ch = 0; ch < 2; ++ch) {
        CHECK(fabsf(toneMagnitude(&r, 0, ch) - lin(-45.0)) < 1e-6f, "%.0f: mailbox 25 Hz ch%d %.6f vs cap", rate, ch, toneMagnitude(&r, 0, ch));
        CHECK(fabsf(toneMagnitude(&r, 1, ch) - lin(-30.0)) < 1e-6f, "%.0f: mailbox 120 Hz ch%d %.6f vs cap", rate, ch, toneMagnitude(&r, 1, ch));
    }
    /* A request below the cap stays where it asked. */
    rec.gain[0][0] = 0.001f; rec.gain[0][2] = 0.001f;
    N60ActiveQuietZoneGainMailboxPublish(r.mailbox, &rec);
    N60ActiveQuietZoneRuntimeApplyMailbox(&r.runtime, r.mailbox, &r.snapshot, rate);
    CHECK(fabsf(toneMagnitude(&r, 0, 0) - 0.001f) < 1e-6f, "%.0f: a gain under the cap was changed", rate);
}

static void testRenderedPeak(double rate) {
    const float caps[2] = {lin(-45.0), 0.0f};
    Rig r;
    CHECK(rigInit(&r, rate, caps), "rig %.0f", rate);
    float low = 0.0f;
    const uint64_t frames = (uint64_t)(rate * 0.5);
    for (uint64_t i = 0; i < frames; ++i) {
        float l = 0.0f, rr = 0.0f;
        N60ActiveQuietZoneRuntimeProcessFrame(&r.runtime, &l, &rr);
        float a = fabsf(l);
        if (i > frames / 2 && a > low) low = a;
    }
    /* Both tones play; the 25 Hz one is capped at -45, the 120 Hz one is not, so the sum exceeds -45. */
    CHECK(low > lin(-45.0) * 1.5f, "%.0f: uncapped tone did not play (%.5f)", rate, low);
    CHECK(low <= lin(-45.0) + 0.05f * 1.01f, "%.0f: sum exceeds the tone caps (%.5f)", rate, low);
}

int main(void) {
    for (size_t i = 0; i < sizeof kRates / sizeof kRates[0]; ++i) {
        testScheduleCaps(kRates[i]);
        testMailboxCaps(kRates[i]);
        testRenderedPeak(kRates[i]);
    }
    if (failures == 0) printf("harness_e4_excursion_cap: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
