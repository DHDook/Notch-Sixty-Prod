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
    if (failures) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("n60core allocation hook: realtime path allocates nothing");
    return 0;
}
