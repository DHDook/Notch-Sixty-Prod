// E20 S10 part 7: realtime function-effect attributes for the C bridge (the C twin of core/src/platform/rt.hpp).
//
// N60_RT_NONBLOCKING_C marks a callback the Core Audio thread calls. Where clang supports function effects it is
// __attribute__((nonblocking)), and -Wfunction-effects rejects a body that calls a function it cannot verify as
// non-blocking (an external function without the attribute). Elsewhere it expands to nothing.
// N60_RT_TRUST_BEGIN_C / N60_RT_TRUST_END_C bracket a call the compiler cannot verify but the design guarantees is
// realtime-safe (a legacy kernel entry point in another translation unit, a clock read). Every use names its reason.
#ifndef N60_REALTIME_ATTRIBUTES_H
#define N60_REALTIME_ATTRIBUTES_H

#if defined(__clang__) && defined(__has_attribute)
#if __has_attribute(nonblocking)
#define N60_RT_NONBLOCKING_C __attribute__((nonblocking))
#endif
#endif
#ifndef N60_RT_NONBLOCKING_C
#define N60_RT_NONBLOCKING_C
#endif

#if defined(__clang__)
#define N60_RT_TRUST_BEGIN_C _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wfunction-effects\"")
#define N60_RT_TRUST_END_C _Pragma("clang diagnostic pop")
#else
#define N60_RT_TRUST_BEGIN_C
#define N60_RT_TRUST_END_C
#endif

#endif
