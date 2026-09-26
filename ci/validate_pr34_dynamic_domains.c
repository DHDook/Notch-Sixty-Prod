#include "N60DynamicEQ.h"

#include <math.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static void require_true(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static bool configure_band(
    N60DynamicEQSnapshot *snapshot,
    double sampleRate,
    N60DynamicEQLane lane,
    uint32_t index,
    N60DynamicEQShape shape,
    N60DynamicEQDirection direction,
    double frequencyHz
) {
    return N60DynamicEQSnapshotSetBandForLane(
        snapshot,
        sampleRate,
        lane,
        index,
        true,
        shape,
        frequencyHz,
        1.0f,
        0.0f,
        -36.0f,
        10.0f,
        -18.0f,
        2.0f,
        50.0f,
        direction,
        -50.0f,
        2.0f,
        6.0f,
        N60DynamicEQDetectorPeak,
        25.0f
    );
}

static void validate_shapes(double sampleRate) {
    const N60DynamicEQShape shapes[] = {
        N60DynamicEQShapePeak,
        N60DynamicEQShapeLowShelf,
        N60DynamicEQShapeHighShelf,
        N60DynamicEQShapeNotch,
        N60DynamicEQShapeBandPass,
        N60DynamicEQShapeTilt,
    };
    const size_t shapeCount = sizeof(shapes) / sizeof(shapes[0]);
    N60DynamicEQSnapshot snapshot = N60DynamicEQSnapshotMakeBypassed(sampleRate);
    require_true(N60DynamicEQSnapshotSetDomain(&snapshot, N60DynamicEQDomainLinkedStereo), "set linked domain");
    require_true(N60DynamicEQSnapshotSetEnabled(&snapshot, true), "enable linked dynamic EQ");

    for (size_t i = 0; i < shapeCount; ++i) {
        N60DynamicEQDirection direction = shapes[i] == N60DynamicEQShapeNotch
            ? N60DynamicEQDirectionCutOnly : N60DynamicEQDirectionBoth;
        double frequency = 1000.0 + 250.0 * (double)i;
        require_true(
            configure_band(&snapshot, sampleRate, N60DynamicEQLanePrimary, (uint32_t)i, shapes[i], direction, frequency),
            "configure supported dynamic shape"
        );
    }
    require_true(N60DynamicEQSnapshotIsValid(snapshot), "supported-shape snapshot valid");

    N60DynamicEQSnapshot invalidNotch = N60DynamicEQSnapshotMakeBypassed(sampleRate);
    require_true(
        !configure_band(
            &invalidNotch,
            sampleRate,
            N60DynamicEQLanePrimary,
            0,
            N60DynamicEQShapeNotch,
            N60DynamicEQDirectionBoostOnly,
            2000.0
        ),
        "notch boost-only rejected"
    );
}

static void run_sine(
    N60DynamicEQRuntime *runtime,
    N60DynamicEQSnapshot snapshot,
    double sampleRate,
    bool pureSide,
    double *inputRMSLeft,
    double *outputRMSLeft,
    double *inputRMSRight,
    double *outputRMSRight
) {
    const uint32_t totalFrames = (uint32_t)(sampleRate * 0.20);
    const uint32_t measureStart = totalFrames / 2u;
    double inL2 = 0.0, outL2 = 0.0, inR2 = 0.0, outR2 = 0.0;
    uint32_t measured = 0;
    for (uint32_t frame = 0; frame < totalFrames; ++frame) {
        float sample = 0.5f * (float)sin(2.0 * M_PI * 1000.0 * (double)frame / sampleRate);
        float inputLeft = sample;
        float inputRight = pureSide ? -sample : sample;
        float left = inputLeft;
        float right = inputRight;
        N60DynamicEQProcessStereoFrame(runtime, snapshot, &left, &right);
        require_true(isfinite(left) && isfinite(right), "dynamic output finite");
        require_true(fabsf(left) < 4.0f && fabsf(right) < 4.0f, "dynamic output bounded");
        if (frame >= measureStart) {
            inL2 += (double)inputLeft * inputLeft;
            outL2 += (double)left * left;
            inR2 += (double)inputRight * inputRight;
            outR2 += (double)right * right;
            measured += 1u;
        }
    }
    *inputRMSLeft = sqrt(inL2 / measured);
    *outputRMSLeft = sqrt(outL2 / measured);
    *inputRMSRight = sqrt(inR2 / measured);
    *outputRMSRight = sqrt(outR2 / measured);
}

static void validate_dual_mono_isolation(double sampleRate) {
    N60DynamicEQSnapshot snapshot = N60DynamicEQSnapshotMakeBypassed(sampleRate);
    require_true(N60DynamicEQSnapshotSetDomain(&snapshot, N60DynamicEQDomainDualMono), "set dual-mono domain");
    require_true(N60DynamicEQSnapshotSetEnabled(&snapshot, true), "enable dual-mono dynamic EQ");
    require_true(
        configure_band(
            &snapshot,
            sampleRate,
            N60DynamicEQLanePrimary,
            0,
            N60DynamicEQShapePeak,
            N60DynamicEQDirectionCutOnly,
            1000.0
        ),
        "configure left-only dynamic band"
    );
    require_true(N60DynamicEQSnapshotIsValid(snapshot), "dual-mono snapshot valid");

    N60DynamicEQRuntime runtime;
    N60DynamicEQRuntimeReset(&runtime);
    double inL, outL, inR, outR;
    run_sine(&runtime, snapshot, sampleRate, false, &inL, &outL, &inR, &outR);
    require_true(outL < inL * 0.80, "left lane receives dynamic attenuation");
    require_true(fabs(outR - inR) < 0.002, "unconfigured right lane remains transparent");
}

static void validate_mid_side_isolation(double sampleRate) {
    N60DynamicEQSnapshot snapshot = N60DynamicEQSnapshotMakeBypassed(sampleRate);
    require_true(N60DynamicEQSnapshotSetDomain(&snapshot, N60DynamicEQDomainMidSide), "set mid-side domain");
    require_true(N60DynamicEQSnapshotSetEnabled(&snapshot, true), "enable mid-side dynamic EQ");
    require_true(
        configure_band(
            &snapshot,
            sampleRate,
            N60DynamicEQLanePrimary,
            0,
            N60DynamicEQShapePeak,
            N60DynamicEQDirectionCutOnly,
            1000.0
        ),
        "configure mid-only dynamic band"
    );
    require_true(N60DynamicEQSnapshotIsValid(snapshot), "mid-side snapshot valid");

    N60DynamicEQRuntime midRuntime;
    N60DynamicEQRuntimeReset(&midRuntime);
    double inL, outL, inR, outR;
    run_sine(&midRuntime, snapshot, sampleRate, false, &inL, &outL, &inR, &outR);
    require_true(outL < inL * 0.80 && outR < inR * 0.80, "pure Mid is dynamically attenuated");
    require_true(fabs(outL - outR) < 0.002, "pure Mid symmetry retained");

    N60DynamicEQRuntime sideRuntime;
    N60DynamicEQRuntimeReset(&sideRuntime);
    run_sine(&sideRuntime, snapshot, sampleRate, true, &inL, &outL, &inR, &outR);
    require_true(fabs(outL - inL) < 0.002, "pure Side left remains transparent when only Mid has dynamics");
    require_true(fabs(outR - inR) < 0.002, "pure Side right remains transparent when only Mid has dynamics");
}

int main(void) {
    const double rates[] = {44100.0, 48000.0, 96000.0, 192000.0, 384000.0};
    const size_t rateCount = sizeof(rates) / sizeof(rates[0]);
    for (size_t i = 0; i < rateCount; ++i) {
        validate_shapes(rates[i]);
        validate_dual_mono_isolation(rates[i]);
        validate_mid_side_isolation(rates[i]);
        printf("PASS dynamic-domain validation at %.0f Hz\n", rates[i]);
    }
    return 0;
}
