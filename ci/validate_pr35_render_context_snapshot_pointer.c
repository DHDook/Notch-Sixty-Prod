#include "N60RenderKernel.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

_Static_assert(sizeof(N60RenderKernelRenderContext) * 8u < sizeof(N60DSPGraphSnapshot),
               "render context should remain much smaller than the pinned graph snapshot");

static void require(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "%s\n", message);
        exit(2);
    }
}

int main(void) {
    N60RenderKernel *kernel = N60RenderKernelCreate();
    require(kernel != NULL, "kernel allocation failed");

    N60DSPGraphSnapshot first = N60DSPGraphSnapshotMakeUnity(48000.0);
    first.inputGainLinear = 0.75f;
    require(N60RenderKernelPublishSnapshot(kernel, first), "first graph publish failed");

    N60RenderKernelRenderContext held = N60RenderKernelBeginRender(kernel);
    require(held.acquired, "first render context not acquired");
    require(held.snapshot != NULL, "first render context has no snapshot pointer");
    const N60DSPGraphSnapshot *heldPointer = held.snapshot;
    uint64_t heldGeneration = held.snapshot->generation;
    require(fabs(held.snapshot->sampleRate - 48000.0) < 0.5, "first context sample rate mismatch");
    require(fabsf(held.snapshot->inputGainLinear - 0.75f) < 1.0e-7f, "first context gain mismatch");

    // Publishing the next graph uses the other slot. The reader-pinned first slot
    // must remain immutable and directly readable until EndRender releases it.
    N60DSPGraphSnapshot second = N60DSPGraphSnapshotMakeUnity(96000.0);
    second.inputGainLinear = 0.25f;
    require(N60RenderKernelPublishSnapshot(kernel, second), "second graph publish failed");
    require(held.snapshot == heldPointer, "held snapshot pointer changed after publish");
    require(held.snapshot->generation == heldGeneration, "held generation changed after publish");
    require(fabs(held.snapshot->sampleRate - 48000.0) < 0.5, "held snapshot was overwritten");
    require(fabsf(held.snapshot->inputGainLinear - 0.75f) < 1.0e-7f, "held snapshot gain was overwritten");

    N60RenderKernelEndRender(kernel, &held, 0);
    require(!held.acquired, "held context did not release reader");

    N60RenderKernelRenderContext latest = N60RenderKernelBeginRender(kernel);
    require(latest.acquired && latest.snapshot != NULL, "latest render context not acquired");
    require(fabs(latest.snapshot->sampleRate - 96000.0) < 0.5, "latest context did not see second graph");
    require(fabsf(latest.snapshot->inputGainLinear - 0.25f) < 1.0e-7f, "latest context gain mismatch");
    N60RenderKernelEndRender(kernel, &latest, 0);

    // Once the old reader is released its slot is available for a later publish.
    N60DSPGraphSnapshot third = N60DSPGraphSnapshotMakeUnity(192000.0);
    require(N60RenderKernelPublishSnapshot(kernel, third), "third graph publish failed after release");

    N60RenderKernelDestroy(kernel);
    puts("PR35 render-context pinned snapshot pointer: PASS");
    return 0;
}
