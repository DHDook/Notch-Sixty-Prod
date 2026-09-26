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
