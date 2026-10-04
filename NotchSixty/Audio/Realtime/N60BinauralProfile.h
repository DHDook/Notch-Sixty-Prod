#ifndef N60BinauralProfile_h
#define N60BinauralProfile_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    N60BinauralProfileKindHRTF = 0,
    N60BinauralProfileKindBRIR = 1,
} N60BinauralProfileKind;

typedef enum {
    N60BinauralLFEModeEqualEar = 0,
    N60BinauralLFEModeDirectional = 1,
} N60BinauralLFEMode;

typedef struct {
    N60ProgramChannelRole role;
    double azimuthDegrees;
    double elevationDegrees;
    double distanceMeters;
} N60BinauralSourcePosition;

typedef struct {
    double sampleRate;
    N60ProgramChannelLayout programLayout;
    N60BinauralProfileKind kind;
    N60BinauralLFEMode lfeMode;
    uint32_t tapCount;
    uint32_t declaredLatencyFrames;
    N60BinauralSourcePosition sources[N60_MAX_PROGRAM_CHANNELS];
} N60BinauralProfileDescriptor;

/// Normalized two-receiver SOFA-style HRIR view used by the proprietary renderer.
/// A file/parser adapter must convert SOFA SourcePosition to spherical degrees/metres,
/// expose exactly two receiver IRs, and bake any SOFA Data.Delay into the IRs before
/// creating this view. The realtime renderer never parses HDF5/NetCDF/SOFA files.
typedef struct {
    double sampleRate;
    uint32_t measurementCount;
    uint32_t tapCount;
    const double * _Nonnull azimuthDegrees;
    const double * _Nonnull elevationDegrees;
    const double * _Nonnull distanceMeters;
    const float * _Nonnull leftIR;
    const float * _Nonnull rightIR;
} N60SOFAHRTFNormalizedView;

static inline N60BinauralSourcePosition N60BinauralDefaultPositionForRole(
    N60ProgramChannelRole role
) {
    N60BinauralSourcePosition position = {
        .role = role,
        .azimuthDegrees = 0.0,
        .elevationDegrees = 0.0,
        .distanceMeters = 1.0,
    };
    switch (role) {
    case N60ProgramChannelRoleFrontLeft: position.azimuthDegrees = -30.0; break;
    case N60ProgramChannelRoleFrontRight: position.azimuthDegrees = 30.0; break;
    case N60ProgramChannelRoleFrontCenter: position.azimuthDegrees = 0.0; break;
    case N60ProgramChannelRoleLowFrequencyEffects: position.azimuthDegrees = 0.0; break;
    case N60ProgramChannelRoleSideLeft: position.azimuthDegrees = -110.0; break;
    case N60ProgramChannelRoleSideRight: position.azimuthDegrees = 110.0; break;
    case N60ProgramChannelRoleRearLeft: position.azimuthDegrees = -150.0; break;
    case N60ProgramChannelRoleRearRight: position.azimuthDegrees = 150.0; break;
    case N60ProgramChannelRoleWideLeft: position.azimuthDegrees = -60.0; break;
    case N60ProgramChannelRoleWideRight: position.azimuthDegrees = 60.0; break;
    case N60ProgramChannelRoleTopFrontLeft:
        position.azimuthDegrees = -45.0; position.elevationDegrees = 45.0; break;
    case N60ProgramChannelRoleTopFrontRight:
        position.azimuthDegrees = 45.0; position.elevationDegrees = 45.0; break;
    case N60ProgramChannelRoleTopMiddleLeft:
        position.azimuthDegrees = -90.0; position.elevationDegrees = 60.0; break;
    case N60ProgramChannelRoleTopMiddleRight:
        position.azimuthDegrees = 90.0; position.elevationDegrees = 60.0; break;
    case N60ProgramChannelRoleTopRearLeft:
        position.azimuthDegrees = -135.0; position.elevationDegrees = 45.0; break;
    case N60ProgramChannelRoleTopRearRight:
        position.azimuthDegrees = 135.0; position.elevationDegrees = 45.0; break;
    case N60ProgramChannelRoleUnused:
    default:
        break;
    }
    return position;
}

static inline N60BinauralProfileDescriptor N60BinauralProfileDescriptorMake(
    double sampleRate,
    N60ProgramChannelLayout programLayout,
    N60BinauralProfileKind kind,
    uint32_t tapCount
) {
    N60BinauralProfileDescriptor descriptor = {0};
    if (!isfinite(sampleRate)
        || sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&programLayout)
        || kind < N60BinauralProfileKindHRTF
        || kind > N60BinauralProfileKindBRIR
        || tapCount == 0u) {
        return descriptor;
    }
    descriptor.sampleRate = sampleRate;
    descriptor.programLayout = programLayout;
    descriptor.kind = kind;
    descriptor.lfeMode = N60BinauralLFEModeEqualEar;
    descriptor.tapCount = tapCount;
    for (uint32_t channel = 0; channel < programLayout.channelCount; ++channel) {
        descriptor.sources[channel] = N60BinauralDefaultPositionForRole(programLayout.channels[channel]);
    }
    return descriptor;
}

static inline bool N60BinauralProfileDescriptorSetSourcePosition(
    N60BinauralProfileDescriptor * _Nonnull descriptor,
    uint32_t channelIndex,
    double azimuthDegrees,
    double elevationDegrees,
    double distanceMeters
) {
    if (descriptor == NULL
        || channelIndex >= descriptor->programLayout.channelCount
        || !isfinite(azimuthDegrees)
        || azimuthDegrees < -180.0
        || azimuthDegrees > 180.0
        || !isfinite(elevationDegrees)
        || elevationDegrees < -90.0
        || elevationDegrees > 90.0
        || !isfinite(distanceMeters)
        || distanceMeters <= 0.0) {
        return false;
    }
    descriptor->sources[channelIndex].role = descriptor->programLayout.channels[channelIndex];
    descriptor->sources[channelIndex].azimuthDegrees = azimuthDegrees;
    descriptor->sources[channelIndex].elevationDegrees = elevationDegrees;
    descriptor->sources[channelIndex].distanceMeters = distanceMeters;
    return true;
}

static inline bool N60BinauralProfileDescriptorIsValid(
    const N60BinauralProfileDescriptor * _Nullable descriptor,
    uint32_t maximumTapCount
) {
    if (descriptor == NULL
        || !isfinite(descriptor->sampleRate)
        || descriptor->sampleRate <= 0.0
        || !N60ProgramChannelLayoutIsValid(&descriptor->programLayout)
        || descriptor->kind < N60BinauralProfileKindHRTF
        || descriptor->kind > N60BinauralProfileKindBRIR
        || descriptor->lfeMode < N60BinauralLFEModeEqualEar
        || descriptor->lfeMode > N60BinauralLFEModeDirectional
        || descriptor->tapCount == 0u
        || descriptor->tapCount > maximumTapCount) {
        return false;
    }
    for (uint32_t channel = 0; channel < descriptor->programLayout.channelCount; ++channel) {
        const N60BinauralSourcePosition source = descriptor->sources[channel];
        if (source.role != descriptor->programLayout.channels[channel]
            || !isfinite(source.azimuthDegrees)
            || source.azimuthDegrees < -180.0
            || source.azimuthDegrees > 180.0
            || !isfinite(source.elevationDegrees)
            || source.elevationDegrees < -90.0
            || source.elevationDegrees > 90.0
            || !isfinite(source.distanceMeters)
            || source.distanceMeters <= 0.0) {
            return false;
        }
    }
    return true;
}

static inline bool N60SOFAHRTFNormalizedViewIsValid(
    const N60SOFAHRTFNormalizedView * _Nullable view,
    uint32_t maximumTapCount
) {
    if (view == NULL
        || !isfinite(view->sampleRate)
        || view->sampleRate <= 0.0
        || view->measurementCount == 0u
        || view->tapCount == 0u
        || view->tapCount > maximumTapCount
        || view->azimuthDegrees == NULL
        || view->elevationDegrees == NULL
        || view->distanceMeters == NULL
        || view->leftIR == NULL
        || view->rightIR == NULL) {
        return false;
    }
    for (uint32_t measurement = 0; measurement < view->measurementCount; ++measurement) {
        if (!isfinite(view->azimuthDegrees[measurement])
            || view->azimuthDegrees[measurement] < -180.0
            || view->azimuthDegrees[measurement] > 180.0
            || !isfinite(view->elevationDegrees[measurement])
            || view->elevationDegrees[measurement] < -90.0
            || view->elevationDegrees[measurement] > 90.0
            || !isfinite(view->distanceMeters[measurement])
            || view->distanceMeters[measurement] <= 0.0) {
            return false;
        }
    }
    return true;
}

static inline void N60BinauralUnitVector(
    double azimuthDegrees,
    double elevationDegrees,
    double * _Nonnull x,
    double * _Nonnull y,
    double * _Nonnull z
) {
    const double degreesToRadians = 3.14159265358979323846 / 180.0;
    const double azimuth = azimuthDegrees * degreesToRadians;
    const double elevation = elevationDegrees * degreesToRadians;
    const double cosElevation = cos(elevation);
    *x = cosElevation * cos(azimuth);
    *y = cosElevation * sin(azimuth);
    *z = sin(elevation);
}

/// Control-plane nearest-direction selection for a normalized SOFA HRIR view.
/// Direction dominates; distance is used only as a small tie-break term.
static inline int32_t N60SOFAFindNearestMeasurement(
    const N60SOFAHRTFNormalizedView * _Nonnull view,
    N60BinauralSourcePosition target
) {
    if (view == NULL || !N60SOFAHRTFNormalizedViewIsValid(view, UINT32_MAX)) return -1;
    double tx = 0.0, ty = 0.0, tz = 0.0;
    N60BinauralUnitVector(target.azimuthDegrees, target.elevationDegrees, &tx, &ty, &tz);
    double bestScore = -INFINITY;
    int32_t bestIndex = -1;
    for (uint32_t measurement = 0; measurement < view->measurementCount; ++measurement) {
        double mx = 0.0, my = 0.0, mz = 0.0;
        N60BinauralUnitVector(
            view->azimuthDegrees[measurement],
            view->elevationDegrees[measurement],
            &mx,
            &my,
            &mz
        );
        const double angularSimilarity = tx * mx + ty * my + tz * mz;
        const double distancePenalty = 0.001 * fabs(view->distanceMeters[measurement] - target.distanceMeters);
        const double score = angularSimilarity - distancePenalty;
        if (score > bestScore) {
            bestScore = score;
            bestIndex = (int32_t)measurement;
        }
    }
    return bestIndex;
}

#ifdef __cplusplus
}
#endif

#endif
