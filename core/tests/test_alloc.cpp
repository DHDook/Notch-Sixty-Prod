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
            stage(N60_STAGE_DENOISER, 1, N60_LANE_ALL, dn, 9),
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
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("n60core allocation hook: realtime path allocates nothing");
    return 0;
}
