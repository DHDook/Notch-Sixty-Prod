#ifndef N60Spatial_h
#define N60Spatial_h

#include <math.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    bool enabled;
    double position;
    float leftGainLinear;
    float rightGainLinear;
} N60SymmetryBalanceSnapshot;


typedef struct {
    bool enabled;
    float amount;
} N60SpeakerCrossfeedSnapshot;


typedef struct {
    bool enabled;
    float amount;
    double headShadowFrequencyHz;
    float headShadowAlpha;
} N60CrosstalkCancellationSnapshot;

static inline bool N60CrosstalkCancellationSnapshotIsValid(N60CrosstalkCancellationSnapshot snapshot) {
    return isfinite(snapshot.amount)
        && snapshot.amount >= 0.0f
        && snapshot.amount <= 1.0f
        && isfinite(snapshot.headShadowFrequencyHz)
        && snapshot.headShadowFrequencyHz >= 200.0
        && snapshot.headShadowFrequencyHz <= 2000.0
        && isfinite(snapshot.headShadowAlpha)
        && snapshot.headShadowAlpha > 0.0f
        && snapshot.headShadowAlpha <= 1.0f;
}

static inline bool N60CrosstalkCancellationDesign(
    double sampleRate,
    double amount,
    double headShadowFrequencyHz,
    bool enabled,
    N60CrosstalkCancellationSnapshot *snapshotOut
) {
    if (snapshotOut == NULL
        || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(amount) || amount < 0.0 || amount > 1.0
        || !isfinite(headShadowFrequencyHz)
        || headShadowFrequencyHz < 200.0 || headShadowFrequencyHz > 2000.0
        || headShadowFrequencyHz >= sampleRate * 0.5) {
        return false;
    }
    const double pi = 3.14159265358979323846264338327950288;
    const double alpha = 1.0 - exp(-2.0 * pi * headShadowFrequencyHz / sampleRate);
    N60CrosstalkCancellationSnapshot snapshot = {
        .enabled = enabled,
        .amount = (float)amount,
        .headShadowFrequencyHz = headShadowFrequencyHz,
        .headShadowAlpha = (float)alpha,
    };
    if (!N60CrosstalkCancellationSnapshotIsValid(snapshot)) return false;
    *snapshotOut = snapshot;
    return true;
}

static inline bool N60SpeakerCrossfeedSnapshotIsValid(N60SpeakerCrossfeedSnapshot snapshot) {
    return isfinite(snapshot.amount)
        && snapshot.amount >= 0.0f
        && snapshot.amount <= 0.5f;
}

static inline bool N60SpeakerCrossfeedDesign(
    double amount,
    bool enabled,
    N60SpeakerCrossfeedSnapshot *snapshotOut
) {
    if (snapshotOut == NULL || !isfinite(amount) || amount < 0.0 || amount > 0.5) return false;
    N60SpeakerCrossfeedSnapshot snapshot = {
        .enabled = enabled,
        .amount = (float)amount,
    };
    if (!N60SpeakerCrossfeedSnapshotIsValid(snapshot)) return false;
    *snapshotOut = snapshot;
    return true;
}

static inline bool N60SymmetryBalanceSnapshotIsValid(N60SymmetryBalanceSnapshot snapshot) {
    if (!isfinite(snapshot.position)
        || snapshot.position < -1.0
        || snapshot.position > 1.0
        || !isfinite(snapshot.leftGainLinear)
        || !isfinite(snapshot.rightGainLinear)
        || snapshot.leftGainLinear < 0.0f
        || snapshot.rightGainLinear < 0.0f) {
        return false;
    }
    if (!snapshot.enabled) {
        return snapshot.leftGainLinear == 1.0f && snapshot.rightGainLinear == 1.0f;
    }
    const float maximumGain = 1.414214f;
    return snapshot.leftGainLinear <= maximumGain
        && snapshot.rightGainLinear <= maximumGain;
}

static inline bool N60SymmetryBalanceDesign(
    double position,
    bool enabled,
    N60SymmetryBalanceSnapshot *snapshotOut
) {
    if (snapshotOut == NULL || !isfinite(position) || position < -1.0 || position > 1.0) {
        return false;
    }

    N60SymmetryBalanceSnapshot snapshot = {
        .enabled = enabled,
        .position = position,
        .leftGainLinear = 1.0f,
        .rightGainLinear = 1.0f,
    };

    if (enabled) {
        const double pi = 3.14159265358979323846264338327950288;
        const double theta = (position + 1.0) * (pi * 0.25);
        const double normalization = 1.4142135623730950488;
        snapshot.leftGainLinear = (float)(normalization * cos(theta));
        snapshot.rightGainLinear = (float)(normalization * sin(theta));
        if (fabs(snapshot.leftGainLinear) < 1.0e-7f) snapshot.leftGainLinear = 0.0f;
        if (fabs(snapshot.rightGainLinear) < 1.0e-7f) snapshot.rightGainLinear = 0.0f;
    }

    if (!N60SymmetryBalanceSnapshotIsValid(snapshot)) return false;
    *snapshotOut = snapshot;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
