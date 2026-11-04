/* E25 S8a: behavioural harness for the capture-side program fold.
 * Part 1 (core): n60_fold_down_process equals a double-precision reference sum of the same matrix for
 * 3.1, 5.1, 7.1 and 7.1.4 channel counts, interleaved and strided, and the ITU levels hold within 0.01 dB.
 * Part 2 (bridge): wider capture buffers (one interleaved buffer and N mono buffers, 6 and 8 channels,
 * 32 to 4096 frames, rings that wrap) reach the output exactly as a stereo bridge fed the reference fold
 * does; a bridge with no fold is untouched by the fold path (it is the control); configuration is refused
 * with adaptive rate conversion, twice, with a bad count or with a non-finite gain; a buffer layout that
 * does not fit counts in unsupportedBufferLayouts and writes nothing. Run at the eight standard rates
 * (the fold is rate-free; the rate sets the graph snapshot the bridge renders with). */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "N60RealtimeAudioBridge.h"
#include "n60/fold.h"

#define CAP 6000u
#define MAXF 4096u
#define MAXCH 12u
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const float K = 0.70710678118654752f;

/* BS.775 5.1/7.1 style rows for the harness (device order = layout order). */
static void makeRows(uint32_t ch, float *l, float *r) {
    memset(l, 0, sizeof(float) * MAXCH);
    memset(r, 0, sizeof(float) * MAXCH);
    l[0] = 1.0f; r[1] = 1.0f;                        /* FL FR */
    l[2] = K; r[2] = K;                              /* C */
    l[3] = 3.16227766f; r[3] = 3.16227766f;          /* LFE +10 dB */
    if (ch > 4u) { l[4] = K; r[5] = K; }             /* sides */
    if (ch > 6u) { l[6] = K; r[7] = K; }             /* rears */
    if (ch > 8u) { l[8] = K; r[9] = K; l[10] = 0.5f; r[11] = 0.5f; } /* heights */
}

static uint64_t rng = 12345u;
static float noise(void) {
    rng = rng * 6364136223846793005ull + 1442695040888963407ull;
    return (float)((int32_t)(rng >> 33) % 20001 - 10000) / 100000.0f; /* +-0.1 */
}

static void corePart(void) {
    const uint32_t counts[] = {4u, 6u, 8u, 12u};
    for (uint32_t k = 0; k < 4u; ++k) {
        const uint32_t ch = counts[k];
        float l[MAXCH], r[MAXCH];
        makeRows(ch, l, r);
        n60_fold_matrix m;
        CHECK(n60_fold_matrix_make(&m, ch, l, r) == 1, "make %u", ch);
        const uint32_t frames = 997u;
        static float buf[MAXF * MAXCH];
        static float out[MAXF * 2u];
        for (uint32_t i = 0; i < frames * ch; ++i) buf[i] = noise();
        const float *ptr[MAXCH];
        uint32_t stride[MAXCH];
        for (uint32_t c = 0; c < ch; ++c) { ptr[c] = buf + c; stride[c] = ch; }
        n60_fold_down_process(&m, ptr, stride, frames, out);
        double worst = 0.0;
        for (uint32_t n = 0; n < frames; ++n) {
            double a = 0.0, b = 0.0;
            for (uint32_t c = 0; c < ch; ++c) { a += (double)l[c] * buf[n * ch + c]; b += (double)r[c] * buf[n * ch + c]; }
            worst = fmax(worst, fmax(fabs(a - out[2u * n]), fabs(b - out[2u * n + 1u])));
        }
        CHECK(worst < 1e-6, "core fold vs reference, %u channels, worst %g", ch, worst);
        /* ITU levels: a unit signal on one channel appears at the matrix gain to 0.01 dB. */
        const uint32_t probe[] = {0u, 2u, 3u};
        for (uint32_t p = 0; p < 3u; ++p) {
            for (uint32_t i = 0; i < frames * ch; ++i) buf[i] = 0.0f;
            for (uint32_t n = 0; n < frames; ++n) buf[n * ch + probe[p]] = 0.5f;
            n60_fold_down_process(&m, ptr, stride, frames, out);
            double want = fabs((double)l[probe[p]] * 0.5);
            if (want > 0.0) {
                double db = 20.0 * log10(fabs(out[0]) / want);
                CHECK(fabs(db) < 0.01, "level error %g dB on channel %u of %u", db, probe[p], ch);
            }
        }
        /* a bad matrix is refused */
        l[1] = NAN;
        CHECK(n60_fold_matrix_make(&m, ch, l, r) == 0, "non-finite gain refused");
        CHECK(n60_fold_matrix_make(&m, 2u, l, r) == 0, "two channels refused");
        CHECK(n60_fold_matrix_make(&m, 17u, l, r) == 0, "seventeen channels refused");
    }
}

static N60RealtimeAudioBridge *makeBridge(double rate) {
    N60RealtimeAudioBridge *b = N60RealtimeAudioBridgeCreate(CAP);
    if (b == NULL) return NULL;
    N60DSPGraphSnapshot snap = N60DSPGraphSnapshotMakeUnity(rate);
    if (!N60RealtimeAudioBridgePublishDSPGraph(b, snap)) { N60RealtimeAudioBridgeDestroy(b); return NULL; }
    N60RealtimeAudioBridgeConfigureOutputGate(b, 0u, 0u);
    return b;
}

static float wideBuf[MAXF * MAXCH];
static float stereoIn[MAXF * 2u];
static float outFold[MAXF * 2u], outRef[MAXF * 2u];

/* layout 0: one interleaved buffer; layout 1: N mono buffers. */
static void bridgePart(double rate, uint32_t ch, int layout) {
    float l[MAXCH], r[MAXCH];
    makeRows(ch, l, r);
    N60RealtimeAudioBridge *fold = makeBridge(rate);
    N60RealtimeAudioBridge *ref = makeBridge(rate);
    CHECK(fold && ref, "bridges");
    if (!fold || !ref) return;
    CHECK(N60RealtimeAudioBridgeConfigureProgramFold(fold, l, r, ch), "configure %u", ch);
    CHECK(N60RealtimeAudioBridgeProgramFoldConfigured(fold), "configured flag");
    CHECK(!N60RealtimeAudioBridgeConfigureProgramFold(fold, l, r, ch), "second configure refused");
    CHECK(!N60RealtimeAudioBridgeProgramFoldConfigured(ref), "control has no fold");
    const uint32_t sizes[] = {32u, 100u, 512u, 1000u, 4096u};
    AudioTimeStamp ts = {0};
    double worst = 0.0;
    for (uint32_t round = 0; round < 12u; ++round) {
        const uint32_t frames = sizes[round % 5u];
        for (uint32_t i = 0; i < frames * ch; ++i) wideBuf[i] = noise();
        /* reference stereo, folded in float exactly as the core does */
        for (uint32_t n = 0; n < frames; ++n) {
            float a = 0.0f, b = 0.0f;
            for (uint32_t c = 0; c < ch; ++c) { a += l[c] * wideBuf[n * ch + c]; b += r[c] * wideBuf[n * ch + c]; }
            stereoIn[2u * n] = a; stereoIn[2u * n + 1u] = b;
        }
        AudioBufferList *in = NULL;
        static float mono[MAXCH][MAXF];
        if (layout == 0) {
            in = calloc(1, sizeof(AudioBufferList));
            in->mNumberBuffers = 1;
            in->mBuffers[0].mNumberChannels = ch;
            in->mBuffers[0].mDataByteSize = frames * ch * (UInt32)sizeof(float);
            in->mBuffers[0].mData = wideBuf;
        } else {
            in = calloc(1, sizeof(AudioBufferList) + (ch - 1u) * sizeof(AudioBuffer));
            in->mNumberBuffers = ch;
            for (uint32_t c = 0; c < ch; ++c) {
                for (uint32_t n = 0; n < frames; ++n) mono[c][n] = wideBuf[n * ch + c];
                in->mBuffers[c].mNumberChannels = 1;
                in->mBuffers[c].mDataByteSize = frames * (UInt32)sizeof(float);
                in->mBuffers[c].mData = mono[c];
            }
        }
        AudioBufferList refIn = {0};
        refIn.mNumberBuffers = 1;
        refIn.mBuffers[0].mNumberChannels = 2;
        refIn.mBuffers[0].mDataByteSize = frames * 2u * (UInt32)sizeof(float);
        refIn.mBuffers[0].mData = stereoIn;
        AudioBufferList outA = {0}, outB = {0};
        outA.mNumberBuffers = outB.mNumberBuffers = 1;
        outA.mBuffers[0].mNumberChannels = outB.mBuffers[0].mNumberChannels = 2;
        outA.mBuffers[0].mDataByteSize = outB.mBuffers[0].mDataByteSize = frames * 2u * (UInt32)sizeof(float);
        outA.mBuffers[0].mData = outFold;
        outB.mBuffers[0].mData = outRef;
        N60CaptureIOProc(0, &ts, in, &ts, &outA, &ts, fold);
        N60CaptureIOProc(0, &ts, &refIn, &ts, &outB, &ts, ref);
        N60OutputIOProc(0, &ts, in, &ts, &outA, &ts, fold);
        N60OutputIOProc(0, &ts, &refIn, &ts, &outB, &ts, ref);
        for (uint32_t i = 0; i < frames * 2u; ++i) worst = fmax(worst, fabs((double)outFold[i] - outRef[i]));
        free(in);
    }
    CHECK(worst < 1e-6, "bridge fold vs stereo reference, rate %.0f, %u ch, layout %d, worst %g", rate, ch, layout, worst);
    N60RealtimeAudioBridgeSnapshot s = N60RealtimeAudioBridgeGetSnapshot(fold);
    CHECK(s.unsupportedBufferLayouts == 0, "no unsupported layouts");
    CHECK(s.overrunFrames == 0, "no overruns, got %llu", (unsigned long long)s.overrunFrames);
    /* a stereo-only buffer does not fit a 6-channel fold: counted, nothing written */
    AudioBufferList wrong = {0};
    wrong.mNumberBuffers = 1;
    wrong.mBuffers[0].mNumberChannels = 2;
    wrong.mBuffers[0].mDataByteSize = 64u * 2u * (UInt32)sizeof(float);
    wrong.mBuffers[0].mData = stereoIn;
    uint64_t before = N60RealtimeAudioBridgeGetSnapshot(fold).capturedFrames;
    N60CaptureIOProc(0, &ts, &wrong, &ts, &wrong, &ts, fold);
    N60RealtimeAudioBridgeSnapshot after = N60RealtimeAudioBridgeGetSnapshot(fold);
    CHECK(after.unsupportedBufferLayouts == 1 && after.capturedFrames == before, "wrong layout counted, nothing written");
    N60RealtimeAudioBridgeDestroy(fold);
    N60RealtimeAudioBridgeDestroy(ref);
}

static void refusalPart(void) {
    float l[MAXCH], r[MAXCH];
    makeRows(6u, l, r);
    N60RealtimeAudioBridge *b = makeBridge(48000.0);
    CHECK(b != NULL, "bridge");
    if (!b) return;
    CHECK(N60RealtimeAudioBridgeConfigureAdaptiveSampleRate(b, 44100.0, 48000.0, 1024u), "adaptive configured");
    CHECK(!N60RealtimeAudioBridgeConfigureProgramFold(b, l, r, 6u), "fold refused with adaptive SRC");
    N60RealtimeAudioBridgeDestroy(b);
    b = makeBridge(48000.0);
    CHECK(!N60RealtimeAudioBridgeConfigureProgramFold(b, l, r, 2u), "two channels refused");
    CHECK(N60RealtimeAudioBridgeConfigureProgramFold(b, l, r, 6u), "six accepted");
    CHECK(!N60RealtimeAudioBridgeConfigureAdaptiveSampleRate(b, 44100.0, 48000.0, 1024u), "adaptive refused after fold");
    N60RealtimeAudioBridgeDestroy(b);
}

int main(void) {
    corePart();
    refusalPart();
    for (size_t i = 0; i < sizeof(kRates) / sizeof(kRates[0]); ++i) {
        const uint32_t counts[] = {6u, 8u};
        for (uint32_t k = 0; k < 2u; ++k) {
            bridgePart(kRates[i], counts[k], 0);
            bridgePart(kRates[i], counts[k], 1);
        }
    }
    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("e25 fold harness passed\n");
    return 0;
}
