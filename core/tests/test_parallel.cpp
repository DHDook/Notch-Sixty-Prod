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
#ifdef __linux__
#include <sched.h>
#endif

#include "n60/graph.h"

// Under ThreadSanitizer the runtime already defines operator new/delete (replacing them is a link error), so the
// allocation counter is compiled out there: the allocation checks are covered by the plain harness and core-rtsan,
// and the thread-safety checks all still run.
#if defined(__SANITIZE_THREAD__)
#define N60_TEST_TSAN 1
#elif defined(__has_feature)
#if __has_feature(thread_sanitizer)
#define N60_TEST_TSAN 1
#endif
#endif

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
#ifndef N60_TEST_TSAN
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
#endif

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

// Portable worker host: workers sleep on a condition variable, the wake function (called from the render thread) only
// bumps an epoch and notifies. Every state change the workers' predicate reads is made under the mutex, so a notify can
// never fall between a worker's predicate check and its block (a lost wakeup left stop() joining a sleeping worker forever
// on a loaded 3-core CI runner; the engine core was never involved).
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
        {
            std::lock_guard<std::mutex> lk(h->m);
            h->epoch.fetch_add(1);
        }
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
        {
            std::lock_guard<std::mutex> lk(m);
            quit = true;
        }
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

// Regression for the CI hang of E20 S5 (run 43016826202): more runnable threads than cores. Spinner threads (twice the
// hardware threads) keep every core busy while the render thread drives 3 workers over 8 lanes at 176.4 kHz, with worker
// delays, and the host is started and stopped many times (the stop path is where the lost wakeup hung). Output must
// match the single-thread reference bit for bit and every join must return.
static void oversubscribedRegression() {
    const Layout L{"R3 8 lanes mixed (oversubscribed)", 8, 16384, 8192, 0, false};
    gWhere = L.name;
    gRate = 176400;
    std::printf("test_parallel: %s\n", L.name);
    std::fflush(stdout);
    const uint32_t hw = std::thread::hardware_concurrency() != 0 ? std::thread::hardware_concurrency() : 4;
    std::atomic<bool> stopSpin{false};
    std::vector<std::thread> spinners;
    for (uint32_t i = 0; i < hw * 2; i++) spinners.emplace_back([&] { while (!stopSpin.load(std::memory_order_relaxed)) {} });
    std::vector<float> ref, got;
    CHECK(render(L, 176400, 0, 0, false, ref, nullptr, nullptr), "oversubscribed ref build");
    for (int i = 0; i < 40; i++) {
        CHECK(render(L, 176400, 3, (i % 2) ? 200 : 0, false, got, nullptr, nullptr) && got.size() == ref.size() &&
                  std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
              "oversubscribed iteration %d differs", i);
    }
    // Pure start/stop churn: workers parked on the condition variable while stop() races their predicate check.
    {
        const float one = 1.0f;
        n60_stage_desc st = firStage(1, &one, 1, 0);
        n60_graph_desc d{};
        d.structSize = sizeof d;
        d.abiVersion = N60_GRAPH_ABI_VERSION;
        d.sampleRate = 48000;
        d.maxBlockFrames = 64;
        d.inputChannels = d.outputChannels = 2;
        d.stages = &st;
        d.stageCount = 1;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "churn build");
        for (int i = 0; i < 3000 && g != nullptr; i++) {
            Host host;
            host.start(g, 3);
            if (i % 3 == 0) std::this_thread::yield();
            host.stop();
        }
        n60_graph_retire(g);
    }
    stopSpin = true;
    for (auto &t : spinners) t.join();
}

// E20 S6 (G22): after a snapshot's last parallel phase the woken workers are released instead of spinning to the end of
// the callback. A graph of FIR lanes followed by an EXTERNAL stage: when the EXTERNAL callback runs (after the last
// parallel phase) every woken worker must already have returned from n60_graph_worker_run. Without parking the workers
// spin until the callback ends and the wait below times out.
struct ParkProbe {
    std::atomic<uint32_t> returns{0};
    std::atomic<bool> parkedBeforeStage{false};
    std::atomic<uint32_t> expect{0};
};
static int parkProbeExternal(void *ctx, const float *const *in, float *const *out, uint32_t channels, uint32_t frames) {
    ParkProbe *p = static_cast<ParkProbe *>(ctx);
    const uint32_t want = p->expect.load();
    if (want != 0) {
        const auto t0 = std::chrono::steady_clock::now();
        while (p->returns.load() < want && std::chrono::steady_clock::now() - t0 < std::chrono::seconds(5)) std::this_thread::yield();
        p->parkedBeforeStage.store(p->returns.load() >= want);
    }
    for (uint32_t c = 0; c < channels; c++) std::memcpy(out[c], in[c], sizeof(float) * frames);
    return 1;
}
struct ParkCtx {
    std::mutex *m;
    std::condition_variable *cv;
    std::atomic<uint64_t> *epoch;
};
static void parkWake(void *c, uint32_t) {
    ParkCtx *x = static_cast<ParkCtx *>(c);
    {
        std::lock_guard<std::mutex> lk(*x->m);
        x->epoch->fetch_add(1);
    }
    x->cv->notify_all();
}
static void parkingRegression() {
    gWhere = "workers park after the last parallel phase";
    std::printf("test_parallel: %s\n", gWhere.load());
    std::fflush(stdout);
    auto taps = makeTaps(6000, 3);
    const uint32_t lanes = 4;
    const float active = 1.0f;
    n60_stage_desc st[2];
    st[0] = firStage(1, taps.data(), 6000, 0);
    std::memset(&st[1], 0, sizeof st[1]);
    st[1].structSize = sizeof st[1];
    st[1].kind = N60_STAGE_EXTERNAL;
    st[1].stageId = 2;
    st[1].laneA = N60_LANE_ALL;
    st[1].params = &active;
    st[1].paramCount = 1;
    n60_graph_desc d{};
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = 48000;
    d.maxBlockFrames = 512;
    d.inputChannels = d.outputChannels = lanes;
    d.firScheme = N60_FIR_SCHEME_NONUNIFORM;
    d.stages = st;
    d.stageCount = 2;
    n60_graph *g = nullptr;
    CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK, "park build");
    if (g == nullptr) return;
    ParkProbe probe;
    CHECK(n60_graph_set_external_processor(g, parkProbeExternal, &probe, lanes) == N60_STATUS_OK, "park register");
    std::mutex m;
    std::condition_variable cv;
    std::atomic<uint64_t> epoch{0};
    std::atomic<bool> quit{false};
    ParkCtx cx{&m, &cv, &epoch};
    n60_graph_set_wake(g, &parkWake, &cx);
    const uint32_t workers = 2;
    n60_graph_set_workers(g, workers);
    std::vector<std::thread> threads;
    for (uint32_t w = 1; w <= workers; w++) {
        threads.emplace_back([&, w] {
            uint64_t seen = 0;
            for (;;) {
                {
                    std::unique_lock<std::mutex> lk(m);
                    cv.wait(lk, [&] { return quit.load() || epoch.load() != seen; });
                    if (quit.load()) return;
                    seen = epoch.load();
                }
                n60_graph_worker_run(g, w);
                probe.returns.fetch_add(1);
            }
        });
    }
    std::vector<std::vector<float>> in(lanes), o(lanes);
    fill(in, 512, 9);
    for (auto &v : o) v.assign(512, 0.0f);
    std::vector<const float *> ip(lanes);
    std::vector<float *> op(lanes);
    for (uint32_t c = 0; c < lanes; c++) {
        ip[c] = in[c].data();
        op[c] = o[c].data();
    }
    for (int blk = 0; blk < 6; blk++) {
        probe.returns.store(0);
        probe.expect.store(workers);
        probe.parkedBeforeStage.store(false);
        CHECK(n60_graph_process(g, ip.data(), op.data(), 512) == N60_STATUS_OK, "park process");
        CHECK(probe.parkedBeforeStage.load(), "block %d: workers still inside n60_graph_worker_run after the last parallel phase", blk);
    }
    probe.expect.store(0);
    n60_graph_set_workers(g, 0);
    {
        std::lock_guard<std::mutex> lk(m);
        quit = true;
    }
    cv.notify_all();
    for (auto &t : threads) t.join();
    n60_graph_set_wake(g, nullptr, nullptr);
    n60_graph_set_external_processor(g, nullptr, nullptr, 0);
    n60_graph_retire(g);
}

// G26: run the whole test on a real 2-core budget. Linux only (macOS has no affinity API); N60_PARALLEL_TEST_CPUS=2 pins this
// process to its first two allowed cores, so three workers plus the render thread contend for two, as on a small CI runner.
static void limitCpus() {
    const char *env = std::getenv("N60_PARALLEL_TEST_CPUS");
    if (env == nullptr) return;
#ifdef __linux__
    const int want = std::atoi(env);
    cpu_set_t all, pick;
    CPU_ZERO(&pick);
    if (want > 0 && sched_getaffinity(0, sizeof all, &all) == 0) {
        int taken = 0;
        for (int c = 0; c < CPU_SETSIZE && taken < want; c++) {
            if (CPU_ISSET(c, &all)) { CPU_SET(c, &pick); taken++; }
        }
        if (taken > 0 && sched_setaffinity(0, sizeof pick, &pick) == 0) {
            std::printf("test_parallel: limited to %d cores\n", taken);
            return;
        }
    }
    std::fprintf(stderr, "FAIL test_parallel: could not limit to %s cores\n", env);
    failures++;
#else
    std::printf("test_parallel: N60_PARALLEL_TEST_CPUS ignored (no affinity API on this platform)\n");
#endif
}

// E20 S6b (G21): a single long FIR lane runs its tail (segment 2) as a job. One lane means no lane jobs, so any worker
// activity here is the tail job. Output must equal the single-thread run bit for bit at 0 to 3 workers, with worker delays
// and an absent worker, and the jobs must really be posted and (with workers) taken.
static void tailJobTests(const double *rates, size_t rateCount, bool lite) {
    struct T { const char *name; uint32_t lanes; uint32_t taps; uint64_t mask; };
    const T cases[] = {
        {"tail: one lane, 2 tail partitions", 1, 14000, 0},
        {"tail: one lane, 262144 taps", 1, 262144, 0},
        {"tail: two lanes, one in the mask", 2, 30000, 0x2u},
    };
    for (const T &t : cases) {
        const bool heavy = t.taps > 100000;
        for (size_t ri = 0; ri < rateCount; ri++) {
            const double rate = rates[ri];
            if (heavy && rate != 48000 && rate != 384000) continue;
            if (lite && rate != 48000 && rate != 384000) continue;
            const Layout L{t.name, t.lanes, t.taps, 0, t.mask, false};
            gWhere = t.name;
            gRate = rate;
            std::printf("test_parallel: %s at %.0f Hz\n", t.name, rate);
            std::fflush(stdout);
            std::vector<float> ref, got;
            CHECK(render(L, rate, 0, 0, false, ref, nullptr, nullptr), "%s ref build", t.name);
            for (uint32_t w = 1; w <= 3; w++) {
                n60_graph_parallel_stats stats{};
                long ac = 0;
                CHECK(render(L, rate, w, 0, false, got, &ac, &stats), "%s w%u build", t.name, w);
                CHECK(got.size() == ref.size() && std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                      "%s rate %.0f workers %u: output differs from single thread", t.name, rate, w);
                CHECK(ac == 0, "%s rate %.0f workers %u: realtime call allocated %ld times", t.name, rate, w, ac);
                CHECK(stats.parallelPhases == 0, "%s: a one-lane phase must not run as lane jobs", t.name);
                CHECK(stats.jobsOnCaller + stats.jobsOnWorkers > 0, "%s workers %u: no tail job ran", t.name, w);
                CHECK(stats.wakes > 0, "%s workers %u: workers were never woken", t.name, w);
            }
            CHECK(render(L, rate, 3, 400, false, got, nullptr, nullptr) &&
                      std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                  "%s rate %.0f delayed workers differ", t.name, rate);
            n60_graph_parallel_stats ab{};
            CHECK(render(L, rate, 2, 0, true, got, nullptr, &ab) && std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                  "%s rate %.0f absent worker differs", t.name, rate);
            CHECK(ab.jobsOnWorkers == 0, "%s absent worker ran %llu jobs", t.name, static_cast<unsigned long long>(ab.jobsOnWorkers));
            CHECK(ab.jobsOnCaller > 0, "%s absent worker: the caller ran no tail job", t.name);
        }
    }
}


// ---- E20 G23: rebuild fade with workers, budget refusal, worker changes mid-run, long phases, 32+ lanes ----

struct G23Case {
    const char *name;
    uint32_t lanes;
    uint32_t stages;      // consecutive FIR stages, each on every lane
    uint32_t taps;
    float fadeMs;         // rebuild crossfade length
    float cpuBudgetPct;   // 0 = off; tiny = every rebuild refused
    bool changeWorkers;   // retune set_workers between blocks
};

// Renders blocks, publishing a different filter set mid-run, and returns every output sample. workers < 0 means no host.
static bool renderG23(const G23Case &C, double rate, int workers, std::vector<float> &out, uint64_t *refused) {
    std::vector<std::vector<float>> tapsA(C.stages), tapsB(C.stages);
    for (uint32_t i = 0; i < C.stages; i++) { tapsA[i] = makeTaps(C.taps, 100 + i); tapsB[i] = makeTaps(C.taps, 900 + i); }
    n60_stage_desc stA[16], stB[16];
    for (uint32_t i = 0; i < C.stages; i++) {
        stA[i] = firStage(1 + i, tapsA[i].data(), C.taps, 0);
        stB[i] = firStage(1 + i, tapsB[i].data(), C.taps, 0);
    }
    n60_graph_desc d{};
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 256;
    d.inputChannels = d.outputChannels = C.lanes;
    d.firScheme = N60_FIR_SCHEME_NONUNIFORM;
    d.stages = stA;
    d.stageCount = C.stages;
    n60_graph *g = nullptr;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return false;
    n60_rebuild_options ro{sizeof ro, C.fadeMs, C.cpuBudgetPct, 0};
    n60_graph_set_rebuild_options(g, &ro);
    Host host;
    if (workers >= 0) host.start(g, static_cast<uint32_t>(workers));
    std::vector<std::vector<float>> in(C.lanes), o(C.lanes);
    fill(in, 8192, 9);
    for (auto &v : o) v.assign(256, 0.0f);
    std::vector<const float *> ip(C.lanes);
    std::vector<float *> op(C.lanes);
    out.clear();
    // Enough blocks to finish the warm-up (the latency) and a 20 ms fade at every rate.
    const uint32_t total = static_cast<uint32_t>(rate * 0.25 / 256.0) + 12;
    for (uint32_t blk = 0; blk < total; blk++) {
        for (uint32_t c = 0; c < C.lanes; c++) { ip[c] = in[c].data() + ((blk * 256) % 7000); op[c] = o[c].data(); }
        if (blk == 4) { d.stages = stB; n60_graph_publish(g, &d); }
        if (C.changeWorkers && workers > 0) {
            const uint32_t w = 1 + (blk / 5) % static_cast<uint32_t>(workers);  // moves between 1 and `workers` while rendering
            n60_graph_set_workers(g, w);
        }
        if (n60_graph_process(g, ip.data(), op.data(), 256) != N60_STATUS_OK) { if (workers >= 0) host.stop(); n60_graph_retire(g); return false; }
        for (uint32_t c = 0; c < C.lanes; c++) out.insert(out.end(), o[c].begin(), o[c].end());
        n60_graph_collect(g);
    }
    n60_rebuild_status rs{};
    rs.structSize = sizeof rs;
    if (refused && n60_graph_get_rebuild_status(g, &rs) == N60_STATUS_OK) *refused = rs.refused;
    if (workers >= 0) host.stop();
    n60_graph_retire(g);
    return true;
}

static void g23Tests(const double *rates, size_t rateCount, bool lite) {
    const G23Case cases[] = {
        {"nonzero fade rebuild", 6, 2, 3000, 20.0f, 0.0f, false},
        {"worker count changes mid-run", 6, 2, 3000, 20.0f, 0.0f, true},
        {"nine consecutive FIR stages", 4, 9, 600, 20.0f, 0.0f, false},
        {"32 lanes", 32, 1, 2000, 20.0f, 0.0f, false},
        {"40 lanes", 40, 1, 2000, 20.0f, 0.0f, false},
        {"budget refusal resets", 6, 2, 3000, 20.0f, 0.0001f, false},
    };
    for (const G23Case &C : cases) {
        for (size_t ri = 0; ri < rateCount; ri++) {
            const double rate = rates[ri];
            if (lite && rate != 48000 && rate != 384000) continue;
            gWhere = C.name;
            gRate = rate;
            std::printf("test_parallel: G23 %s at %.0f Hz\n", C.name, rate);
            std::fflush(stdout);
            std::vector<float> ref, got;
            uint64_t refRef = 0, refGot = 0;
            CHECK(renderG23(C, rate, -1, ref, &refRef), "%s ref build", C.name);
            for (int w = 1; w <= 3; w++) {
                CHECK(renderG23(C, rate, w, got, &refGot), "%s w%d build", C.name, w);
                CHECK(got.size() == ref.size() && std::memcmp(got.data(), ref.data(), ref.size() * sizeof(float)) == 0,
                      "%s rate %.0f workers %d: output differs from single thread", C.name, rate, w);
                CHECK(refGot == refRef, "%s rate %.0f workers %d: refused %llu vs %llu", C.name, rate, w,
                      static_cast<unsigned long long>(refGot), static_cast<unsigned long long>(refRef));
            }
            if (C.cpuBudgetPct > 0.0f) CHECK(refRef > 0, "%s: the tiny CPU budget refused no rebuild", C.name);
        }
    }
}

int main() {
    startWatchdog();
    limitCpus();
    const bool lite = std::getenv("N60_PARALLEL_TEST_LITE") != nullptr;
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
            if ((heavy || lite) && rate != 48000 && rate != 384000) continue;  // keep the long-tap case affordable
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

    tailJobTests(rates, 8, lite);
    g23Tests(rates, 8, lite);
    oversubscribedRegression();
    parkingRegression();

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
