#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "../NotchSixty/Audio/Realtime/N60RenderKernel.h"

static void require_close(float actual, float expected, float tolerance, const char *label) {
    if (!isfinite(actual) || fabsf(actual - expected) > tolerance) {
        fprintf(stderr, "%s: got %.9f expected %.9f\n", label, actual, expected);
        exit(1);
    }
}

int main(void) {
    const float pairs[][2] = {
        {0.0f, 0.0f},
        {0.25f, -0.5f},
        {-0.75f, 0.125f},
        {1.0f, 1.0f},
        {1.0f, -1.0f},
    };

    for (size_t i = 0; i < sizeof(pairs) / sizeof(pairs[0]); ++i) {
        float mid = 0.0f;
        float side = 0.0f;
        float left = 0.0f;
        float right = 0.0f;
        N60MidSideEncode(pairs[i][0], pairs[i][1], &mid, &side);
        N60MidSideDecode(mid, side, &left, &right);
        require_close(left, pairs[i][0], 1.0e-7f, "L/R -> M/S -> L left identity");
        require_close(right, pairs[i][1], 1.0e-7f, "L/R -> M/S -> R right identity");
    }

    float mid = 0.0f;
    float side = 0.0f;
    N60MidSideEncode(0.4f, 0.4f, &mid, &side);
    require_close(mid, 0.4f, 1.0e-7f, "mono mid");
    require_close(side, 0.0f, 1.0e-7f, "mono side null");

    N60MidSideEncode(0.4f, -0.4f, &mid, &side);
    require_close(mid, 0.0f, 1.0e-7f, "anti-phase mid null");
    require_close(side, 0.4f, 1.0e-7f, "anti-phase side");

    puts("PR34 Mid/Side contract validation passed.");
    return 0;
}
