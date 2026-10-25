/* E6 S9c2: behavioural harness for the live bridge shutdown fade. At the eight standard rates,
 * a stereo N-channel bridge in steady state is asked for a 20 ms shutdown fade. The output must
 * ramp to exact silence with no step larger than a few times the per-frame slope (no click),
 * stay silent afterwards, and report completion to the control plane only once silent. A bridge
 * that was never asked to fade must be unaffected. */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60LiveNChannelBridge.h"

#define MAXB 128u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

static N60LiveNChannelRenderGraph makeGraph(double rate) {
    const N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ProgramLaneGraphSnapshot lanes = N60ProgramLaneGraphSnapshotMakeUnity(rate, layout);
    N60ProgramLaneGraphFinalize(&lanes);
    uint32_t phys[N60_MAX_PROGRAM_CHANNELS];
    for (uint32_t i = 0; i < N60_MAX_PROGRAM_CHANNELS; ++i) phys[i] = N60_LIVE_PHYSICAL_CHANNEL_UNMAPPED;
    phys[0] = 0u;
    phys[1] = 1u;
    N60LiveNChannelOutputMap map = {0};
    N60LiveNChannelOutputMapCompile(layout, 2u, phys, false, 0u, NULL, &map);
    N60MultichannelBassManagementSnapshot bass = {0};
    N60LiveNChannelRenderGraph graph = {0};
    N60LiveNChannelRenderGraphMake(rate, layout, lanes, false, bass, map, &graph);
    return graph;
}

/* Drives one block of constant input and writes the left output into dst. */
static void block(N60LiveNChannelBridge *b, uint32_t frames, float *dst) {
    float in[MAXB * 2u], out[MAXB * 2u];
    for (uint32_t i = 0; i < frames * 2u; ++i) in[i] = 0.4f;
    memset(out, 0, sizeof out);
    AudioBufferList inList = {0}, outList = {0}, unused = {0};
    inList.mNumberBuffers = 1;
    inList.mBuffers[0].mNumberChannels = 2;
    inList.mBuffers[0].mDataByteSize = frames * 2u * sizeof(float);
    inList.mBuffers[0].mData = in;
    outList.mNumberBuffers = 1;
    outList.mBuffers[0].mNumberChannels = 2;
    outList.mBuffers[0].mDataByteSize = frames * 2u * sizeof(float);
    outList.mBuffers[0].mData = out;
    AudioTimeStamp ts = {0};
    N60LiveNChannelCaptureIOProc(0, &ts, &inList, &ts, &unused, &ts, b);
    N60LiveNChannelOutputIOProc(0, &ts, &unused, &ts, &outList, &ts, b);
    for (uint32_t i = 0; i < frames; ++i) dst[i] = out[i * 2u];
}

int main(void) {
    for (size_t r = 0; r < sizeof kRates / sizeof kRates[0]; ++r) {
        const double rate = kRates[r];
        N60LiveNChannelRenderGraph g = makeGraph(rate);
        AudioChannelDescription desc[2] = {{kAudioChannelLabel_Left, 0, {0, 0, 0}},
                                            {kAudioChannelLabel_Right, 0, {0, 0, 0}}};
        N60ProgramInputMap map = {0};
        CHECK(N60ProgramInputMapCompile(desc, 2u, g.programLayout, &map), "input map at %.0f", rate);
        N60LiveNChannelBridge *b = N60LiveNChannelBridgeCreate(16384u, map, g, 0u, 1u);
        CHECK(b != NULL, "bridge at %.0f", rate);
        if (!b) continue;

        float buf[MAXB];
        float level = 0.0f;
        for (int i = 0; i < 400; ++i) { block(b, MAXB, buf); level = buf[MAXB - 1u]; }
        CHECK(level > 0.2f, "steady level %.3f at %.0f", level, rate);
        CHECK(!N60LiveNChannelBridgeShutdownFadeComplete(b), "complete before request");

        const uint32_t fadeFrames = (uint32_t)(rate * 0.020);
        N60LiveNChannelBridgeRequestShutdownFade(b, fadeFrames);
        const float slope = level / (float)fadeFrames;
        float prev = level, maxStep = 0.0f;
        uint32_t silentAt = 0, total = 0;
        bool sawIncrease = false;
        const uint32_t budget = fadeFrames + 4u * MAXB;
        while (total < budget) {
            block(b, MAXB, buf);
            for (uint32_t i = 0; i < MAXB; ++i) {
                float step = prev - buf[i];
                if (step < -1e-4f) sawIncrease = true;
                if (fabsf(step) > maxStep) maxStep = fabsf(step);
                if (buf[i] == 0.0f && silentAt == 0u) silentAt = total + i;
                prev = buf[i];
            }
            total += MAXB;
        }
        CHECK(!sawIncrease, "output rose during fade at %.0f", rate);
        CHECK(maxStep < 4.0f * slope + 1e-4f, "step %.6f vs slope %.6f at %.0f", maxStep, slope, rate);
        CHECK(silentAt != 0u && silentAt <= fadeFrames + MAXB, "silent at %u of %u at %.0f", silentAt, fadeFrames, rate);
        CHECK(prev == 0.0f, "not silent after fade: %.6f", prev);
        CHECK(N60LiveNChannelBridgeShutdownFadeComplete(b), "completion not reported at %.0f", rate);
        N60LiveNChannelBridgeDestroy(b);
        printf("rate %.0f ok\n", rate);
    }
    if (failures) { fprintf(stderr, "%d failures\n", failures); return 1; }
    puts("harness_e6_shutdown_fade OK");
    return 0;
}
