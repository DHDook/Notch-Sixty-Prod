#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "N60RenderKernel.h"

#define SAMPLE_RATE 96000.0
#define BUFFER_FRAMES 512u
#define WARMUP_BUFFERS 128u
#define MEASURE_BUFFERS 4096u

typedef enum {
    BenchmarkBypass = 0,
    BenchmarkUnity = 1,
    BenchmarkCompressor = 2,
} BenchmarkCase;

static volatile double benchmark_sink = 0.0;

static double monotonic_seconds(void) {
    struct timespec now = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0.0;
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static bool configure_snapshot(N60DSPGraphSnapshot *snapshot, BenchmarkCase benchmarkCase) {
    if (snapshot == NULL) return false;
    *snapshot = N60DSPGraphSnapshotMakeUnity(SAMPLE_RATE);
    if (benchmarkCase == BenchmarkBypass) {
        snapshot->bypassed = true;
        return true;
    }
    if (benchmarkCase == BenchmarkCompressor) {
        return N60DynamicsSnapshotSetCompressorAdvanced(
            &snapshot->dynamics,
            SAMPLE_RATE,
            true,
            -18.0f,
            3.0f,
            6.0f,
            10.0f,
            150.0f,
            0.0f,
            N60CompressorTopologyFeedForward,
            false,
            0.0f
        );
    }
    return true;
}

static bool process_buffers(
    N60RenderKernel *kernel,
    uint32_t bufferCount,
    double *sink
) {
    if (kernel == NULL || sink == NULL) return false;
    double accumulator = *sink;
    for (uint32_t bufferIndex = 0; bufferIndex < bufferCount; ++bufferIndex) {
        N60RenderKernelRenderContext context = N60RenderKernelBeginRender(kernel);
        if (!context.acquired || context.snapshot == NULL) return false;
        for (uint32_t frameIndex = 0; frameIndex < BUFFER_FRAMES; ++frameIndex) {
            uint32_t pattern = bufferIndex * BUFFER_FRAMES + frameIndex;
            float inputLeft = (pattern & 1u) == 0u ? 0.18f : -0.17f;
            float inputRight = (pattern & 2u) == 0u ? -0.13f : 0.14f;
            float outputLeft = 0.0f;
            float outputRight = 0.0f;
            N60RenderKernelProcessStereoFrameInContext(
                kernel,
                &context,
                inputLeft,
                inputRight,
                &outputLeft,
                &outputRight
            );
            accumulator += (double)outputLeft * 1.0e-9 + (double)outputRight * 1.0e-9;
        }
        N60RenderKernelEndRender(kernel, &context, BUFFER_FRAMES);
    }
    *sink = accumulator;
    return true;
}

static bool run_case(const char *name, BenchmarkCase benchmarkCase) {
    N60RenderKernel *kernel = N60RenderKernelCreate();
    if (kernel == NULL) {
        fprintf(stderr, "%s: unable to create render kernel\n", name);
        return false;
    }

    N60DSPGraphSnapshot snapshot = {0};
    if (!configure_snapshot(&snapshot, benchmarkCase)
        || !N60RenderKernelPublishSnapshot(kernel, snapshot)) {
        fprintf(stderr, "%s: unable to configure/publish graph\n", name);
        N60RenderKernelDestroy(kernel);
        return false;
    }

    double sink = 0.0;
    if (!process_buffers(kernel, WARMUP_BUFFERS, &sink)) {
        fprintf(stderr, "%s: warmup failed\n", name);
        N60RenderKernelDestroy(kernel);
        return false;
    }

    double start = monotonic_seconds();
    if (start <= 0.0 || !process_buffers(kernel, MEASURE_BUFFERS, &sink)) {
        fprintf(stderr, "%s: measurement failed\n", name);
        N60RenderKernelDestroy(kernel);
        return false;
    }
    double finish = monotonic_seconds();
    N60RenderKernelDestroy(kernel);
    if (finish <= start) {
        fprintf(stderr, "%s: invalid timer result\n", name);
        return false;
    }

    const double frames = (double)BUFFER_FRAMES * (double)MEASURE_BUFFERS;
    const double seconds = finish - start;
    const double nsPerFrame = seconds * 1000000000.0 / frames;
    const double oneCorePercentAt96k = nsPerFrame * 0.0096;
    benchmark_sink += sink;
    printf(
        "%s: %.2f ns/frame, theoretical %.2f%% of one core at 96 kHz (%.3f s / %.0f frames)\n",
        name,
        nsPerFrame,
        oneCorePercentAt96k,
        seconds,
        frames
    );
    return true;
}

int main(void) {
    if (!run_case("global-bypass", BenchmarkBypass)) return EXIT_FAILURE;
    if (!run_case("unity-parked", BenchmarkUnity)) return EXIT_FAILURE;
    if (!run_case("compressor", BenchmarkCompressor)) return EXIT_FAILURE;
    if (benchmark_sink == 123456789.0) puts("unreachable");
    return EXIT_SUCCESS;
}
