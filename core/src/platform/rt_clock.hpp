// E20 S2: a clock read the realtime thread may call. steady_clock::now is a bounded read of the monotonic counter
// (mach_absolute_time, clock_gettime on the vDSO): no lock, no allocation, no wait. The standard library does not
// annotate it, so this wrapper vouches for it once, for the load meter and the profile build.
#pragma once

#include <chrono>

#include "rt.hpp"

namespace n60 {

inline std::chrono::steady_clock::time_point rtNow() N60_RT_NONBLOCKING {
    N60_RT_TRUST_BEGIN
    return std::chrono::steady_clock::now();
    N60_RT_TRUST_END
}

}  // namespace n60
