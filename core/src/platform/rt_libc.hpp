// E20 S2: libc and libm calls the render path is allowed to make under clang function effects.
//
// Clang cannot see inside the C library, so -Wfunction-effects rejects every call to it from a nonblocking function.
// The functions below are pure arithmetic or bounded memory moves (no allocation, no locks, no I/O); redeclaring them
// nonblocking states that. Include after <cmath> and <cstring>. Anything that can block (malloc, printf, pthread)
// stays unlisted on purpose, so the compiler still rejects it.
#pragma once

#include <cmath>
#include <cstring>

#include "rt.hpp"

#if defined(__clang__) && defined(__has_cpp_attribute)
#if __has_cpp_attribute(clang::nonblocking)
extern "C" {
double sin(double) [[clang::nonblocking]];
double cos(double) [[clang::nonblocking]];
double tan(double) [[clang::nonblocking]];
double exp(double) [[clang::nonblocking]];
double log(double) [[clang::nonblocking]];
double log10(double) [[clang::nonblocking]];
double pow(double, double) [[clang::nonblocking]];
double sqrt(double) [[clang::nonblocking]];
double atan2(double, double) [[clang::nonblocking]];
double tanh(double) [[clang::nonblocking]];
double fmod(double, double) [[clang::nonblocking]];
float sinf(float) [[clang::nonblocking]];
float cosf(float) [[clang::nonblocking]];
float expf(float) [[clang::nonblocking]];
float logf(float) [[clang::nonblocking]];
float powf(float, float) [[clang::nonblocking]];
float sqrtf(float) [[clang::nonblocking]];
float tanhf(float) [[clang::nonblocking]];
}
#endif
#endif
