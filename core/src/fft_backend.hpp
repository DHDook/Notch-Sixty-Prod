// FFT backends (E21 S3). One contract (fft.hpp, measure/offline_fft.hpp), two implementations chosen at build time:
//  - n60::fft::portable / n60::fft::offline::portable: the in-house radix-2 transforms (fft.cpp, measure/offline_fft.cpp).
//    Always compiled; the only backend on Linux and Windows.
//  - n60::fft::vdsp / n60::fft::offline::vdsp: vDSP (core/platform/apple/fft_vdsp.cpp). Compiled only when N60_FFT_VDSP is
//    defined (Xcode defines it; CMake defines it when N60_FFT_BACKEND is vdsp, the default on Apple).
// The public n60::fft::* and n60::fft::offline::* functions forward to one of them in the same translation units that hold
// the portable code, so engine code never reads a flag. Tests call the backend namespaces directly to compare them.
#ifndef N60_CORE_FFT_BACKEND_HPP
#define N60_CORE_FFT_BACKEND_HPP

#include "fft.hpp"
#include "measure/offline_fft.hpp"

#define N60_FFT_DECLARE_BACKEND(NS)                                                                                    \
    namespace NS {                                                                                                     \
    size_t planBytes(uint32_t n) N60_RT_NONBLOCKING;                                                                   \
    bool planInit(void *mem, uint32_t n);                                                                              \
    void forward(const void *plan, Complex *x) N60_RT_NONBLOCKING;                                                     \
    void inverse(const void *plan, Complex *x) N60_RT_NONBLOCKING;                                                     \
    size_t realPlanBytes(uint32_t n) N60_RT_NONBLOCKING;                                                               \
    bool realPlanInit(void *mem, uint32_t n);                                                                          \
    void forwardReal(const void *realPlan, float *x) N60_RT_NONBLOCKING;                                               \
    void inverseReal(const void *realPlan, float *x) N60_RT_NONBLOCKING;                                               \
    }

namespace n60::fft {
N60_FFT_DECLARE_BACKEND(portable)
#ifdef N60_FFT_VDSP
N60_FFT_DECLARE_BACKEND(vdsp)
#endif
}  // namespace n60::fft

#undef N60_FFT_DECLARE_BACKEND

namespace n60::fft::offline {
namespace portable {
bool realForward(const double *x, uint64_t n, std::vector<Cplx> &spectrum);
bool realInverse(const std::vector<Cplx> &spectrum, uint64_t n, std::vector<double> &x);
}  // namespace portable
#ifdef N60_FFT_VDSP
namespace vdsp {
bool realForward(const double *x, uint64_t n, std::vector<Cplx> &spectrum);
bool realInverse(const std::vector<Cplx> &spectrum, uint64_t n, std::vector<double> &x);
}  // namespace vdsp
#endif
}  // namespace n60::fft::offline

#endif
