// E21 S8: in-house dense linear algebra for the design maths (design note 7). Header only, no dependency.
//
// Real and complex double (T = double or std::complex<double>). Row-major storage, raw pointers, so the callers keep
// their own std::vector storage. Off-thread design maths only: nothing here may run on an audio callback. Solvers
// never throw, never use threads and sum in a fixed order, so results are bit-identical between runs and platforms
// with IEEE double. cholesky and svdJacobi do not allocate; qrLeastSquares sizes a few small work vectors.
//
// cholesky            Hermitian positive definite A = L L^H (lower triangle in place).
// qrLeastSquares      Householder QR with column pivoting, minimum-residual basic solution of rank r.
// svdJacobi           one-sided Jacobi (Hestenes) SVD, high relative accuracy; singular values sorted descending.
// svdSolve            pseudo-inverse solve from the SVD with a relative cut-off.
//
// References: Golub and Van Loan, "Matrix Computations", 4th ed., 4.2 (Cholesky), 5.4.1 (QR with column pivoting),
// 8.6.3 (one-sided Jacobi); Demmel and Veselic, "Jacobi's method is more accurate than QR", SIAM J. Matrix Anal.
// Appl. 13(4), 1992.
#ifndef N60_LINALG_HPP
#define N60_LINALG_HPP

#include <cmath>
#include <complex>
#include <cstddef>
#include <vector>

namespace n60 {
namespace linalg {

using Cx = std::complex<double>;

inline double re(double v) { return v; }
inline double re(const Cx &v) { return v.real(); }
inline double conj(double v) { return v; }
inline Cx conj(const Cx &v) { return std::conj(v); }
inline double abs2(double v) { return v * v; }
inline double abs2(const Cx &v) { return std::norm(v); }
inline double mag(double v) { return std::fabs(v); }
inline double mag(const Cx &v) { return std::abs(v); }

// In-place Cholesky of a Hermitian positive-definite n x n matrix (only the lower triangle is read and written; the
// diagonal becomes real). Returns false when a pivot is not strictly positive (not positive definite).
template <typename T>
bool cholesky(T *a, int n) {
    for (int j = 0; j < n; ++j) {
        double d = re(a[j * n + j]);
        for (int k = 0; k < j; ++k) d -= abs2(a[j * n + k]);
        if (!(d > 0.0)) return false;
        const double ljj = std::sqrt(d);
        a[j * n + j] = T(ljj);
        for (int i = j + 1; i < n; ++i) {
            T s = a[i * n + j];
            for (int k = 0; k < j; ++k) s -= a[i * n + k] * conj(a[j * n + k]);
            a[i * n + j] = s / ljj;
        }
    }
    return true;
}

// Solves A x = b in place in b, from the factor that cholesky() left in l.
template <typename T>
void choleskySolve(const T *l, int n, T *b) {
    for (int i = 0; i < n; ++i) {
        T s = b[i];
        for (int k = 0; k < i; ++k) s -= l[i * n + k] * b[k];
        b[i] = s / re(l[i * n + i]);
    }
    for (int i = n - 1; i >= 0; --i) {
        T s = b[i];
        for (int k = i + 1; k < n; ++k) s -= conj(l[k * n + i]) * b[k];
        b[i] = s / re(l[i * n + i]);
    }
}

// Least squares min |A x - b| for an m x n matrix (any shape) by Householder QR with column pivoting. `a` (m x n,
// row-major) and `b` (m) are overwritten. The numerical rank r counts the leading diagonal entries of R with
// |R_kk| > rcond * |R_00|; the basic solution has zeros outside the r pivot columns. Returns r (0 for a zero
// matrix). `x` has n entries.
template <typename T>
int qrLeastSquares(T *a, int m, int n, T *b, T *x, double rcond) {
    const int kmax = m < n ? m : n;
    std::vector<int> perm(static_cast<size_t>(n));
    for (int j = 0; j < n; ++j) perm[static_cast<size_t>(j)] = j;
    for (int j = 0; j < n; ++j) x[j] = T(0);
    int rank = 0;
    double r00 = 0.0;
    std::vector<T> v(static_cast<size_t>(m));
    for (int k = 0; k < kmax; ++k) {
        // Pivot: the remaining column with the largest norm (the first wins a tie).
        int best = k;
        double bestNorm = -1.0;
        for (int j = k; j < n; ++j) {
            double s = 0.0;
            for (int i = k; i < m; ++i) s += abs2(a[i * n + j]);
            if (s > bestNorm) { bestNorm = s; best = j; }
        }
        if (best != k) {
            for (int i = 0; i < m; ++i) { const T t = a[i * n + k]; a[i * n + k] = a[i * n + best]; a[i * n + best] = t; }
            const int t = perm[static_cast<size_t>(k)];
            perm[static_cast<size_t>(k)] = perm[static_cast<size_t>(best)];
            perm[static_cast<size_t>(best)] = t;
        }
        const double nrm = std::sqrt(bestNorm);
        if (k == 0) r00 = nrm;
        if (!(nrm > 0.0) || !(nrm > rcond * r00)) break;
        rank = k + 1;
        // Reflector H = I - 2 v v^H / (v^H v) with H x = alpha e1, alpha = -phase(x0) |x|.
        const T x0 = a[k * n + k];
        const double m0 = mag(x0);
        const T phase = m0 > 0.0 ? T(x0 / m0) : T(1);
        const T alpha = -phase * nrm;
        v[0] = x0 - alpha;
        for (int i = k + 1; i < m; ++i) v[static_cast<size_t>(i - k)] = a[i * n + k];
        double vv = 0.0;
        for (int i = 0; i < m - k; ++i) vv += abs2(v[static_cast<size_t>(i)]);
        if (vv > 0.0) {
            for (int j = k + 1; j < n; ++j) {
                T dot(0);
                for (int i = k; i < m; ++i) dot += conj(v[static_cast<size_t>(i - k)]) * a[i * n + j];
                const T f = dot * (2.0 / vv);
                for (int i = k; i < m; ++i) a[i * n + j] -= v[static_cast<size_t>(i - k)] * f;
            }
            T dot(0);
            for (int i = k; i < m; ++i) dot += conj(v[static_cast<size_t>(i - k)]) * b[i];
            const T f = dot * (2.0 / vv);
            for (int i = k; i < m; ++i) b[i] -= v[static_cast<size_t>(i - k)] * f;
        }
        a[k * n + k] = alpha;
        for (int i = k + 1; i < m; ++i) a[i * n + k] = T(0);
    }
    // Back substitution on the leading rank x rank block of R.
    std::vector<T> y(static_cast<size_t>(rank));
    for (int i = rank - 1; i >= 0; --i) {
        T s = b[i];
        for (int j = i + 1; j < rank; ++j) s -= a[i * n + j] * y[static_cast<size_t>(j)];
        y[static_cast<size_t>(i)] = s / a[i * n + i];
    }
    for (int i = 0; i < rank; ++i) x[perm[static_cast<size_t>(i)]] = y[static_cast<size_t>(i)];
    return rank;
}

// One-sided Jacobi SVD of an m x n matrix with m >= n: A = U diag(sigma) V^H. On return `a` holds U (m x n, columns
// orthonormal where sigma > 0), `sigma` (n) is sorted descending, `v` (n x n) holds V. Returns the number of sweeps
// used, or -1 if it did not converge in maxSweeps (the factors are still the best so far).
template <typename T>
int svdJacobi(T *a, int m, int n, double *sigma, T *v, int maxSweeps = 60) {
    for (int i = 0; i < n; ++i)
        for (int j = 0; j < n; ++j) v[i * n + j] = i == j ? T(1) : T(0);
    const double eps = 1.0e-15;
    int sweeps = 0;
    bool rotated = true;
    while (rotated && sweeps < maxSweeps) {
        rotated = false;
        ++sweeps;
        for (int p = 0; p < n - 1; ++p) {
            for (int q = p + 1; q < n; ++q) {
                double alpha = 0.0, beta = 0.0;
                T gamma(0);
                for (int i = 0; i < m; ++i) {
                    alpha += abs2(a[i * n + p]);
                    beta += abs2(a[i * n + q]);
                    gamma += conj(a[i * n + p]) * a[i * n + q];
                }
                const double g = mag(gamma);
                if (!(g > eps * std::sqrt(alpha * beta)) || !(g > 0.0)) continue;
                rotated = true;
                // Make the coupling real by rotating the phase of column q, then a plane rotation.
                const T ec = conj(T(gamma / g));
                const double zeta = (beta - alpha) / (2.0 * g);
                const double t = (zeta >= 0.0 ? 1.0 : -1.0) / (std::fabs(zeta) + std::sqrt(1.0 + zeta * zeta));
                const double c = 1.0 / std::sqrt(1.0 + t * t);
                const double s = c * t;
                for (int i = 0; i < m; ++i) {
                    const T ap = a[i * n + p], aq = a[i * n + q] * ec;
                    a[i * n + p] = c * ap - s * aq;
                    a[i * n + q] = s * ap + c * aq;
                }
                for (int i = 0; i < n; ++i) {
                    const T vp = v[i * n + p], vq = v[i * n + q] * ec;
                    v[i * n + p] = c * vp - s * vq;
                    v[i * n + q] = s * vp + c * vq;
                }
            }
        }
    }
    for (int j = 0; j < n; ++j) {
        double s = 0.0;
        for (int i = 0; i < m; ++i) s += abs2(a[i * n + j]);
        sigma[j] = std::sqrt(s);
    }
    // Selection sort, descending, stable for ties (deterministic).
    for (int j = 0; j < n - 1; ++j) {
        int best = j;
        for (int k = j + 1; k < n; ++k) if (sigma[k] > sigma[best]) best = k;
        if (best == j) continue;
        const double ts = sigma[j]; sigma[j] = sigma[best]; sigma[best] = ts;
        for (int i = 0; i < m; ++i) { const T t = a[i * n + j]; a[i * n + j] = a[i * n + best]; a[i * n + best] = t; }
        for (int i = 0; i < n; ++i) { const T t = v[i * n + j]; v[i * n + j] = v[i * n + best]; v[i * n + best] = t; }
    }
    for (int j = 0; j < n; ++j) {
        if (!(sigma[j] > 0.0)) continue;
        for (int i = 0; i < m; ++i) a[i * n + j] /= sigma[j];
    }
    return rotated ? -1 : sweeps;
}

// Minimum-norm least squares x = V diag(1/sigma) U^H b from svdJacobi() factors, dropping sigma <= rcond * sigma_0.
// Returns the rank used. `x` has n entries.
template <typename T>
int svdSolve(const T *u, const double *sigma, const T *v, int m, int n, const T *b, T *x, double rcond) {
    int rank = 0;
    for (int j = 0; j < n; ++j) x[j] = T(0);
    for (int j = 0; j < n; ++j) {
        if (!(sigma[j] > rcond * sigma[0]) || !(sigma[j] > 0.0)) break;
        ++rank;
        T proj(0);
        for (int i = 0; i < m; ++i) proj += conj(u[i * n + j]) * b[i];
        proj /= sigma[j];
        for (int i = 0; i < n; ++i) x[i] += v[i * n + j] * proj;
    }
    return rank;
}

}  // namespace linalg
}  // namespace n60

#endif
