#ifndef N60HeadTracking_h
#define N60HeadTracking_h

#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#include "N60BinauralProfile.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_HEAD_POSE_COMPONENT_BITS 21u
#define N60_HEAD_POSE_COMPONENT_MASK ((uint64_t)((1u << N60_HEAD_POSE_COMPONENT_BITS) - 1u))
#define N60_HEAD_POSE_COMPONENT_SIGN (1u << (N60_HEAD_POSE_COMPONENT_BITS - 1u))
#define N60_HEAD_POSE_MILLIDEGREES_PER_DEGREE 1000.0

typedef struct {
    double yawDegrees;
    double pitchDegrees;
    double rollDegrees;
} N60HeadPose;

typedef struct {
    _Atomic uint64_t packedPose;
} N60HeadPoseAtomic;

typedef struct {
    uint32_t totalFrames;
    uint32_t frameCursor;
    bool active;
} N60SpatialCrossfade;

static inline double N60HeadPoseWrap180(double value) {
    while (value > 180.0) value -= 360.0;
    while (value < -180.0) value += 360.0;
    return value;
}

static inline bool N60HeadPoseIsValid(N60HeadPose pose) {
    return isfinite(pose.yawDegrees)
        && pose.yawDegrees >= -180.0
        && pose.yawDegrees <= 180.0
        && isfinite(pose.pitchDegrees)
        && pose.pitchDegrees >= -90.0
        && pose.pitchDegrees <= 90.0
        && isfinite(pose.rollDegrees)
        && pose.rollDegrees >= -180.0
        && pose.rollDegrees <= 180.0;
}

static inline uint64_t N60HeadPoseEncodeSigned21(int32_t value) {
    return ((uint64_t)(uint32_t)value) & N60_HEAD_POSE_COMPONENT_MASK;
}

static inline int32_t N60HeadPoseDecodeSigned21(uint64_t encoded) {
    uint32_t value = (uint32_t)(encoded & N60_HEAD_POSE_COMPONENT_MASK);
    if ((value & N60_HEAD_POSE_COMPONENT_SIGN) != 0u) {
        value |= (uint32_t)~((uint32_t)N60_HEAD_POSE_COMPONENT_MASK);
    }
    return (int32_t)value;
}

static inline bool N60HeadPosePack(N60HeadPose pose, uint64_t * _Nonnull packedOut) {
    if (packedOut == NULL || !N60HeadPoseIsValid(pose)) return false;
    const int32_t yaw = (int32_t)llround(pose.yawDegrees * N60_HEAD_POSE_MILLIDEGREES_PER_DEGREE);
    const int32_t pitch = (int32_t)llround(pose.pitchDegrees * N60_HEAD_POSE_MILLIDEGREES_PER_DEGREE);
    const int32_t roll = (int32_t)llround(pose.rollDegrees * N60_HEAD_POSE_MILLIDEGREES_PER_DEGREE);
    *packedOut = N60HeadPoseEncodeSigned21(yaw)
        | (N60HeadPoseEncodeSigned21(pitch) << 21u)
        | (N60HeadPoseEncodeSigned21(roll) << 42u);
    return true;
}

static inline N60HeadPose N60HeadPoseUnpack(uint64_t packed) {
    const int32_t yaw = N60HeadPoseDecodeSigned21(packed);
    const int32_t pitch = N60HeadPoseDecodeSigned21(packed >> 21u);
    const int32_t roll = N60HeadPoseDecodeSigned21(packed >> 42u);
    return (N60HeadPose){
        .yawDegrees = (double)yaw / N60_HEAD_POSE_MILLIDEGREES_PER_DEGREE,
        .pitchDegrees = (double)pitch / N60_HEAD_POSE_MILLIDEGREES_PER_DEGREE,
        .rollDegrees = (double)roll / N60_HEAD_POSE_MILLIDEGREES_PER_DEGREE,
    };
}

static inline void N60HeadPoseAtomicInitialize(
    N60HeadPoseAtomic * _Nonnull atomicPose,
    N60HeadPose initialPose
) {
    if (atomicPose == NULL) return;
    uint64_t packed = 0u;
    if (!N60HeadPosePack(initialPose, &packed)) packed = 0u;
    atomic_init(&atomicPose->packedPose, packed);
}

/// Control-plane capability check. Product integration must refuse live tracking
/// if the platform cannot provide a lock-free 64-bit atomic pose snapshot.
static inline bool N60HeadPoseAtomicIsLockFree(
    const N60HeadPoseAtomic * _Nonnull atomicPose
) {
    return atomicPose != NULL && atomic_is_lock_free(&atomicPose->packedPose);
}

static inline bool N60HeadPoseAtomicPublish(
    N60HeadPoseAtomic * _Nonnull atomicPose,
    N60HeadPose pose
) {
    if (atomicPose == NULL) return false;
    uint64_t packed = 0u;
    if (!N60HeadPosePack(pose, &packed)) return false;
    atomic_store_explicit(&atomicPose->packedPose, packed, memory_order_release);
    return true;
}

/// Realtime-safe coherent pose read: one atomic load, no retry loop, no locks.
static inline N60HeadPose N60HeadPoseAtomicLoad(
    const N60HeadPoseAtomic * _Nonnull atomicPose
) {
    if (atomicPose == NULL) return (N60HeadPose){0};
    const uint64_t packed = atomic_load_explicit(&atomicPose->packedPose, memory_order_acquire);
    return N60HeadPoseUnpack(packed);
}

static inline double N60HeadPoseAngularDeltaDegrees(N60HeadPose lhs, N60HeadPose rhs) {
    const double yaw = fabs(N60HeadPoseWrap180(lhs.yawDegrees - rhs.yawDegrees));
    const double pitch = fabs(lhs.pitchDegrees - rhs.pitchDegrees);
    const double roll = fabs(N60HeadPoseWrap180(lhs.rollDegrees - rhs.rollDegrees));
    return fmax(yaw, fmax(pitch, roll));
}

typedef struct {
    double w;
    double x;
    double y;
    double z;
} N60HeadQuaternion;

static inline N60HeadQuaternion N60HeadQuaternionForPose(N60HeadPose pose) {
    const double degreesToRadians = 3.14159265358979323846 / 180.0;
    const double halfYaw = pose.yawDegrees * degreesToRadians * 0.5;
    const double halfPitch = pose.pitchDegrees * degreesToRadians * 0.5;
    const double halfRoll = pose.rollDegrees * degreesToRadians * 0.5;
    const double cy = cos(halfYaw), sy = sin(halfYaw);
    const double cp = cos(halfPitch), sp = sin(halfPitch);
    const double cr = cos(halfRoll), sr = sin(halfRoll);
    return (N60HeadQuaternion){
        .w = cr * cp * cy + sr * sp * sy,
        .x = sr * cp * cy - cr * sp * sy,
        .y = cr * sp * cy + sr * cp * sy,
        .z = cr * cp * sy - sr * sp * cy,
    };
}

static inline void N60HeadQuaternionRotateWorldToHead(
    N60HeadQuaternion q,
    double worldX,
    double worldY,
    double worldZ,
    double * _Nonnull headX,
    double * _Nonnull headY,
    double * _Nonnull headZ
) {
    // R(q)^T * world: inverse rotation of a unit quaternion.
    const double xx = q.x * q.x, yy = q.y * q.y, zz = q.z * q.z;
    const double xy = q.x * q.y, xz = q.x * q.z, yz = q.y * q.z;
    const double wx = q.w * q.x, wy = q.w * q.y, wz = q.w * q.z;
    *headX = (1.0 - 2.0 * (yy + zz)) * worldX
        + 2.0 * (xy + wz) * worldY
        + 2.0 * (xz - wy) * worldZ;
    *headY = 2.0 * (xy - wz) * worldX
        + (1.0 - 2.0 * (xx + zz)) * worldY
        + 2.0 * (yz + wx) * worldZ;
    *headZ = 2.0 * (xz + wy) * worldX
        + 2.0 * (yz - wx) * worldY
        + (1.0 - 2.0 * (xx + yy)) * worldZ;
}

/// Control-plane scene transform. Trigonometry and HRTF lookup remain outside
/// the realtime callback; the result is prepared into an inactive PR57 renderer.
static inline bool N60BinauralProfileDescriptorApplyHeadPose(
    const N60BinauralProfileDescriptor * _Nonnull worldDescriptor,
    N60HeadPose pose,
    N60BinauralProfileDescriptor * _Nonnull headRelativeOut
) {
    if (worldDescriptor == NULL
        || headRelativeOut == NULL
        || !N60HeadPoseIsValid(pose)
        || !N60BinauralProfileDescriptorIsValid(worldDescriptor, UINT32_MAX)) {
        return false;
    }
    N60BinauralProfileDescriptor result = *worldDescriptor;
    const N60HeadQuaternion quaternion = N60HeadQuaternionForPose(pose);
    const double radiansToDegrees = 180.0 / 3.14159265358979323846;
    for (uint32_t channel = 0; channel < result.programLayout.channelCount; ++channel) {
        if (result.lfeMode == N60BinauralLFEModeEqualEar
            && result.programLayout.channels[channel] == N60ProgramChannelRoleLowFrequencyEffects) {
            continue;
        }
        double worldX = 0.0, worldY = 0.0, worldZ = 0.0;
        N60BinauralUnitVector(
            worldDescriptor->sources[channel].azimuthDegrees,
            worldDescriptor->sources[channel].elevationDegrees,
            &worldX,
            &worldY,
            &worldZ
        );
        double headX = 0.0, headY = 0.0, headZ = 0.0;
        N60HeadQuaternionRotateWorldToHead(
            quaternion, worldX, worldY, worldZ, &headX, &headY, &headZ
        );
        const double length = sqrt(headX * headX + headY * headY + headZ * headZ);
        if (!isfinite(length) || length <= 1.0e-12) return false;
        headX /= length;
        headY /= length;
        headZ /= length;
        result.sources[channel].azimuthDegrees = atan2(headY, headX) * radiansToDegrees;
        result.sources[channel].elevationDegrees = asin(fmax(-1.0, fmin(1.0, headZ))) * radiansToDegrees;
    }
    *headRelativeOut = result;
    return true;
}

static inline bool N60SpatialCrossfadeStart(
    N60SpatialCrossfade * _Nonnull crossfade,
    uint32_t totalFrames
) {
    if (crossfade == NULL || totalFrames == 0u) return false;
    crossfade->totalFrames = totalFrames;
    crossfade->frameCursor = 0u;
    crossfade->active = true;
    return true;
}

static inline float N60SpatialCrossfadeWeight(const N60SpatialCrossfade * _Nonnull crossfade) {
    if (crossfade == NULL || !crossfade->active || crossfade->totalFrames == 0u) return 1.0f;
    const float x = fminf(1.0f, (float)crossfade->frameCursor / (float)crossfade->totalFrames);
    return x * x * (3.0f - 2.0f * x);
}

/// Realtime-safe crossfade between two already-rendered generations. No kernel
/// preparation, lookup, trigonometry or allocation occurs here.
static inline void N60SpatialCrossfadeProcessStereo(
    N60SpatialCrossfade * _Nonnull crossfade,
    float oldLeft,
    float oldRight,
    float newLeft,
    float newRight,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
) {
    if (outputLeft == NULL || outputRight == NULL) return;
    if (crossfade == NULL || !crossfade->active) {
        *outputLeft = newLeft;
        *outputRight = newRight;
        return;
    }
    const float weight = N60SpatialCrossfadeWeight(crossfade);
    *outputLeft = oldLeft + (newLeft - oldLeft) * weight;
    *outputRight = oldRight + (newRight - oldRight) * weight;
    crossfade->frameCursor += 1u;
    if (crossfade->frameCursor >= crossfade->totalFrames) {
        crossfade->frameCursor = crossfade->totalFrames;
        crossfade->active = false;
        *outputLeft = newLeft;
        *outputRight = newRight;
    }
}

#ifdef __cplusplus
}
#endif

#endif
