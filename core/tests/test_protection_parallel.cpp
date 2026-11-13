// E20 S10b (G33): lane-parallel PROTECTION. The output and the readbacks must be bit-identical to the serial stage (no workers)
// at 1 to 3 workers, at the eight standard rates, for 2, 6 and 12 lanes, with the limiter alone, with the clipper, at factor 2 and
// 4, with and without the gain rider, for block sizes that are not multiples of 256, and with a worker that never runs.
// The oversampled rows are shared with nothing else, so the path also has to stay allocation-free.
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

#include "n60/graph.h"

static std::atomic<bool> armed{false};
static std::atomic<long> allocs{0};
void *operator new(std::size_t n) { if (armed.load()) allocs.fetch_add(1); return std::malloc(n ? n : 1); }
void *operator new[](std::size_t n) { if (armed.load()) allocs.fetch_add(1); return std::malloc(n ? n : 1); }
void operator delete(void *p) noexcept { std::free(p); }
void operator delete[](void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }
void operator delete[](void *p, std::size_t) noexcept { std::free(p); }

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

struct Host {
    n60_graph *g = nullptr;
    std::mutex m;
    std::condition_variable cv;
    std::atomic<uint64_t> epoch{0};
    bool quit = false;
    std::vector<std::thread> threads;
    static void wake(void *ctx, uint32_t) {
        Host *h = static_cast<Host *>(ctx);
        { std::lock_guard<std::mutex> lk(h->m); h->epoch.fetch_add(1); }
        h->cv.notify_all();
    }
    void start(n60_graph *graph, uint32_t workers) {
        g = graph;
        n60_graph_set_wake(g, &Host::wake, this);
        n60_graph_set_workers(g, workers);
        for (uint32_t w = 1; w <= workers; w++) {
            threads.emplace_back([this, w] {
                uint64_t seen = 0;
                for (;;) {
                    {
                        std::unique_lock<std::mutex> lk(m);
                        cv.wait(lk, [&] { return quit || epoch.load() != seen; });
                        if (quit) return;
                        seen = epoch.load();
                    }
                    n60_graph_worker_run(g, w);
                }
            });
        }
    }
    void stop() {
        n60_graph_set_workers(g, 0);
        { std::lock_guard<std::mutex> lk(m); quit = true; }
        cv.notify_all();
        for (auto &t : threads) t.join();
        threads.clear();
        n60_graph_set_wake(g, nullptr, nullptr);
    }
};

struct Case {
    const char *name;
    uint32_t lanes;
    bool clipper, truePeak, rider;
    float factor;   // oversampling factor when truePeak is off
    bool limiter;
    float ampl;     // input amplitude (above the ceiling engages the limiter)
};

struct Result {
    std::vector<float> out;
    std::vector<float> read;  // per lane: grMax, grNow, in peak, out peak
    long allocs = 0;
    bool ok = false;
};

static Result render(const Case &c, double rate, uint32_t workers, bool absent) {
    Result res;
    float p[18] = {c.limiter ? 1.0f : 0.0f, -1.0f, 1.0f, 50.0f, 5.0f, c.truePeak ? 1.0f : 0.0f, c.factor,
                   c.clipper ? 1.0f : 0.0f, 3.0f, -3.0f, 0.8f, 1.0f, 1.0f, 0.0f,
                   c.rider ? 1.0f : 0.0f, 3.0f, 6.0f, 0.0f};
    n60_stage_desc st;
    std::memset(&st, 0, sizeof st);
    st.structSize = sizeof st;
    st.kind = N60_STAGE_PROTECTION;
    st.stageId = 1;
    st.laneA = N60_LANE_ALL;
    st.params = p;
    st.paramCount = 18;
    n60_graph_desc d{};
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = 1024;
    d.inputChannels = d.outputChannels = c.lanes;
    d.firScheme = N60_FIR_SCHEME_NONUNIFORM;
    d.stages = &st;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    { const n60_status bs = n60_graph_build(&d, &g); if (bs != N60_STATUS_OK) { std::fprintf(stderr, "build status %d\n", static_cast<int>(bs)); return res; } }
    Host host;
    if (workers != 0) {
        if (absent) n60_graph_set_workers(g, workers);
        else host.start(g, workers);
    }
    const uint32_t total = 6000;
    std::vector<std::vector<float>> in(c.lanes, std::vector<float>(total)), o(c.lanes, std::vector<float>(1024));
    for (uint32_t l = 0; l < c.lanes; l++) {
        for (uint32_t i = 0; i < total; i++) {
            // loud tone with a burst every few thousand samples, a different phase per lane
            const float burst = (i / 700) % 3 == 1 ? 1.0f : 0.35f;
            in[l][i] = c.ampl * burst * std::sin(0.031f * static_cast<float>(i) * (1.0f + 0.2f * l) + l);
        }
    }
    std::vector<const float *> ip(c.lanes);
    std::vector<float *> op(c.lanes);
    const uint32_t sizes[] = {1024, 256, 37, 1, 300, 512, 100};
    uint32_t pos = 0;
    for (int blk = 0; blk < 12 && pos < total; blk++) {
        uint32_t n = sizes[blk % 7];
        if (pos + n > total) n = total - pos;
        for (uint32_t l = 0; l < c.lanes; l++) { ip[l] = in[l].data() + pos; op[l] = o[l].data(); }
        pos += n;
        if (blk >= 2) { allocs = 0; armed = true; }
        const n60_status s = n60_graph_process(g, ip.data(), op.data(), n);
        if (blk >= 2) { armed = false; res.allocs += allocs.load(); }
        if (s != N60_STATUS_OK) { if (workers && !absent) host.stop(); n60_graph_retire(g); return res; }
        for (uint32_t l = 0; l < c.lanes; l++) res.out.insert(res.out.end(), o[l].begin(), o[l].begin() + n);
        n60_graph_collect(g);
    }
    for (uint32_t l = 0; l < c.lanes; l++) {
        n60_dynamics_readback rb{};
        rb.structSize = sizeof rb;
        if (n60_graph_read_dynamics(g, 1, l, &rb) != N60_STATUS_OK) { if (workers && !absent) host.stop(); n60_graph_retire(g); return res; }
        res.read.push_back(rb.grMaxDb);
        res.read.push_back(rb.grNowDb);
        res.read.push_back(rb.inTruePeak);
        res.read.push_back(rb.outTruePeak);
    }
    n60_graph_parallel_stats ps{};
    ps.structSize = sizeof ps;
    n60_graph_read_parallel(g, &ps);
    if (workers && !absent) host.stop();
    n60_graph_retire(g);
    res.ok = true;
    // a run with workers must have used the lane jobs when the path is eligible (limiter or clipper, factor above 1, no rider)
    if (workers != 0 && !c.rider) CHECK(ps.parallelPhases != 0, "%s %.0f Hz: PROTECTION never ran as jobs", c.name, rate);
    return res;
}

static bool same(const std::vector<float> &a, const std::vector<float> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

int main() {
    const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    const Case cases[] = {
        {"limiter tp 2 lanes", 2, false, true, false, 1, true, 1.6f},
        {"limiter tp 6 lanes clipper", 6, true, true, false, 1, true, 1.6f},
        {"limiter x2 12 lanes", 12, false, false, false, 2, true, 1.6f},
        {"clipper only x4 6 lanes", 6, true, false, false, 4, false, 1.6f},
        {"quiet limiter tp 6 lanes", 6, false, true, false, 1, true, 0.2f},
        {"rider on 6 lanes (serial)", 6, false, true, true, 1, true, 1.6f},
    };
    for (const Case &c : cases) {
        for (double rate : rates) {
            const Result ref = render(c, rate, 0, false);
            CHECK(ref.ok, "%s %.0f Hz: serial render failed", c.name, rate);
            if (!ref.ok) continue;
            for (uint32_t w = 1; w <= 3; w++) {
                const Result r = render(c, rate, w, false);
                CHECK(r.ok, "%s %.0f Hz w=%u: render failed", c.name, rate, w);
                if (!r.ok) continue;
                CHECK(same(r.out, ref.out), "%s %.0f Hz: output differs at %u workers", c.name, rate, w);
                CHECK(same(r.read, ref.read), "%s %.0f Hz: readbacks differ at %u workers", c.name, rate, w);
                CHECK(r.allocs == 0, "%s %.0f Hz: %ld allocations on the render thread", c.name, rate, r.allocs);
            }
        }
        const Result ref = render(c, 48000, 0, false), absent = render(c, 48000, 2, true);
        CHECK(absent.ok && same(absent.out, ref.out), "%s: output differs with workers set but absent", c.name);
    }
    // sanity: the limiter really limited (the comparison above would pass trivially on silence)
    const Result loud = render(cases[0], 48000, 0, false);
    float peak = 0.0f, grMax = 0.0f;
    for (float v : loud.out) peak = std::fmax(peak, std::fabs(v));
    for (size_t k = 0; k + 3 < loud.read.size(); k += 4) grMax = std::fmax(grMax, loud.read[k]);
    CHECK(peak > 0.5f && peak < 1.0f && grMax > 1.0f, "limiter case not exercising the limiter (peak %f, grMax %f dB)", peak, grMax);
    if (failures == 0) std::puts("protection parallel: ok");
    return failures == 0 ? 0 : 1;
}
