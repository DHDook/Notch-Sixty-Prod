// Offline double-precision FFT for the measurement core (E11 S1, design note 2).
//
// Control or worker thread only; allocates freely and is never called from an audio
// callback. Real-input transforms of any power-of-two size from 2 to 2^24. The realtime
// FFT in fft.hpp is untouched.
#ifndef N60_MEASURE_OFFLINE_FFT_HPP
#define N60_MEASURE_OFFLINE_FFT_HPP

#include <cstddef>
#include <cstdint>
#include <vector>

namespace n60::fft::offline {

struct Cplx {
    double re;
    double im;
};

constexpr uint64_t kMaxSize = 1ull << 24;

bool validSize(uint64_t n);

// Real forward transform of n real samples (zero padded by the caller to n): writes n/2+1
// bins. Unnormalised: X[k] = sum x[j] exp(-2 pi i jk / n). Returns false on a bad size or
// allocation failure.
bool realForward(const double *x, uint64_t n, std::vector<Cplx> &spectrum);

// Inverse of realForward, scaled by 1/n so realInverse(realForward(x)) == x.
bool realInverse(const std::vector<Cplx> &spectrum, uint64_t n, std::vector<double> &x);

}  // namespace n60::fft::offline

#endif
