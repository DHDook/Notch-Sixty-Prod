#include "N60Dynamics.h"
#include "N60DynamicEQ.h"

#if defined(__clang__) || defined(__GNUC__)
typedef void (*N60DynamicsProcessFn)(
    N60DynamicsRuntime *,
    const N60DynamicsSnapshot *,
    float *,
    float *
);

typedef void (*N60DynamicsProcessWithMasterFn)(
    N60DynamicsRuntime *,
    const N60DynamicsSnapshot *,
    float,
    float *,
    float *
);

typedef void (*N60DynamicEQProcessFn)(
    N60DynamicEQRuntime *,
    const N60DynamicEQSnapshot *,
    float *,
    float *
);

_Static_assert(
    __builtin_types_compatible_p(__typeof__(&N60DynamicsProcessPreEQStereoFrame), N60DynamicsProcessFn),
    "pre-EQ dynamics must consume a const snapshot pointer"
);
_Static_assert(
    __builtin_types_compatible_p(__typeof__(&N60DynamicsProcessDynamicEQStereoFrame), N60DynamicsProcessFn),
    "Dynamic EQ stage must consume a const dynamics snapshot pointer"
);
_Static_assert(
    __builtin_types_compatible_p(__typeof__(&N60DynamicsProcessCoreStereoFrame), N60DynamicsProcessFn),
    "core dynamics must consume a const snapshot pointer"
);
_Static_assert(
    __builtin_types_compatible_p(__typeof__(&N60DynamicsProcessCoreStereoFrameWithMasterGain), N60DynamicsProcessWithMasterFn),
    "core dynamics/master-gain stage must consume a const snapshot pointer"
);
_Static_assert(
    __builtin_types_compatible_p(__typeof__(&N60DynamicsProcessPauseGateStereoFrame), N60DynamicsProcessFn),
    "pause gate must consume a const snapshot pointer"
);
_Static_assert(
    __builtin_types_compatible_p(__typeof__(&N60DynamicsProcessStereoFrame), N60DynamicsProcessFn),
    "combined dynamics entry point must consume a const snapshot pointer"
);
_Static_assert(
    __builtin_types_compatible_p(__typeof__(&N60DynamicEQProcessStereoFrame), N60DynamicEQProcessFn),
    "Dynamic EQ must consume a const snapshot pointer"
);
#endif

int main(void) {
    return 0;
}
