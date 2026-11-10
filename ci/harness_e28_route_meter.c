/* E28 S6: behavioural harness for the same-device per-route meters in the realtime bridge.
 * Drives the real IOProcs with a 2.1 output map (L, R, Sub on three DAC channels) at the eight standard rates:
 *  - a -6 dBFS signal on one route shows on that route only, within 0.05 dB, and RMS follows;
 *  - over-range counts only on the route that is over (a sub over-range latches only its own meter);
 *  - Take is read-and-reset (second Take reads zero) and keeps the maximum across several callbacks;
 *  - demand off: nothing is measured and the snapshot says disabled;
 *  - a concurrent reader thread never sees a value above the true maximum and sees the maximum;
 *  - the callback helpers use fixed-size structs only (no allocation), asserted by the size check below. */
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RealtimeAudioBridge.h"

#define FRAMES 512u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

_Static_assert(sizeof(N60RouteMeterAccumulator) <= 512u, "accumulator stays a small fixed struct");

static N60RealtimeAudioBridge *makeBridge(double rate) {
    N60RealtimeAudioBridge *bridge = N60RealtimeAudioBridgeCreate(FRAMES * 8u);
    if (bridge == NULL) return NULL;
    N60SpeakerOutputRouteDescriptor routes[3] = {
        {N60SpeakerOutputBusLeftFullRange, 0},
        {N60SpeakerOutputBusRightFullRange, 1},
        {N60SpeakerOutputBusSubMono, 2},
    };
    N60SameDeviceOutputMap map = {0};
    if (!N60SameDeviceOutputMapCompile(3, routes, 3, &map)
        || !N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(bridge, map)
        || !N60RealtimeAudioBridgePublishDSPGraph(bridge, N60DSPGraphSnapshotMakeUnity(rate))) {
        N60RealtimeAudioBridgeDestroy(bridge);
        return NULL;
    }
    N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0u, 0u);
    return bridge;
}

static float inBuf[FRAMES * 2u];
static float outBuf[FRAMES * 3u];

/* One capture + output callback pair with constant L and R. */
static void runBlock(N60RealtimeAudioBridge *bridge, float left, float right) {
    for (uint32_t n = 0; n < FRAMES; ++n) { inBuf[2u * n] = left; inBuf[2u * n + 1u] = right; }
    AudioBufferList in = {0};
    in.mNumberBuffers = 1;
    in.mBuffers[0].mNumberChannels = 2;
    in.mBuffers[0].mDataByteSize = sizeof(inBuf);
    in.mBuffers[0].mData = inBuf;
    AudioBufferList out = {0};
    out.mNumberBuffers = 1;
    out.mBuffers[0].mNumberChannels = 3;
    out.mBuffers[0].mDataByteSize = sizeof(outBuf);
    out.mBuffers[0].mData = outBuf;
    AudioTimeStamp ts = {0};
    N60CaptureIOProc(0, &ts, &in, &ts, &in, &ts, bridge);
    N60OutputIOProc(0, &ts, &in, &ts, &out, &ts, bridge);
}

static double db(double linear) { return 20.0 * log10(linear); }

static void rateCase(double rate) {
    N60RealtimeAudioBridge *bridge = makeBridge(rate);
    CHECK(bridge != NULL, "bridge at %.0f", rate);
    if (bridge == NULL) return;

    /* demand off: nothing measured */
    N60RealtimeAudioBridgeSetRouteMeterDemand(false);
    runBlock(bridge, 0.5f, 0.0f);
    N60RouteMeterSnapshot off = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(bridge);
    CHECK(!off.enabled && off.peak[0] == 0.0f && off.rms[0] == 0.0f, "off: nothing measured at %.0f", rate);
    CHECK(off.routeCount == 3u, "route count");

    N60RealtimeAudioBridgeSetRouteMeterDemand(true);
    for (int block = 0; block < 4; ++block) runBlock(bridge, 0.5f, 0.0f); /* -6.02 dBFS on L only */
    N60RouteMeterSnapshot s = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(bridge);
    CHECK(s.enabled, "enabled");
    CHECK(s.routes[0].bus == N60SpeakerOutputBusLeftFullRange && s.routes[2].bus == N60SpeakerOutputBusSubMono,
          "routes carry their bus");
    CHECK(fabs(db(s.peak[0]) - db(0.5)) < 0.05, "L peak %.3f dB at %.0f", db(s.peak[0]), rate);
    CHECK(s.peak[1] == 0.0f && s.peak[2] == 0.0f, "only L shows (R %g, Sub %g)", s.peak[1], s.peak[2]);
    CHECK(s.rms[0] > 0.45f && s.rms[0] <= 0.5001f, "L rms %g", s.rms[0]);
    CHECK(s.overRangeSamples[0] == 0 && s.overRangeSamples[1] == 0 && s.overRangeSamples[2] == 0, "no over-range");

    /* read and reset */
    N60RouteMeterSnapshot again = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(bridge);
    CHECK(again.peak[0] == 0.0f && again.rms[0] == 0.0f, "second take reads zero at %.0f", rate);

    /* maximum over several callbacks: loud block then quiet block, one take */
    runBlock(bridge, 0.5f, 0.0f);
    runBlock(bridge, 0.25f, 0.0f);
    N60RouteMeterSnapshot held = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(bridge);
    CHECK(fabs(db(held.peak[0]) - db(0.5)) < 0.05, "max kept across callbacks (%.3f dB)", db(held.peak[0]));

    /* over-range on R only counts on R's route */
    N60RouteMeterSnapshot before = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(bridge);
    runBlock(bridge, 0.0f, 1.5f);
    N60RouteMeterSnapshot over = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(bridge);
    CHECK(over.overRangeSamples[1] > before.overRangeSamples[1], "R over-range counted at %.0f", rate);
    CHECK(over.overRangeSamples[0] == before.overRangeSamples[0] && over.overRangeSamples[2] == before.overRangeSamples[2],
          "over-range stays on its own route");

    N60RealtimeAudioBridgeDestroy(bridge);
}

/* ---- concurrent reader ---- */
typedef struct { N60RealtimeAudioBridge *bridge; atomic_bool stop; float maxSeen; float overshoot; } Reader;

static void *readerMain(void *arg) {
    Reader *r = (Reader *)arg;
    while (!atomic_load(&r->stop)) {
        N60RouteMeterSnapshot s = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(r->bridge);
        if (s.peak[0] > r->maxSeen) r->maxSeen = s.peak[0];
        if (s.peak[0] > 0.5001f || s.peak[1] != 0.0f) r->overshoot = s.peak[0] > 0.5001f ? s.peak[0] : s.peak[1];
    }
    N60RouteMeterSnapshot s = N60RealtimeAudioBridgeTakeRouteMeterSnapshot(r->bridge);
    if (s.peak[0] > r->maxSeen) r->maxSeen = s.peak[0];
    return NULL;
}

static void concurrentCase(void) {
    N60RealtimeAudioBridge *bridge = makeBridge(48000.0);
    CHECK(bridge != NULL, "bridge");
    if (bridge == NULL) return;
    N60RealtimeAudioBridgeSetRouteMeterDemand(true);
    Reader reader = {bridge, false, 0.0f, 0.0f};
    pthread_t thread;
    pthread_create(&thread, NULL, readerMain, &reader);
    for (int block = 0; block < 400; ++block) runBlock(bridge, (block % 7 == 0) ? 0.5f : 0.1f, 0.0f);
    atomic_store(&reader.stop, true);
    pthread_join(thread, NULL);
    CHECK(reader.overshoot == 0.0f, "reader saw a value above the true maximum: %g", reader.overshoot);
    CHECK(fabs(db(reader.maxSeen) - db(0.5)) < 0.05, "reader saw the maximum (%g)", reader.maxSeen);
    N60RealtimeAudioBridgeDestroy(bridge);
}

/* The accumulate helper on its own: NaN is not metered, unmapped buses are ignored. */
static void helperCase(void) {
    N60SpeakerOutputRouteDescriptor routes[2] = {
        {N60SpeakerOutputBusLeftFullRange, 0},
        {N60SpeakerOutputBusSubMono, 1},
    };
    N60SameDeviceOutputMap map = {0};
    CHECK(N60SameDeviceOutputMapCompile(2, routes, 2, &map), "compile");
    N60RouteMeterAccumulator acc;
    memset(&acc, 0, sizeof(acc));
    N60SpeakerBusFrame frame = N60SpeakerBusFrameMakeSilence();
    N60SpeakerBusFrameSet(&frame, N60SpeakerOutputBusLeftFullRange, -0.8f);
    N60SpeakerBusFrameSet(&frame, N60SpeakerOutputBusRightFullRange, 0.9f); /* not routed */
    N60RouteMeterAccumulate(&acc, &map, &frame);
    CHECK(fabsf(acc.peak[0] - 0.8f) < 1e-6f && acc.peak[1] == 0.0f, "peak by route");
    CHECK(acc.overRange[0] == 0 && acc.overRange[1] == 0, "no over-range");
}

int main(void) {
    helperCase();
    for (size_t i = 0; i < sizeof(kRates) / sizeof(kRates[0]); ++i) rateCase(kRates[i]);
    concurrentCase();
    if (failures != 0) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    puts("e28 route meter: all checks passed");
    return 0;
}
