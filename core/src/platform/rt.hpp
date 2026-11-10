// E20 S2: realtime function attributes.
//
// N60_RT_NONBLOCKING marks a function that the audio thread calls: it must not allocate, lock, or call anything
// that can. Where the compiler supports clang function effects it is [[clang::nonblocking]], and
// -Wfunction-effects (an error in the core build) rejects a body that calls an unannotated external function.
// Elsewhere it expands to nothing. Place it after the parameter list: `void f(int) N60_RT_NONBLOCKING;`. It includes noexcept, which clang requires with the attribute.
#pragma once

#if defined(__clang__) && defined(__has_cpp_attribute)
#if __has_cpp_attribute(clang::nonblocking)
#define N60_RT_NONBLOCKING noexcept [[clang::nonblocking]]
#endif
#endif
#ifndef N60_RT_NONBLOCKING
#define N60_RT_NONBLOCKING
#endif

// Marks a call the compiler cannot verify but the design guarantees is realtime-safe (a host callback documented to
// obey the realtime rules, a clock read, a C entry point in another translation unit). Every use names its reason.
#if defined(__clang__)
#define N60_RT_TRUST_BEGIN _Pragma("clang diagnostic push") _Pragma("clang diagnostic ignored \"-Wfunction-effects\"")
#define N60_RT_TRUST_END _Pragma("clang diagnostic pop")
#else
#define N60_RT_TRUST_BEGIN
#define N60_RT_TRUST_END
#endif
