#ifndef N60Biquad_h
#define N60Biquad_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    N60BiquadFilterTypePeaking = 0,
    N60BiquadFilterTypeLowShelf = 1,
    N60BiquadFilterTypeHighShelf = 2,
    N60BiquadFilterTypeLowPass = 3,
    N60BiquadFilterTypeHighPass = 4,
    N60BiquadFilterTypeNotch = 5,
} N60BiquadFilterType;

typedef struct {
    float b0;
    float b1;
    float b2;
    float a1;
    float a2;
} N60BiquadCoefficients;

typedef struct {
    float z1;
    float z2;
} N60BiquadState;

typedef struct {
    bool enabled;
    N60BiquadFilterType type;
    double frequencyHz;
    double gainDB;
    double q;
    N60BiquadCoefficients coefficients;
} N60BiquadBandSnapshot;

N60BiquadCoefficients N60BiquadCoefficientsMakeIdentity(void);

// Control-plane coefficient design. Never call from the realtime render path.
bool N60BiquadDesign(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    double gainDB,
    double q,
    N60BiquadCoefficients * _Nonnull coefficients
);

bool N60BiquadBandSnapshotMake(
    N60BiquadFilterType type,
    double sampleRate,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled,
    N60BiquadBandSnapshot * _Nonnull band
);

// Realtime-safe state processing. Coefficients must already be normalized.
float N60BiquadProcessSample(
    N60BiquadCoefficients coefficients,
    N60BiquadState * _Nonnull state,
    float input
);

// Deterministic control/test helper.
double N60BiquadMagnitudeDB(
    N60BiquadCoefficients coefficients,
    double sampleRate,
    double frequencyHz
);

#ifdef __cplusplus
}
#endif

#endif
