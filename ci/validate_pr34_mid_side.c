#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdio.h>

#include "../NotchSixty/Audio/Realtime/N60Biquad.h"

static void encode_mid_side(float left, float right, float *mid, float *side) {
    *mid = 0.5f * (left + right);
    *side = 0.5f * (left - right);
}

static void decode_mid_side(float mid, float side, float *left, float *right) {
    *left = mid + side;
    *right = mid - side;
}

static double rms_gain_db_for_mid_filter(double sample_rate, bool pure_mid) {
    N60BiquadCoefficients coefficients;
    assert(N60BiquadDesign(
        N60BiquadFilterTypePeaking,
        sample_rate,
        1000.0,
        6.0,
        1.0,
        &coefficients
    ));
    N60BiquadState mid_state = {0};
    double input_sum = 0.0;
    double output_sum = 0.0;
    const int total = 32768;
    const int warmup = 8192;
    for (int frame = 0; frame < total; ++frame) {
        float x = (float)(0.1 * sin(2.0 * M_PI * 1000.0 * (double)frame / sample_rate));
        float left = x;
        float right = pure_mid ? x : -x;
        float mid = 0.0f;
        float side = 0.0f;
        encode_mid_side(left, right, &mid, &side);
        mid = N60BiquadProcessSample(coefficients, &mid_state, mid);
        decode_mid_side(mid, side, &left, &right);
        if (frame >= warmup) {
            input_sum += (double)x * (double)x;
            output_sum += (double)left * (double)left;
        }
    }
    return 10.0 * log10(output_sum / input_sum);
}

int main(void) {
    const double rates[] = {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0, 352800.0, 384000.0};

    const float vectors[][2] = {
        {0.25f, -0.5f},
        {0.75f, 0.75f},
        {-0.6f, 0.6f},
        {0.0f, 0.0f},
    };
    for (unsigned i = 0; i < sizeof(vectors) / sizeof(vectors[0]); ++i) {
        float mid = 0.0f, side = 0.0f, left = 0.0f, right = 0.0f;
        encode_mid_side(vectors[i][0], vectors[i][1], &mid, &side);
        decode_mid_side(mid, side, &left, &right);
        assert(fabsf(left - vectors[i][0]) < 1.0e-7f);
        assert(fabsf(right - vectors[i][1]) < 1.0e-7f);
    }

    for (unsigned i = 0; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        double mid_gain = rms_gain_db_for_mid_filter(rates[i], true);
        double side_gain = rms_gain_db_for_mid_filter(rates[i], false);
        assert(isfinite(mid_gain));
        assert(isfinite(side_gain));
        assert(fabs(mid_gain - 6.0) < 0.25);
        assert(fabs(side_gain) < 0.05);
    }

    puts("PR34 Mid/Side validator passed through 384 kHz.");
    return 0;
}
