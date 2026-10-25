// E6 S3: the realtime call never allocates or frees. Replaces the global allocation
// functions with counting versions, arms the counters around n60_graph_process only
// (including the block that adopts a new snapshot, drains the mailbox and hands the
// old snapshot to the retire queue), and requires both counts to stay zero.
// Control-thread calls (build, publish, post, collect) are allowed to allocate.
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <new>

#include "n60/graph.h"

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
static std::atomic<long> frees{0};

static void *countedAlloc(std::size_t n) {
    if (armed.load()) allocs.fetch_add(1);
    return std::malloc(n ? n : 1);
}
static void countedFree(void *p) {
    if (p != nullptr && armed.load()) frees.fetch_add(1);
    std::free(p);
}

void *operator new(std::size_t n) { return countedAlloc(n); }
void *operator new[](std::size_t n) { return countedAlloc(n); }
void *operator new(std::size_t n, const std::nothrow_t &) noexcept { return countedAlloc(n); }
void *operator new[](std::size_t n, const std::nothrow_t &) noexcept { return countedAlloc(n); }
void operator delete(void *p) noexcept { countedFree(p); }
void operator delete[](void *p) noexcept { countedFree(p); }
void operator delete(void *p, std::size_t) noexcept { countedFree(p); }
void operator delete[](void *p, std::size_t) noexcept { countedFree(p); }
void operator delete(void *p, const std::nothrow_t &) noexcept { countedFree(p); }
void operator delete[](void *p, const std::nothrow_t &) noexcept { countedFree(p); }

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static n60_stage_desc stage(uint32_t kind, uint32_t id, uint32_t lane, const float *p, uint32_t np, uint32_t cap = 0,
                            uint32_t laneB = 0) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = kind;
    s.stageId = id;
    s.laneA = lane;
    s.laneB = laneB;
    s.capacityFrames = cap;
    s.params = p;
    s.paramCount = np;
    return s;
}

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double rate : rates) {
        constexpr uint32_t N = 512;
        const float gain = 0.8f, gain2 = 1.2f, delay = 40;
        const float peq[8] = {0, static_cast<float>(1000 * rate / 48000), 6, 1, 1, static_cast<float>(200 * rate / 48000), -3, 0.7f};
        n60_stage_desc a[8] = {
            stage(N60_STAGE_SANITISE, 1, N60_LANE_ALL, nullptr, 0),
            stage(N60_STAGE_METER_IN, 2, N60_LANE_ALL, nullptr, 0),
            stage(N60_STAGE_GAIN, 3, N60_LANE_ALL, &gain, 1),
            stage(N60_STAGE_MS_ENCODE, 4, 0, nullptr, 0, 0, 1),
            stage(N60_STAGE_PEQ, 5, N60_LANE_ALL, peq, 8),
            stage(N60_STAGE_MS_DECODE, 6, 0, nullptr, 0, 0, 1),
            stage(N60_STAGE_METER_OUT, 7, N60_LANE_ALL, nullptr, 0),
            stage(N60_STAGE_DELAY, 8, N60_LANE_ALL, &delay, 1, 256),
        };
        n60_stage_desc b[3] = {a[0], stage(N60_STAGE_GAIN, 3, N60_LANE_ALL, &gain2, 1), a[7]};
        n60_graph_desc da{}, db{};
        da.structSize = db.structSize = sizeof da;
        da.abiVersion = db.abiVersion = N60_GRAPH_ABI_VERSION;
        da.sampleRate = db.sampleRate = rate;
        da.maxBlockFrames = db.maxBlockFrames = N;
        da.inputChannels = da.outputChannels = db.inputChannels = db.outputChannels = 2;
        da.stages = a;
        da.stageCount = 8;
        db.stages = b;
        db.stageCount = 3;

        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build");
        n60_rebuild_options instant{sizeof instant, 0.0f, 0.0f, 0};
        CHECK(n60_graph_set_rebuild_options(g, &instant) == N60_STATUS_OK, "instant swaps");
        float l[N], r[N], ol[N], orr[N];
        for (uint32_t i = 0; i < N; i++) { l[i] = 0.1f * std::sin(0.05f * i); r[i] = 0.1f * std::cos(0.07f * i); }
        l[3] = NAN;
        const float *in[2] = {l, r};
        float *out[2] = {ol, orr};

        long swaps = 0;
        for (int round = 0; round < 40; round++) {
            n60_graph_desc &d = (round & 1) ? db : da;
            CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish");           // allocates: control thread
            n60_param_record rec[2] = {{3, 0, 0.5f + 0.01f * round, 0}, {8, 0, static_cast<float>(round), 0}};
            CHECK(n60_graph_post_params(g, rec, 2) == N60_STATUS_OK, "post");
            allocs = 0;
            frees = 0;
            armed = true;
            n60_status st = n60_graph_process(g, in, out, N);                      // adopt + drain + render
            for (int k = 0; k < 4; k++) st = static_cast<n60_status>(st | n60_graph_process(g, in, out, 1 + 100 * k));
            armed = false;
            CHECK(st == N60_STATUS_OK, "process");
            CHECK(allocs == 0 && frees == 0, "rate %.0f round %d: realtime call allocated %ld / freed %ld", rate, round,
                  allocs.load(), frees.load());
            swaps += n60_graph_collect(g);
        }
        CHECK(swaps == 40, "every swap retired a snapshot (%ld)", swaps);
        n60_graph_retire(g);
    }

    // S4 stages: denoiser, dynamic EQ, FIR, compressor and expander on four lanes, with
    // lane masks, published, edited live and rendered with blocks that straddle FFT frames.
    for (double rate : rates) {
        constexpr uint32_t N = 512;
        const float dn[9] = {2, 0, 1, -30, 1, 100, 4000, 1, 1};
        float band[16] = {1, 0, 1000, 1, 0, -30, 4, -24, 10, 10, 0, -60, 1, 0, 1, 20};
        band[2] = static_cast<float>(1000 * rate / 48000);
        float comp[10] = {-20, 4, 6, 1, 100, 0, 0, 1, 80, 1};
        const float exp6[6] = {-50, 2, -30, 1, 100, 0};
        float taps[700];
        for (int i = 0; i < 700; i++) taps[i] = 0.001f * static_cast<float>(std::sin(0.1 * i));
        n60_stage_desc a[5] = {
            stage(N60_STAGE_DENOISER, 1, 0, dn, 9),
            stage(N60_STAGE_DYN_EQ, 2, N60_LANE_ALL, band, 16),
            stage(N60_STAGE_FIR, 3, 0, taps, 700, 5),
            stage(N60_STAGE_COMPRESSOR, 4, 0, comp, 10),
            stage(N60_STAGE_EXPANDER, 5, N60_LANE_ALL, exp6, 6),
        };
        a[2].laneMask = 0x5; a[2].laneA = 0;
        a[3].laneMask = 0xB; a[3].laneA = 0;
        n60_stage_desc b[2] = {a[3], a[4]};
        n60_graph_desc da{}, db{};
        da.structSize = db.structSize = sizeof da;
        da.abiVersion = db.abiVersion = N60_GRAPH_ABI_VERSION;
        da.sampleRate = db.sampleRate = rate;
        da.maxBlockFrames = db.maxBlockFrames = N;
        da.inputChannels = da.outputChannels = db.inputChannels = db.outputChannels = 4;
        da.stages = a; da.stageCount = 5;
        db.stages = b; db.stageCount = 2;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build S4 graph at %.0f", rate);
        { n60_rebuild_options instant{sizeof instant, 0.0f, 0.0f, 0}; n60_graph_set_rebuild_options(g, &instant); }
        static float buf[4][N], obuf[4][N];
        const float *in[4];
        float *out[4];
        for (int c = 0; c < 4; c++) { in[c] = buf[c]; out[c] = obuf[c]; }
        uint32_t seed = 7;
        for (int round = 0; round < 24; round++) {
            n60_graph_desc &d = (round % 8 == 7) ? db : da;
            CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish S4");
            n60_param_record rec[3] = {{4, 0, -30.0f + round, 0}, {1, 3, -60.0f + round, 0}, {2, 4, -10.0f, 0}};
            n60_status ps = n60_graph_post_params(g, rec, (round % 8 == 7) ? 1 : 3);
            CHECK(ps == N60_STATUS_OK, "post S4 (%d)", ps);
            for (int c = 0; c < 4; c++) {
                for (uint32_t i = 0; i < N; i++) {
                    seed = seed * 1664525u + 1013904223u;
                    buf[c][i] = 0.2f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                }
            }
            allocs = 0;
            frees = 0;
            armed = true;
            n60_status st = n60_graph_process(g, in, out, N);
            for (int k = 0; k < 4; k++) st = static_cast<n60_status>(st | n60_graph_process(g, in, out, 1 + 100 * k));
            armed = false;
            CHECK(st == N60_STATUS_OK, "process S4");
            CHECK(allocs == 0 && frees == 0, "rate %.0f S4 round %d: realtime call allocated %ld / freed %ld", rate, round,
                  allocs.load(), frees.load());
            n60_graph_collect(g);
        }
        n60_graph_retire(g);
    }
    // E6 S8d: the shapes the stereo translator emits: a two-lane denoiser (all tunings and
    // qualities, a Reset command) before a dual-mono dynamic EQ with a tilt band, edited live.
    for (double rate : rates) {
        constexpr uint32_t N = 512;
        const int qualities[3] = {0, 1, 2};
        for (int quality : qualities) {
            float dn[9] = {static_cast<float>(quality + 1), static_cast<float>(quality), 0.9f, -45, 1, 0, 400, 2, 3};
            float bands[1 + 3 * 15] = {0};
            const float b0[15] = {0, 1000, 1.4f, -2, -40, 4, -12, 5, 80, 0, -30, 2, 6, 0, 50};
            const float b1[15] = {1, 250, 0.8f, 1, -20, 2, -6, 10, 200, 2, -18, 3, 6, 1, 40};
            const float b2[15] = {5, 1700, 1.0f, 0, -35, 3, -9, 8, 120, 0, -30, 2, 6, 0, 50};
            std::memcpy(bands + 1, b0, sizeof b0);
            std::memcpy(bands + 16, b1, sizeof b1);
            std::memcpy(bands + 31, b2, sizeof b2);
            n60_stage_desc a[2] = {
                stage(N60_STAGE_DENOISER, 1, 0, dn, 9),
                stage(N60_STAGE_DYN_EQ, 2, 0, bands, 46),
            };
            a[0].laneMask = a[1].laneMask = 0x3;
            n60_graph_desc da{};
            da.structSize = sizeof da;
            da.abiVersion = N60_GRAPH_ABI_VERSION;
            da.sampleRate = rate;
            da.maxBlockFrames = N;
            da.inputChannels = da.outputChannels = 2;
            da.stages = a; da.stageCount = 2;
            n60_graph *g = nullptr;
            CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build S8d graph at %.0f q%d", rate, quality);
            if (g == nullptr) continue;
            static float buf[2][N], obuf[2][N];
            const float *in[2] = {buf[0], buf[1]};
            float *out[2] = {obuf[0], obuf[1]};
            uint32_t seed = 11;
            for (int round = 0; round < 12; round++) {
                CHECK(n60_graph_publish(g, &da) == N60_STATUS_OK, "publish S8d");
                n60_param_record rec[2] = {{2, 5, -30.0f + round, 0}, {1, 2, 0.5f + 0.03f * round, 0}};
                CHECK(n60_graph_post_params(g, rec, 2) == N60_STATUS_OK, "post S8d");
                for (int c = 0; c < 2; c++) {
                    for (uint32_t i = 0; i < N; i++) {
                        seed = seed * 1664525u + 1013904223u;
                        buf[c][i] = 0.2f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                    }
                }
                allocs = 0;
                frees = 0;
                armed = true;
                n60_status st = n60_graph_process(g, in, out, N);
                for (int k = 0; k < 4; k++) st = static_cast<n60_status>(st | n60_graph_process(g, in, out, 1 + 100 * k));
                armed = false;
                // ABI v9 profile carry: the hand-over export and import are bounded copies on the realtime thread.
                static n60_denoiser_state ds;
                allocs = 0;
                frees = 0;
                armed = true;
                (void)n60_graph_denoiser_export(g, &ds);
                n60_graph_denoiser_import(g, &ds);
                armed = false;
                CHECK(allocs == 0 && frees == 0, "rate %.0f S8d q%d round %d: profile export/import allocated %ld / freed %ld",
                      rate, quality, round, allocs.load(), frees.load());
                CHECK(st == N60_STATUS_OK, "process S8d");
                CHECK(allocs == 0 && frees == 0, "rate %.0f S8d q%d round %d: realtime call allocated %ld / freed %ld",
                      rate, quality, round, allocs.load(), frees.load());
                n60_graph_collect(g);
            }
            // The denoiser switched off (parked profile) and back on, a quality change, all under the counter.
            for (int phase = 0; phase < 4; phase++) {
                n60_stage_desc only[1] = {a[1]};
                n60_graph_desc dp = da;
                if (phase == 0 || phase == 2) {
                    dp.stages = only; dp.stageCount = 1;
                    dp.parkFftSize = 1024u << quality; dp.parkRevision = static_cast<uint32_t>(phase); dp.parkCommand = phase == 2 ? 2u : 0u;
                }
                CHECK(n60_graph_publish(g, &dp) == N60_STATUS_OK, "publish park phase %d", phase);
                allocs = 0;
                frees = 0;
                armed = true;
                n60_status st = N60_STATUS_OK;
                for (int k = 0; k < 8; k++) st = static_cast<n60_status>(st | n60_graph_process(g, in, out, N));
                armed = false;
                CHECK(st == N60_STATUS_OK, "process park phase");
                CHECK(allocs == 0 && frees == 0, "rate %.0f S8d q%d park phase %d: realtime call allocated %ld / freed %ld",
                      rate, quality, phase, allocs.load(), frees.load());
                n60_graph_collect(g);
            }
            n60_graph_retire(g);
        }
    }
    // S5 system stages: every ABI v4 stage on four lanes, published, edited live and rendered.
    for (double rate : rates) {
        constexpr uint32_t N = 512;
        const float bm[9] = {80, 0, 2, 3, 120, 0, 0, 0, 0};
        const float amb[10] = {3, 100, 0, 1, 1000, 1, 1, 8000, 0, 1};
        const float sym[1] = {0.2f}, cf[1] = {0.2f}, ct[2] = {900, 0.3f}, og[1] = {0.9f};
        const float hp[11] = {-1, 0.5f, 45, 0.09f, 700, 0, 0, 0, 0, 0, 0};
        const float gate[5] = {-90, 6, 10, 5, 5};
        float gp[28] = {-1, -1, 3, 2, 6, 6, 3, 0.9f, -60, 0.005f, 0, 0};
        for (int i = 12; i < 28; i++) gp[i] = -100;
        const float inj[3] = {3, 0, 0}, prot[7] = {1, -1, 1, 50, 5, 1, 2}, mute[1] = {0}, cap[1] = {1};
        float taps[300];
        for (int i = 0; i < 300; i++) taps[i] = 0.002f * static_cast<float>(std::sin(0.2 * i));
        n60_stage_desc a[14] = {
            stage(N60_STAGE_BASS_MGMT, 1, 0, bm, 9),
            stage(N60_STAGE_ROOM_FIR, 2, 0, taps, 300),
            stage(N60_STAGE_AMBIENT, 3, N60_LANE_ALL, amb, 10),
            stage(N60_STAGE_SYMMETRY, 4, 0, sym, 1, 0, 1),
            stage(N60_STAGE_CROSSFEED, 5, 0, cf, 1, 0, 1),
            stage(N60_STAGE_CROSSTALK, 6, 0, ct, 2, 0, 1),
            stage(N60_STAGE_OUTPUT_GAIN, 7, 0, og, 1),
            stage(N60_STAGE_HEADPHONE, 8, 0, hp, 11, 0, 1),
            stage(N60_STAGE_PAUSE_GATE, 9, 0, gate, 5),
            stage(N60_STAGE_ANC_GUARD, 10, 2, gp, 28),
            stage(N60_STAGE_ANC_INJECT, 11, 0, inj, 3),
            stage(N60_STAGE_PROTECTION, 12, N60_LANE_ALL, prot, 7),
            stage(N60_STAGE_MUTE, 13, N60_LANE_ALL, mute, 1),
            stage(N60_STAGE_ANC_CAPTURE, 14, 0, cap, 1, 4096),
        };
        a[0].laneMask = 0x3; a[1].laneMask = 0x3; a[8].laneMask = 0xF; a[13].laneMask = 0xF;
        n60_stage_desc b[2] = {a[11], a[12]};
        n60_graph_desc da{}, db{};
        da.structSize = db.structSize = sizeof da;
        da.abiVersion = db.abiVersion = N60_GRAPH_ABI_VERSION;
        da.sampleRate = db.sampleRate = rate;
        da.maxBlockFrames = db.maxBlockFrames = N;
        da.inputChannels = da.outputChannels = db.inputChannels = db.outputChannels = 4;
        da.stages = a; da.stageCount = 14;
        db.stages = b; db.stageCount = 2;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build S5 graph at %.0f", rate);
        { n60_rebuild_options instant{sizeof instant, 0.0f, 0.0f, 0}; n60_graph_set_rebuild_options(g, &instant); }
        if (g == nullptr) continue;
        static float buf[4][N], obuf[4][N];
        const float *in[4];
        float *out[4];
        for (int c = 0; c < 4; c++) { in[c] = buf[c]; out[c] = obuf[c]; }
        uint32_t seed = 11;
        for (int round = 0; round < 16; round++) {
            n60_graph_desc &d = (round % 8 == 7) ? db : da;
            CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish S5");
            n60_param_record rec[4] = {{1, 1, -3.0f + round * 0.1f, 0}, {4, 0, -0.5f + 0.05f * round, 0}, {12, 1, -2.0f, 0}, {9, 0, 0, 0}};
            n60_status ps = n60_graph_post_params(g, rec, (round % 8 == 7) ? 0 : 3);
            CHECK(ps == N60_STATUS_OK, "post S5 (%d)", ps);
            for (int c = 0; c < 4; c++) {
                for (uint32_t i = 0; i < N; i++) {
                    seed = seed * 1664525u + 1013904223u;
                    buf[c][i] = 0.3f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                }
            }
            allocs = 0;
            frees = 0;
            armed = true;
            n60_status st = n60_graph_process(g, in, out, N);
            for (int k = 0; k < 4; k++) st = static_cast<n60_status>(st | n60_graph_process(g, in, out, 1 + 100 * k));
            armed = false;
            CHECK(st == N60_STATUS_OK, "process S5");
            CHECK(allocs == 0 && frees == 0, "rate %.0f S5 round %d: realtime call allocated %ld / freed %ld", rate, round,
                  allocs.load(), frees.load());
            n60_graph_collect(g);
        }
        n60_graph_retire(g);
    }
    // S6: ramped live edits and the faded rebuild (warm-up, crossfade, completion, NaN cancel and CPU-budget
    // refusal) run entirely on preallocated state: no allocation or free anywhere in the callback.
    for (double rate : rates) {
        constexpr uint32_t N = 256;
        const float gain = 0.9f;
        const float peq[8] = {0, static_cast<float>(1000 * rate / 48000), 3, 1, 1, static_cast<float>(300 * rate / 48000), -2, 0.7f};
        float taps0[64] = {1.0f}, taps1[64] = {0};
        taps1[7] = 0.5f;
        const float delay = 20;
        const float inj[4] = {1, 1, -6, 3};
        n60_stage_desc a[6] = {
            stage(N60_STAGE_SANITISE, 1, N60_LANE_ALL, nullptr, 0),
            stage(N60_STAGE_GAIN, 2, N60_LANE_ALL, &gain, 1),
            stage(N60_STAGE_PEQ, 3, N60_LANE_ALL, peq, 8),
            stage(N60_STAGE_FIR, 4, N60_LANE_ALL, taps0, 64),
            stage(N60_STAGE_DELAY, 5, N60_LANE_ALL, &delay, 1, 300),
            stage(N60_STAGE_ANC_INJECT, 6, 0, inj, 4),
        };
        n60_stage_desc b[5] = {a[0], a[1], stage(N60_STAGE_FIR, 4, N60_LANE_ALL, taps1, 64), a[4], a[5]};
        n60_stage_desc nanb[2] = {a[1], a[4]};  // no sanitiser: NaN input reaches the output
        n60_graph_desc da{}, db{}, dn{};
        da.structSize = db.structSize = dn.structSize = sizeof da;
        da.abiVersion = db.abiVersion = dn.abiVersion = N60_GRAPH_ABI_VERSION;
        da.sampleRate = db.sampleRate = dn.sampleRate = rate;
        da.maxBlockFrames = db.maxBlockFrames = dn.maxBlockFrames = N;
        da.inputChannels = da.outputChannels = db.inputChannels = db.outputChannels = dn.inputChannels = dn.outputChannels = 2;
        da.stages = a; da.stageCount = 6;
        db.stages = b; db.stageCount = 5;
        dn.stages = nanb; dn.stageCount = 2;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build S6 graph at %.0f", rate);
        if (g == nullptr) continue;
        static float buf[2][N], obuf[2][N];
        const float *in[2];
        float *out[2];
        for (int c = 0; c < 2; c++) { in[c] = buf[c]; out[c] = obuf[c]; }
        uint32_t seed = 5;
        long blocks = 0;
        for (int round = 0; round < 12; round++) {
            const int kind = round % 4;  // 0 faded rebuild, 1 NaN cancel, 2 CPU refusal, 3 rebuild back to the full graph
            n60_rebuild_options o{sizeof o, 20.0f, kind == 2 ? 1e-7f : 0.0f, 0};
            CHECK(n60_graph_set_rebuild_options(g, &o) == N60_STATUS_OK, "options");
            n60_graph_desc &d = kind == 1 ? dn : (kind == 3 ? da : db);
            CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish S6");
            // S8d: the control thread drops the FIR history; the next realtime blocks must not allocate or clear.
            if (round % 3 == 0) n60_graph_invalidate_history(g);  // single-threaded test: control and render are the same thread
            for (int step = 0; step < 400; step++) {
                // Edits every block: PEQ gain and frequency, gain, delay.
                const n60_param_record rec[4] = {{3, 2, static_cast<float>((step % 11) - 5), 0},
                                                 {3, 1, static_cast<float>((200 + 37 * step) % 5000 + 100), 0},
                                                 {2, 0, 0.5f + 0.01f * static_cast<float>(step % 50), 0},
                                                 {5, 0, static_cast<float>(step % 200), 0}};
                if (kind == 0 || kind == 3) n60_graph_post_params(g, rec, 4);
                for (int c = 0; c < 2; c++) {
                    for (uint32_t i = 0; i < N; i++) {
                        seed = seed * 1664525u + 1013904223u;
                        buf[c][i] = 0.3f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                    }
                }
                if (kind == 1 && step == 1) buf[0][5] = NAN;
                allocs = 0;
                frees = 0;
                armed = true;
                n60_status st = n60_graph_process(g, in, out, N);
                armed = false;
                ++blocks;
                CHECK(st == N60_STATUS_OK, "process S6");
                CHECK(allocs == 0 && frees == 0, "rate %.0f S6 round %d step %d: realtime call allocated %ld / freed %ld", rate,
                      round, step, allocs.load(), frees.load());
                n60_rebuild_status rs{};
                rs.structSize = sizeof rs;
                n60_graph_get_rebuild_status(g, &rs);
                if (step > 2 && rs.state == 0) break;
            }
            n60_rebuild_status rs{};
            rs.structSize = sizeof rs;
            n60_graph_get_rebuild_status(g, &rs);
            CHECK(rs.state == 0, "round %d rebuild finished", round);
            CHECK(rs.lastResult == (kind == 1 ? 3u : (kind == 2 ? 2u : 1u)), "round %d result %u", round, rs.lastResult);
            n60_graph_collect(g);
            if (kind == 1 || kind == 2) {
                // The failed rebuild left the previous graph live; nothing else to undo.
                n60_rebuild_options off{sizeof off, 20.0f, 0.0f, 0};
                n60_graph_set_rebuild_options(g, &off);
            }
        }
        CHECK(blocks > 12, "S6 rounds ran");
        n60_graph_retire(g);
    }
    // S7: layouts and the binaural graph stage. Mode switches (5.1 speakers <-> binaural with three head
    // orientation sets) rebuild with the fade while the head yaw is posted every block; the callback
    // allocates and frees nothing, including the blocks that blend and fade orientation sets.
    for (double rate : rates) {
        constexpr uint32_t N = 200;
        n60_layout lay{};
        CHECK(n60_layout_standard(N60_LAYOUT_5_1, &lay) == N60_STATUS_OK, "5.1 layout");
        static float resp[3 * 6 * 2 * 300];
        uint32_t rng = 99;
        for (float &v : resp) {
            rng = rng * 1664525u + 1013904223u;
            v = 0.02f * (static_cast<float>((rng >> 8) & 0xFFFF) / 65536.0f - 0.5f);
        }
        n60_binaural_profile prof{};
        prof.structSize = sizeof prof;
        prof.taps = 300;
        prof.orientations = 3;
        prof.yawStartDeg = -90;
        prof.yawStepDeg = 90;
        prof.equalEarChannel = 3;
        prof.declaredLatency = 10;
        prof.responses = resp;
        const float peq[8] = {0, static_cast<float>(1000 * rate / 48000), 3, 1, 1, static_cast<float>(300 * rate / 48000), -2, 0.7f};
        n60_layout_options o{};
        o.structSize = sizeof o;
        o.sampleRate = rate;
        o.maxBlockFrames = N;
        o.graphChannels = 8;
        o.layout = &lay;
        o.midSide = 1;
        o.peq = peq;
        o.peqParamCount = 8;
        o.linkedDynamics = 1;
        o.protection = 1;
        n60_layout_graph *spk = nullptr, *bin = nullptr;
        CHECK(n60_layout_graph_build(&o, &spk) == N60_STATUS_OK, "speakers graph at %.0f", rate);
        o.mode = N60_MODE_BINAURAL;
        o.binaural = &prof;
        CHECK(n60_layout_graph_build(&o, &bin) == N60_STATUS_OK, "binaural graph at %.0f", rate);
        if (spk == nullptr || bin == nullptr) continue;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(n60_layout_graph_desc(spk), &g) == N60_STATUS_OK, "build S7 graph");
        if (g == nullptr) continue;
        static float buf[8][N], obuf[8][N];
        const float *in[8];
        float *out[8];
        for (int c = 0; c < 8; c++) { in[c] = buf[c]; out[c] = obuf[c]; }
        long blocks = 0;
        for (int round = 0; round < 6; round++) {
            CHECK(n60_graph_publish(g, n60_layout_graph_desc((round & 1) ? spk : bin)) == N60_STATUS_OK, "publish S7");
            for (int step = 0; step < 600; step++) {
                const n60_param_record rec[3] = {{N60_LSTAGE_BINAURAL, 0, -120.0f + static_cast<float>((step * 37) % 240), 0},
                                                 {N60_LSTAGE_BINAURAL, 1, static_cast<float>(step % 40), 0},
                                                 {N60_LSTAGE_BINAURAL, 2, 5.0f, 0}};
                if (round & 1) n60_graph_post_params(g, rec, 0); else n60_graph_post_params(g, rec, 3);
                for (int c = 0; c < 8; c++) {
                    for (uint32_t i = 0; i < N; i++) {
                        rng = rng * 1664525u + 1013904223u;
                        buf[c][i] = c < 6 ? 0.3f * (static_cast<float>((rng >> 8) & 0xFFFF) / 65536.0f - 0.5f) : 0.0f;
                    }
                }
                allocs = 0;
                frees = 0;
                armed = true;
                n60_status st = n60_graph_process(g, in, out, N);
                armed = false;
                ++blocks;
                CHECK(st == N60_STATUS_OK, "process S7");
                CHECK(allocs == 0 && frees == 0, "rate %.0f S7 round %d step %d: realtime call allocated %ld / freed %ld", rate,
                      round, step, allocs.load(), frees.load());
                n60_rebuild_status rs{};
                rs.structSize = sizeof rs;
                n60_graph_get_rebuild_status(g, &rs);
                if (step > 2 && rs.state == 0) break;
            }
            n60_graph_collect(g);
        }
        CHECK(blocks > 6, "S7 rounds ran");
        n60_graph_retire(g);
        n60_layout_graph_free(spk);
        n60_layout_graph_free(bin);
    }
    // S7b: eight sub lanes with per-sub EQ; live gain, polarity and EQ edits every block and a sub-count
    // rebuild (8 default-mode subs to 3 host-weighted and back) allocate nothing in the callback.
    for (double rate : rates) {
        constexpr uint32_t N = 256, CH = 11;
        float bass8[9 + 4 + 1 + 7 * 8], bass3[9 + 4 + 1 + 2 * 8];
        auto fill = [](float *p, uint32_t subs, bool weighted) {
            const float head[9] = {200, -6, 3, 2, 120, 0, 0, 0, 1};
            std::memcpy(p, head, sizeof head);
            uint32_t n = 9;
            p[n++] = 0; p[n++] = 50; p[n++] = 3; p[n++] = 1;
            p[n++] = static_cast<float>(subs - 1) + (weighted ? 8.0f : 0.0f);
            for (uint32_t q = 1; q < subs; ++q) {
                p[n++] = static_cast<float>(3 + q); p[n++] = -1.0f * static_cast<float>(q); p[n++] = static_cast<float>(q & 1u); p[n++] = 1;
                p[n++] = 0; p[n++] = 50; p[n++] = 3; p[n++] = 1;
            }
            return n;
        };
        const uint32_t n8 = fill(bass8, 8, false), n3 = fill(bass3, 3, true);
        n60_stage_desc a = stage(N60_STAGE_BASS_MGMT, 1, 0, bass8, n8), b = stage(N60_STAGE_BASS_MGMT, 1, 0, bass3, n3);
        a.laneMask = b.laneMask = 0x3;
        n60_graph_desc da{}, db{};
        da.structSize = db.structSize = sizeof da;
        da.abiVersion = db.abiVersion = N60_GRAPH_ABI_VERSION;
        da.sampleRate = db.sampleRate = rate;
        da.maxBlockFrames = db.maxBlockFrames = N;
        da.inputChannels = da.outputChannels = db.inputChannels = db.outputChannels = CH;
        da.stages = &a; da.stageCount = 1;
        db.stages = &b; db.stageCount = 1;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build S7b graph at %.0f", rate);
        if (g == nullptr) continue;
        static float buf[CH][N], obuf[CH][N];
        const float *in[CH];
        float *out[CH];
        for (uint32_t c = 0; c < CH; c++) { in[c] = buf[c]; out[c] = obuf[c]; }
        uint32_t seed = 3;
        for (int round = 0; round < 6; round++) {
            n60_graph_desc &d = (round % 2 == 0) ? db : da;
            CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish S7b");
            for (int step = 0; step < 300; step++) {
                const n60_param_record rec[3] = {{1, 6, static_cast<float>(step % 7) - 3.0f, 0},
                                                 {1, 7, static_cast<float>(step & 1), 0},
                                                 {1, 11, static_cast<float>((step * 5) % 24) - 12.0f, 0}};
                n60_graph_post_params(g, rec, 3);
                for (uint32_t c = 0; c < CH; c++) {
                    for (uint32_t i = 0; i < N; i++) {
                        seed = seed * 1664525u + 1013904223u;
                        buf[c][i] = 0.3f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                    }
                }
                allocs = 0;
                frees = 0;
                armed = true;
                n60_status st = n60_graph_process(g, in, out, N);
                armed = false;
                CHECK(st == N60_STATUS_OK, "process S7b");
                CHECK(allocs == 0 && frees == 0, "rate %.0f S7b round %d step %d: realtime call allocated %ld / freed %ld", rate,
                      round, step, allocs.load(), frees.load());
                n60_rebuild_status rs{};
                rs.structSize = sizeof rs;
                n60_graph_get_rebuild_status(g, &rs);
                if (step > 2 && rs.state == 0) break;
            }
            n60_graph_collect(g);
        }
        n60_graph_retire(g);
    }
    // E6 S8c: meters (with over-range counting), compressor, expander and protection while the
    // control thread reads the ABI v8 readbacks between blocks; the audio call must not allocate.
    for (double rate : rates) {
        constexpr uint32_t CH = 2, N = 256;
        const float comp[10] = {-20, 4, 6, 1, 50, 0, 0, 1, 80, 1};
        const float expa[6] = {-50, 2, -40, 2, 50, 1};
        const float prot[18] = {1, -3, 1, 50, 5, 1, 4, 1, 6, 0, 0.5f, 2, 0, 1, 0, 2, 6, 1};
        const float xo[8] = {120, 1, 0, 1, 0, 1, 80, 0.7f};
        n60_stage_desc st[7] = {stage(N60_STAGE_METER_IN, 1, N60_LANE_ALL, nullptr, 0),
                                stage(N60_STAGE_COMPRESSOR, 2, 0, comp, 10),
                                stage(N60_STAGE_EXPANDER, 3, 0, expa, 6),
                                stage(N60_STAGE_METER_OUT, 4, N60_LANE_ALL, nullptr, 0),
                                stage(N60_STAGE_STEREO_CROSSOVER, 7, 0, xo, 8, 0, 1),
                                stage(N60_STAGE_PROTECTION, 5, N60_LANE_ALL, prot, 18),
                                stage(N60_STAGE_FINAL_METER, 6, N60_LANE_ALL, nullptr, 0)};
        st[1].laneMask = st[2].laneMask = 0x3;
        n60_graph_desc d{};
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = rate;
        d.maxBlockFrames = N;
        d.inputChannels = d.outputChannels = CH;
        d.stages = st;
        d.stageCount = 7;
        n60_graph *g = nullptr;
        { n60_status bs = n60_graph_build(&d, &g); CHECK(bs == N60_STATUS_OK, "build S8c graph at %.0f (status %d)", rate, static_cast<int>(bs)); }
        if (g == nullptr) continue;
        static float buf[CH][N], obuf[CH][N];
        const float *in[CH];
        float *out[CH];
        for (uint32_t c = 0; c < CH; c++) { in[c] = buf[c]; out[c] = obuf[c]; }
        float peakGr = 0.0f;
        uint64_t overTotal = 0;
        uint32_t seed = 11;
        for (int step = 0; step < 400; step++) {
            for (uint32_t c = 0; c < CH; c++) {
                for (uint32_t i = 0; i < N; i++) {
                    seed = seed * 1664525u + 1013904223u;
                    buf[c][i] = 3.0f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);  // over-range input
                }
            }
            allocs = 0;
            frees = 0;
            armed = true;
            n60_status s = n60_graph_process(g, in, out, N);
            armed = false;
            CHECK(s == N60_STATUS_OK, "process S8c");
            CHECK(allocs == 0 && frees == 0, "rate %.0f S8c step %d: realtime call allocated %ld / freed %ld", rate, step,
                  allocs.load(), frees.load());
            n60_dynamics_readback r{};
            r.structSize = sizeof r;
            for (uint32_t stageId : {2u, 3u, 5u}) {
                for (uint32_t lane = 0; lane < CH; lane++) {
                    CHECK(n60_graph_read_dynamics(g, stageId, lane, &r) == N60_STATUS_OK, "read dynamics %u", stageId);
                    if (stageId == 5u && r.grMaxDb > peakGr) peakGr = r.grMaxDb;
                }
            }
            for (uint32_t stageId : {1u, 4u, 6u}) {
                for (uint32_t lane = 0; lane < CH; lane++) {
                    uint64_t over = 0;
                    CHECK(n60_graph_read_over_range(g, stageId, lane, &over) == N60_STATUS_OK, "read over-range %u", stageId);
                    if (stageId == 1u) overTotal += over;
                }
            }
        }
        CHECK(peakGr > 0.0f, "rate %.0f S8c: limiter reduction was never read back", rate);
        CHECK(overTotal > 0, "rate %.0f S8c: input over-range was never counted", rate);
        n60_graph_retire(g);
    }
    // ABI v13 EXTERNAL stage: a host callback runs in the graph, through publishes (with the default
    // warm-up and crossfade, where the follower reuses the cached delta), live bypass and a failing host.
    for (double rate : rates) {
        constexpr uint32_t N = 512;
        const float active = 1.0f, gain = 0.9f, gain2 = 1.1f;
        struct Host { int calls = 0; bool fail = false; };
        Host host;
        auto fn = [](void *c, const float *const *in, float *const *out, uint32_t ch, uint32_t frames) -> int {
            Host *h = static_cast<Host *>(c);
            h->calls++;
            if (h->fail) return 0;
            for (uint32_t k = 0; k < ch; k++)
                for (uint32_t i = 0; i < frames; i++) out[k][i] = 0.5f * in[k][i];
            return 1;
        };
        n60_stage_desc ext = stage(N60_STAGE_EXTERNAL, 2, 0, &active, 1, 32);
        ext.laneMask = 3;
        n60_stage_desc a[2] = {stage(N60_STAGE_GAIN, 1, N60_LANE_ALL, &gain, 1), ext};
        n60_stage_desc b[2] = {stage(N60_STAGE_GAIN, 1, N60_LANE_ALL, &gain2, 1), ext};
        n60_graph_desc da{}, db{};
        da.structSize = db.structSize = sizeof da;
        da.abiVersion = db.abiVersion = N60_GRAPH_ABI_VERSION;
        da.sampleRate = db.sampleRate = rate;
        da.maxBlockFrames = db.maxBlockFrames = N;
        da.inputChannels = da.outputChannels = db.inputChannels = db.outputChannels = 2;
        da.stages = a;
        db.stages = b;
        da.stageCount = db.stageCount = 2;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&da, &g) == N60_STATUS_OK, "build external");
        CHECK(n60_graph_set_external_processor(g, fn, &host, 2) == N60_STATUS_OK, "register external");
        float l[N], r[N], ol[N], orr[N];
        for (uint32_t i = 0; i < N; i++) { l[i] = 0.1f * std::sin(0.05f * i); r[i] = 0.1f * std::cos(0.07f * i); }
        const float *in[2] = {l, r};
        float *out[2] = {ol, orr};
        for (int round = 0; round < 12; round++) {
            CHECK(n60_graph_publish(g, (round & 1) ? &db : &da) == N60_STATUS_OK, "publish external");
            host.fail = (round % 5) == 4;
            for (int blk = 0; blk < 12; blk++) {
                n60_param_record rec{2, 0, (blk % 7) == 3 ? 0.0f : 1.0f, 0};
                CHECK(n60_graph_post_params(g, &rec, 1) == N60_STATUS_OK, "post external");
                allocs = 0;
                frees = 0;
                armed = true;
                n60_status st = n60_graph_process(g, in, out, N);
                st = static_cast<n60_status>(st | n60_graph_process(g, in, out, 77));
                armed = false;
                CHECK(st == N60_STATUS_OK, "process external");
                CHECK(allocs == 0 && frees == 0, "rate %.0f external round %d: realtime call allocated %ld / freed %ld",
                      rate, round, allocs.load(), frees.load());
            }
            n60_graph_collect(g);
        }
        CHECK(host.calls > 0, "external host was called");
        n60_graph_set_external_processor(g, nullptr, nullptr, 0);
        n60_graph_retire(g);
    }
    // E6 S9a2: a 7.1.4 (12 lane) graph with the program stages on every lane set the unified graph maps
    // (denoiser, M/S around a PEQ, dynamic EQ, program FIR, linked compressor and expander, bass management
    // to two lanes, room and speaker IR on the front pair, ambient, core dynamics, front pair stages, output
    // gain, pause gate, delay, protection and the final meter), published, edited live and rendered.
    for (double rate : rates) {
        constexpr uint32_t CH = 12, N = 512;
        const float gain = 0.8f, gain2 = 1.1f, delay = 24;
        const float dn[9] = {1, 0, 0.8f, -50, 1, 100, 4000, 0, 0};
        const float peq[8] = {0, static_cast<float>(1000 * rate / 48000), 4, 1, 1, static_cast<float>(250 * rate / 48000), -2, 0.7f};
        float band[16] = {1, 0, 1000, 1, 0, -30, 4, -24, 10, 10, 0, -60, 1, 0, 1, 20};
        band[2] = static_cast<float>(1000 * rate / 48000);
        const float comp[10] = {-20, 4, 6, 1, 100, 0, 0, 1, 80, 1};
        const float exp6[6] = {-50, 2, -30, 1, 100, 0};
        const float bm[9] = {80, 0, 10, 11, 120, 0, 0, 0, 0};
        const float amb[10] = {3, 100, 0, 1, 1000, 1, 1, 8000, 0, 1};
        const float sym[1] = {0.2f}, cf[1] = {0.2f}, ct[2] = {900, 0.3f}, og[1] = {0.9f};
        const float gate[5] = {-90, 6, 10, 5, 5};
        const float prot[7] = {1, -1, 1, 50, 5, 1, 2};
        float taps[700], room[300];
        for (int i = 0; i < 700; i++) taps[i] = 0.001f * static_cast<float>(std::sin(0.1 * i));
        for (int i = 0; i < 300; i++) room[i] = 0.002f * static_cast<float>(std::sin(0.2 * i));
        constexpr uint32_t ALL = (1u << CH) - 1, MAINS = 0x3FF, FRONT = 0x3;
        n60_stage_desc a[24] = {
            stage(N60_STAGE_SANITISE, 1, N60_LANE_ALL, nullptr, 0),
            stage(N60_STAGE_METER_IN, 2, N60_LANE_ALL, nullptr, 0),
            stage(N60_STAGE_GAIN, 3, N60_LANE_ALL, &gain, 1),
            stage(N60_STAGE_DENOISER, 4, 0, dn, 9),
            stage(N60_STAGE_MS_ENCODE, 5, 0, nullptr, 0, 0, 1),
            stage(N60_STAGE_PEQ, 6, N60_LANE_ALL, peq, 8),
            stage(N60_STAGE_DYN_EQ, 7, 0, band, 16),
            stage(N60_STAGE_MS_DECODE, 8, 0, nullptr, 0, 0, 1),
            stage(N60_STAGE_FIR, 9, 0, taps, 700, 5),
            stage(N60_STAGE_COMPRESSOR, 10, 0, comp, 10),
            stage(N60_STAGE_EXPANDER, 11, 0, exp6, 6),
            stage(N60_STAGE_METER_OUT, 12, N60_LANE_ALL, nullptr, 0),
            stage(N60_STAGE_BASS_MGMT, 13, 0, bm, 9),
            stage(N60_STAGE_ROOM_FIR, 14, 0, room, 300),
            stage(N60_STAGE_SPEAKER_IR, 15, 0, room, 150),
            stage(N60_STAGE_AMBIENT, 16, 0, amb, 10),
            stage(N60_STAGE_SYMMETRY, 17, 0, sym, 1, 0, 1),
            stage(N60_STAGE_CROSSFEED, 18, 0, cf, 1, 0, 1),
            stage(N60_STAGE_CROSSTALK, 19, 0, ct, 2, 0, 1),
            stage(N60_STAGE_OUTPUT_GAIN, 20, N60_LANE_ALL, og, 1),
            stage(N60_STAGE_PAUSE_GATE, 21, 0, gate, 5),
            stage(N60_STAGE_DELAY, 22, N60_LANE_ALL, &delay, 1, 256),
            stage(N60_STAGE_PROTECTION, 23, N60_LANE_ALL, prot, 7),
            stage(N60_STAGE_FINAL_METER, 24, N60_LANE_ALL, nullptr, 0),
        };
        for (int i : {3, 6, 8, 9, 10, 15, 20}) a[i].laneMask = ALL;
        a[8].laneMask = MAINS; a[9].laneMask = MAINS; a[10].laneMask = MAINS;
        a[12].laneMask = MAINS;
        a[13].laneMask = FRONT; a[14].laneMask = FRONT;
        n60_stage_desc b[3] = {a[0], stage(N60_STAGE_GAIN, 3, N60_LANE_ALL, &gain2, 1), a[22]};
        n60_graph_desc da{}, db{};
        da.structSize = db.structSize = sizeof da;
        da.abiVersion = db.abiVersion = N60_GRAPH_ABI_VERSION;
        da.sampleRate = db.sampleRate = rate;
        da.maxBlockFrames = db.maxBlockFrames = N;
        da.inputChannels = da.outputChannels = db.inputChannels = db.outputChannels = CH;
        da.stages = a; da.stageCount = 24;
        db.stages = b; db.stageCount = 3;
        n60_graph *g = nullptr;
        { n60_status bs = n60_graph_build(&da, &g); CHECK(bs == N60_STATUS_OK, "build 7.1.4 graph at %.0f (status %d)", rate, static_cast<int>(bs)); }
        if (g == nullptr) continue;
        { n60_rebuild_options instant{sizeof instant, 0.0f, 0.0f, 0}; n60_graph_set_rebuild_options(g, &instant); }
        static float buf[CH][N], obuf[CH][N];
        const float *in[CH];
        float *out[CH];
        for (uint32_t c = 0; c < CH; c++) { in[c] = buf[c]; out[c] = obuf[c]; }
        uint32_t seed = 21;
        for (int round = 0; round < 16; round++) {
            n60_graph_desc &d = (round % 8 == 7) ? db : da;
            CHECK(n60_graph_publish(g, &d) == N60_STATUS_OK, "publish 7.1.4");
            n60_param_record rec[3] = {{3, 0, 0.7f + 0.01f * round, 0}, {10, 0, -30.0f + round, 0}, {20, 0, 0.8f, 0}};
            n60_status ps = n60_graph_post_params(g, rec, (round % 8 == 7) ? 1 : 3);
            CHECK(ps == N60_STATUS_OK, "post 7.1.4 (%d)", ps);
            for (uint32_t c = 0; c < CH; c++) {
                for (uint32_t i = 0; i < N; i++) {
                    seed = seed * 1664525u + 1013904223u;
                    buf[c][i] = 0.3f * (static_cast<float>((seed >> 8) & 0xFFFF) / 65536.0f - 0.5f);
                }
            }
            allocs = 0;
            frees = 0;
            armed = true;
            n60_status st = n60_graph_process(g, in, out, N);
            for (int k = 0; k < 4; k++) st = static_cast<n60_status>(st | n60_graph_process(g, in, out, 1 + 100 * k));
            armed = false;
            CHECK(st == N60_STATUS_OK, "process 7.1.4");
            CHECK(allocs == 0 && frees == 0, "rate %.0f 7.1.4 round %d: realtime call allocated %ld / freed %ld", rate, round,
                  allocs.load(), frees.load());
            n60_graph_collect(g);
        }
        n60_graph_retire(g);
    }
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("n60core allocation hook: realtime path allocates nothing");
    return 0;
}
