#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60Convolution.h"

static void require_true(bool condition, const char *label) {
    if (!condition) {
        fprintf(stderr, "%s failed\n", label);
        exit(1);
    }
}

static void require_close(float actual, float expected, float tolerance, const char *label) {
    if (!isfinite(actual) || fabsf(actual - expected) > tolerance) {
        fprintf(stderr, "%s: got %.9f expected %.9f\n", label, actual, expected);
        exit(1);
    }
}

int main(void) {
    {
        const float identity[] = {1.0f};
        const float kernel[] = {0.25f, 0.5f, 0.25f};
        float output[3] = {0};
        require_true(
            N60FIRConvolveControlPlane(identity, 1, kernel, 3, output, 3),
            "identity cascade"
        );
        require_close(output[0], 0.25f, 1.0e-6f, "identity[0]");
        require_close(output[1], 0.5f, 1.0e-6f, "identity[1]");
        require_close(output[2], 0.25f, 1.0e-6f, "identity[2]");
    }

    {
        const float first[] = {1.0f, 1.0f};
        const float second[] = {1.0f, -1.0f};
        float output[3] = {0};
        require_true(
            N60FIRConvolveControlPlane(first, 2, second, 2, output, 3),
            "known cascade"
        );
        require_close(output[0], 1.0f, 1.0e-5f, "known[0]");
        require_close(output[1], 0.0f, 1.0e-5f, "known[1]");
        require_close(output[2], -1.0f, 1.0e-5f, "known[2]");
    }

    {
        const float first[] = {0.0f, 1.0f};
        const float second[] = {0.0f, 0.0f, 1.0f};
        float output[4] = {0};
        require_true(
            N60FIRConvolveControlPlane(first, 2, second, 3, output, 4),
            "delay cascade"
        );
        require_close(output[0], 0.0f, 1.0e-6f, "delay[0]");
        require_close(output[1], 0.0f, 1.0e-6f, "delay[1]");
        require_close(output[2], 0.0f, 1.0e-6f, "delay[2]");
        require_close(output[3], 1.0f, 1.0e-6f, "delay[3]");
    }

    {
        float *largeA = calloc(N60_CONVOLUTION_MAX_TAPS, sizeof(float));
        float *largeB = calloc(2, sizeof(float));
        float *output = calloc(N60_CONVOLUTION_MAX_TAPS, sizeof(float));
        require_true(largeA != NULL && largeB != NULL && output != NULL, "allocation");
        largeA[0] = 1.0f;
        largeB[0] = 1.0f;
        largeB[1] = 1.0f;
        require_true(
            !N60FIRConvolveControlPlane(
                largeA,
                N60_CONVOLUTION_MAX_TAPS,
                largeB,
                2,
                output,
                N60_CONVOLUTION_MAX_TAPS
            ),
            "combined tap budget"
        );
        free(largeA);
        free(largeB);
        free(output);
    }

    puts("PR34 per-band FIR cascade validation passed.");
    return 0;
}
