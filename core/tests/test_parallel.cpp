// E20 S5: parallel render core. A std::thread host drives n60_graph_worker_run; the output must be bit-identical at any
// worker count (0 to 3), with random worker delays, with an absent worker, across rebuilds, and the realtime call must
// stay allocation-free with workers running. Layouts mimic the room-treatment profiles: 6, 8 and 16 lanes, short and
// long taps, lane-mask subsets, two consecutive FIR stages.
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <random>
#include <thread>
#include <vector>

#include <unistd.h>

#include "n60/graph.h"

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
static void *countedAlloc(std::size_t n) {
    if (armed.load()) allocs.fetch_add(1);
    return std::malloc(n ? n : 1);
}
void *operator new(std::size_t n) { return countedAlloc(n); }
void *operator new[](std::size_t n) { return countedAlloc(n); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
void operator delete[](void *p, std::size_t) noexcept { std::free(p); }

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

// Portable worker host: workers sleep on a condition variable, the wake function (called from the render thread) only
// bumps an epoch and notifies.
struct Host {
    n60_graph *g = nullptr;
    std::mutex m;
    std::condition_variable cv;
    std::atomic<uint64_t> epoch{0};
    std::atomic<bool> quit{false};
    std::atomic<uint32_t> maxDelayUs{0};
    std::vector<std::thread> threads;

    static void wake(void *ctx, uint32_t) {
        Host *h = static_cast<Host *>(ctx);
        h->epoch.fetch_add(1);
        h->cv.notify_all();
    }
    void start(n60_graph *graph, uint32_t workers) {
        g = graph;
        quit = false;
        n60_graph_set_wake(g, &Host::wake, this);
        n60_graph_set_workers(g, workers);
        for (uint32_t w = 1; w <= workers; w++) {
            threads.emplace_back([this, w] {
                std::mt19937 rng(w * 7919u);
                uint64_t seen = 0;
                for (;;) {
                    {
                        std::unique_lock<std::mutex> lk(m);
                        cv.wait(lk, [&] { return quit.load() || epoch.load() != seen; });
                        if (quit.load()) return;
                        seen = epoch.load();
                    }
                    const uint32_t d = maxDelayUs.load();
                    if (d != 0) std::this_thread::sleep_for(std::chrono::microseconds(rng() % d));
                    n60_graph_worker_run(g, w);
                }
            });
        }
    }
    void stop() {
        n60_graph_set_workers(g, 0);
        quit = true;
        cv.notify_all();
        for (auto &t : threads) t.join();
        threads.clear();
        n60_graph_set_wake(g, nullptr, nullptr);
    }
};

static n60_stage_desc firStage(uint32_t id, const float *taps, uint32_t n, uint32_t laneMask, uint32_t lane = N60_LANE_ALL) {
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_FIR;
    s.stageId = id;
    s.laneA = laneMask ? 0 : lane;
    s.laneMask = laneMask;
    s.params = taps;
    s.paramCount = n;
    return s;
}

static std::vector<float> makeTaps(uint32_t n, uint32_t seed) {
    std::mt19937 rng(seed);
    std::vector<float> t(n);
    for (uint32_t i = 0; i < n; i++) {
        const float env = std::exp(-6.0f * static_cast<float>(i) / static_cast<float>(n));
        t[i] = env * (static_cast<float>(rng() % 20001) / 10000.0f - 1.0f) * 0.2f;
    }
    return t;
}

struct Layout {
    const char *name;
    uint32_t lanes;
    uint32_t tapsA;
    uint32_t tapsB;      // 0 = no second stage
    uint64_t maskA;      // 0 = all lanes
    bool shortSecond;
};

static float gScale = 1.0f;  // 1e-37 makes the FIR products subnormal: workers must flush like the caller
static void fill(std::vector<std::vector<float>> &in, uint32_t frames, uint32_t seed) {
    std::mt19937 rng(seed);
    for (size_t c = 0; c < in.size(); c++) {
        in[c].resize(frames);
        for (uint32_t i = 0; i < frames; i++) in[c][i] = gScale * 0.3f * std::sin(0.013f * static_cast<float>(i) * (1.0f + c)) +
                                                          gScale * 0.05f * (static_cast<float>(rng() % 2001) / 1000.0f - 1.0f);
    }
}

// Renders `blocks` varied-size blocks and appends every output sample to `out`.
static bool render(const Layout &L, double rate, uint32_t workers, uint32_t delayUs, bool absent, std::vector<float> &out,
                   long *allocCount, n60_graph_parallel_stats *stats) {
    auto tapsA = makeTaps(L.tapsA, 11), tapsB = makeTaps(L.tapsB ? L.tapsB : 1, 23);
    n60_stage_desc st[2];
    uint32_t count = 0;
    st[count++] = firStage(1, tapsA.data(), L.tapsA, static_cast<uint32_t>(L.maskA));
    if (L.tapsB) st[count++] = firStage(2, tapsB.data(), L.tapsB, 0);
    n60_graph_desc d{};
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = L.lanes;
    d.firScheme = N60_FIR_SCHEME_NONUNIFORM;
    d.stages = st;
    d.stageCount = count;
    n60_graph *g = nullptr;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return false;
    n60_rebuild_options instant{sizeof instant, 0.0f, 0.0f, 0};
    n60_graph_set_rebuild_options(g, &instant);

    Host host;
    if (workers != 0) {
        if (absent) {
            n60_graph_set_workers(g, workers);  // set, but no wake function and no threads
        } else {
            host.maxDelayUs = delayUs;
            host.start(g, workers);
        }
    }
    std::vector<std::vector<float>> in(L.lanes), o(L.lanes);
    fill(in, 4096, 5);
    for (auto &v : o) v.assign(512, 0.0f);
    std::vector<const float *> ip(L.lanes);
    std::vector<float *> op(L.lanes);
    const uint32_t sizes[] = {512, 1, 37, 256, 100, 512, 480};
    uint32_t pos = 0;
    out.clear();
    for (int blk = 0; blk < 14; blk++) {
        const uint32_t n = sizes[blk % 7];
        for (uint32_t c = 0; c < L.lanes; c++) { ip[c] = in[c].data() + (pos % 3000); op[c] = o[c].data(); }
        pos += n;
        if (blk == 9) n60_graph_publish(g, &d);  // a same-content rebuild mid-run, adopted by the next block
        if (allocCount && blk >= 2) { allocs = 0; armed = true; }
        const n60_status s = n60_graph_process(g, ip.data(), op.data(), n);
        if (allocCount && blk >= 2) { armed = false; *allocCount += allocs.load(); }
        if (s != N60_STATUS_OK) { if (workers) host.stop(); n60_graph_retire(g); return false; }
        for (uint32_t c = 0; c < L.lanes; c++) out.insert(out.end(), o[c].begin(), o[c].begin() + n);
        n60_graph_collect(g);
    }
    if (stats) { stats->structSize = sizeof *stats; n60_graph_read_parallel(g, stats); }
    if (workers && !absent) host.stop();
    n60_graph_retire(g);
    return true;
}

// A worker or the render thread that never finishes must fail this test, not stall the job: the watchdog reports where
// the run was and exits non-zero. Override the limit with N60_PARALLEL_TEST_TIMEOUT_S.
static std::atomic<const char *> gWhere{"start"};
static std::atomic<double> gRate{0};
static void startWatchdog() {
    const char *env = std::getenv("N60_PARALLEL_TEST_TIMEOUT_S");
    const long limit = env != nullptr ? std::atol(env) : 600;
    std::thread([limit] {
        std::this_thread::sleep_for(std::chrono::seconds(limit > 0 ? limit : 600));
        std::fprintf(stderr, "FAIL test_parallel: no result after %lds (layout '%s', rate %.0f): a worker or the caller is stuck\n",
                     limit, gWhere.load(), gRate.load());
        std::fflush(stderr);
        _exit(3);
    }).detach();
}

int main() {
    startWatchdog();
    std::printf("test_parallel: %u hardware threads\n", std::thread::hardware_concurrency());
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const Layout layouts[] = {
        {"R2 6 lanes short+long", 6, 4096, 20000, 0, false},
        {"R3 8 lanes mixed", 8, 16384, 8192, 0, false},
        {"R4 16 lanes", 16, 6000, 0, 0, false},
        {"mask subset", 8, 12000, 3000, 0x5Au, false},
        {"long 8 lanes", 8, 262144, 0, 0, false},
    };
    for (const Layout &L : layouts) {
        const bool heavy = L.tapsA > 100000;
        for (double rate : rates) {
            if (heavy && rate != 48000 && rate != 384000) continue;  // keep the long-tap case affordable
            std::vector<float> ref, got;
            long ac = 0;
            gWhere = L.name;
            gRate = rate;
            std::printf("test_parallel: %s at %.0f Hz\n", L.name, rate);
            std::fflush(stdout);
            CHECK(render(L, rate, 0, 0, false, ref, nullptr, nullptr), "%s ref build", L.name);
            for (uint32_t w = 1; w <= 3; w++) {
                n60_graph_parallel_stats stats{};
                ac = 0;
                CHECK(render(L, rate, w, 0, false, got, &ac, &stats), "%s w%u build", L.name, w);
                CHECK(got.size() == ref.size() && std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                      "%s rate %.0f workers %u: output differs from single thread", L.name, rate, w);
                CHECK(ac == 0, "%s rate %.0f workers %u: realtime call allocated %ld times", L.name, rate, w, ac);
                CHECK(stats.parallelPhases > 0, "%s workers %u: no phase ran in parallel", L.name, w);
                CHECK(stats.jobsOnCaller + stats.jobsOnWorkers > 0, "%s: no jobs counted", L.name);
            }
            // Random worker delays (late joins) and an absent worker: still identical.
            CHECK(render(L, rate, 3, 400, false, got, nullptr, nullptr) &&
                      std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                  "%s rate %.0f delayed workers differ", L.name, rate);
            n60_graph_parallel_stats ab{};
            CHECK(render(L, rate, 2, 0, true, got, nullptr, &ab) &&
                      std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                  "%s rate %.0f absent worker differs", L.name, rate);
            CHECK(ab.jobsOnWorkers == 0, "%s absent worker ran %llu jobs", L.name, static_cast<unsigned long long>(ab.jobsOnWorkers));
        }
    }

    // Subnormal inputs: lanes run on workers must match the calling thread (flush-to-zero on both).
    {
        gScale = 1e-37f;
        const Layout L = layouts[0];
        std::vector<float> ref, got;
        CHECK(render(L, 48000, 0, 0, false, ref, nullptr, nullptr), "subnormal ref");
        for (uint32_t w = 1; w <= 3; w++) {
            CHECK(render(L, 48000, w, 0, false, got, nullptr, nullptr) && got.size() == ref.size() &&
                      std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                  "subnormal input, workers %u: output differs", w);
        }
        gScale = 1.0f;
    }

    // Argument checks.
    {
        const float one = 1.0f;
        n60_stage_desc s = firStage(1, &one, 1, 0);
        n60_graph_desc d{};
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = 48000;
        d.maxBlockFrames = 64;
        d.inputChannels = d.outputChannels = 2;
        d.stages = &s;
        d.stageCount = 1;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "build small");
        CHECK(n60_graph_set_workers(g, N60_GRAPH_MAX_WORKERS + 1) == N60_STATUS_BAD_ARGUMENT, "too many workers rejected");
        CHECK(n60_graph_set_workers(g, N60_GRAPH_MAX_WORKERS) == N60_STATUS_OK, "max workers accepted");
        CHECK(n60_graph_worker_run(g, 0) == 0 && n60_graph_worker_run(g, 9) == 0, "bad worker index runs nothing");
        CHECK(n60_graph_worker_run(g, 1) == 0, "worker run outside a callback runs nothing");
        n60_graph_retire(g);
    }

    if (failures == 0) std::printf("test_parallel: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
