#include <stdint.h>
#include <stdio.h>

#include "N60RenderKernel.h"

static int meters_are_zero(N60RenderKernelDiagnostics diagnostics) {
    return diagnostics.inputMeter.peakLeft == 0.0f
        && diagnostics.inputMeter.peakRight == 0.0f
        && diagnostics.inputMeter.rmsLeft == 0.0f
        && diagnostics.inputMeter.rmsRight == 0.0f
        && diagnostics.postEQMeter.peakLeft == 0.0f
        && diagnostics.postEQMeter.peakRight == 0.0f
        && diagnostics.postEQMeter.rmsLeft == 0.0f
        && diagnostics.postEQMeter.rmsRight == 0.0f
        && diagnostics.outputMeter.peakLeft == 0.0f
        && diagnostics.outputMeter.peakRight == 0.0f
        && diagnostics.outputMeter.rmsLeft == 0.0f
        && diagnostics.outputMeter.rmsRight == 0.0f;
}

int main(void) {
    N60RenderKernel *kernel = N60RenderKernelCreate();
    if (kernel == NULL) {
        fputs("failed to create render kernel\n", stderr);
        return 1;
    }

    N60DSPGraphSnapshot snapshot = N60DSPGraphSnapshotMakeUnity(96000.0);
    if (snapshot.meteringEnabled) {
        fputs("unity graph unexpectedly enables metering\n", stderr);
        N60RenderKernelDestroy(kernel);
        return 1;
    }
    if (!N60RenderKernelPublishSnapshot(kernel, snapshot)) {
        fputs("failed to publish meter-off snapshot\n", stderr);
        N60RenderKernelDestroy(kernel);
        return 1;
    }

    for (uint32_t frame = 0; frame < 256u; ++frame) {
        float left = 0.25f;
        float right = -0.125f;
        float outputLeft = 0.0f;
        float outputRight = 0.0f;
        N60RenderKernelProcessStereoFrame(kernel, left, right, &outputLeft, &outputRight);
    }

    N60RenderKernelDiagnostics diagnostics = N60RenderKernelGetDiagnostics(kernel);
    if (diagnostics.meteringEnabled || !meters_are_zero(diagnostics)) {
        fputs("meter processing advanced while disabled\n", stderr);
        N60RenderKernelDestroy(kernel);
        return 1;
    }

    if (!N60DSPGraphSnapshotSetMeteringEnabled(&snapshot, true)
        || !N60RenderKernelPublishSnapshot(kernel, snapshot)) {
        fputs("failed to publish meter-on snapshot\n", stderr);
        N60RenderKernelDestroy(kernel);
        return 1;
    }

    for (uint32_t frame = 0; frame < 256u; ++frame) {
        float outputLeft = 0.0f;
        float outputRight = 0.0f;
        N60RenderKernelProcessStereoFrame(kernel, 0.25f, -0.125f, &outputLeft, &outputRight);
    }

    diagnostics = N60RenderKernelGetDiagnostics(kernel);
    if (!diagnostics.meteringEnabled
        || diagnostics.inputMeter.peakLeft <= 0.0f
        || diagnostics.postEQMeter.peakLeft <= 0.0f
        || diagnostics.outputMeter.peakLeft <= 0.0f
        || diagnostics.inputMeter.rmsLeft <= 0.0f
        || diagnostics.outputMeter.rmsLeft <= 0.0f) {
        fputs("explicitly enabled metering did not publish readings\n", stderr);
        N60RenderKernelDestroy(kernel);
        return 1;
    }

    N60RenderKernelDestroy(kernel);
    puts("PR35 meter gating validation passed");
    return 0;
}
