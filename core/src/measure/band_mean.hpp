// Mean power over a frequency band of a power spectrum, by prefix sums (E11 S3/S4).
// Offline measurement analysis only.
#ifndef N60_MEASURE_BAND_MEAN_HPP
#define N60_MEASURE_BAND_MEAN_HPP

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace n60::measure {

struct BandMean {
    std::vector<double> prefix;  // prefix[k] = sum of power[0..k)
    double binHz = 0;
    explicit BandMean(const std::vector<double> &power, double hzPerBin) : prefix(power.size() + 1, 0.0), binHz(hzPerBin) {
        for (size_t k = 0; k < power.size(); ++k) prefix[k + 1] = prefix[k] + power[k];
    }
    double mean(double lo, double hi, double centre) const {
        const int64_t last = static_cast<int64_t>(prefix.size()) - 2;
        int64_t a = static_cast<int64_t>(std::ceil(lo / binHz));
        int64_t b = static_cast<int64_t>(std::floor(hi / binHz));
        a = std::max<int64_t>(a, 1);
        b = std::min<int64_t>(b, last);
        if (b < a) {
            const int64_t k = std::min<int64_t>(std::max<int64_t>(static_cast<int64_t>(std::llround(centre / binHz)), 1), last);
            return prefix[k + 1] - prefix[k];
        }
        return (prefix[b + 1] - prefix[a]) / static_cast<double>(b - a + 1);
    }
};

}  // namespace n60::measure

#endif
