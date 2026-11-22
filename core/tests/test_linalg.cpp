// E21 S8: dense solvers (core/src/linalg/linalg.hpp) against closed-form systems and ill-conditioned cases
// (condition 1e8), real and complex double. Orthogonal factors are built from Givens rotations, independent of the
// code under test, so the singular values and solutions are known by construction.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <type_traits>
#include <vector>

#include "linalg/linalg.hpp"

using namespace n60::linalg;

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

struct Rng {
    uint32_t s = 12345;
    double next() { s = s * 1664525u + 1013904223u; return double(s >> 8) / 8388608.0 - 1.0; }
};

template <typename T> static T make(double a, double b);
template <> double make<double>(double a, double) { return a; }
template <> Cx make<Cx>(double a, double b) { return Cx(a, b); }

// Unitary n x n from random Givens rotations and phases.
template <typename T>
static std::vector<T> unitary(int n, Rng &rng) {
    std::vector<T> q(size_t(n) * n, T(0));
    for (int i = 0; i < n; ++i) q[size_t(i) * n + i] = T(1);
    for (int sweep = 0; sweep < 3; ++sweep)
        for (int p = 0; p < n - 1; ++p)
            for (int r = p + 1; r < n; ++r) {
                const double th = rng.next() * 3.14159265358979, c = std::cos(th), s = std::sin(th);
                const T ph = std::is_same<T, Cx>::value ? make<T>(std::cos(rng.next() * 3.14), std::sin(rng.next() * 3.14)) : T(1);
                const T phn = ph / mag(ph);
                for (int k = 0; k < n; ++k) {
                    const T a = q[size_t(p) * n + k], b = q[size_t(r) * n + k] * phn;
                    q[size_t(p) * n + k] = c * a - s * b;
                    q[size_t(r) * n + k] = s * a + c * b;
                }
            }
    return q;
}

template <typename T>
static std::vector<T> matmul(const std::vector<T> &a, const std::vector<T> &b, int m, int k, int n) {
    std::vector<T> c(size_t(m) * n, T(0));
    for (int i = 0; i < m; ++i)
        for (int j = 0; j < n; ++j) {
            T s(0);
            for (int l = 0; l < k; ++l) s += a[size_t(i) * k + l] * b[size_t(l) * n + j];
            c[size_t(i) * n + j] = s;
        }
    return c;
}

template <typename T>
static std::vector<T> adjoint(const std::vector<T> &a, int m, int n) {
    std::vector<T> t(size_t(n) * m);
    for (int i = 0; i < m; ++i) for (int j = 0; j < n; ++j) t[size_t(j) * m + i] = conj(a[size_t(i) * n + j]);
    return t;
}

// A = Q1 diag(s) Q2^H with logarithmically spaced singular values from 1 down to 1/cond.
template <typename T>
static std::vector<T> illConditioned(int n, double cond, Rng &rng, std::vector<double> &sig) {
    std::vector<T> q1 = unitary<T>(n, rng), q2 = unitary<T>(n, rng);
    sig.resize(static_cast<size_t>(n));
    for (int i = 0; i < n; ++i) sig[size_t(i)] = std::pow(cond, -double(i) / double(n - 1));
    for (int i = 0; i < n; ++i) for (int j = 0; j < n; ++j) q1[size_t(i) * n + j] *= sig[size_t(j)];
    return matmul(q1, adjoint(q2, n, n), n, n, n);
}

template <typename T>
static double relErr(const std::vector<T> &x, const std::vector<T> &ref) {
    double e = 0, r = 0;
    for (size_t i = 0; i < x.size(); ++i) { e += abs2(x[i] - ref[i]); r += abs2(ref[i]); }
    return std::sqrt(e / r);
}

template <typename T>
static std::vector<T> randomVec(int n, Rng &rng) {
    std::vector<T> v(static_cast<size_t>(n));
    for (auto &e : v) e = make<T>(rng.next(), rng.next());
    return v;
}

static void testClosedForm() {
    // [4 2; 2 3] x = [10; 8] has x = [1.75; 1.5] ... checked as A x = b to the rounding of the closed form.
    double a[4] = {4, 2, 2, 3}, b[2] = {10, 8};
    CHECK(cholesky(a, 2), "cholesky 2x2");
    choleskySolve(a, 2, b);
    CHECK(std::fabs(b[0] - 1.75) < 1e-14 && std::fabs(b[1] - 1.5) < 1e-14, "cholesky closed form %.17g %.17g", b[0], b[1]);
    double neg[4] = {1, 2, 2, 1};
    CHECK(!cholesky(neg, 2), "indefinite matrix is refused");
    // Hermitian [2 i; -i 2], b = [3; 1]: det 3, x = [2 -i/... ] verified by substitution.
    Cx h[4] = {Cx(2, 0), Cx(0, 1), Cx(0, -1), Cx(2, 0)}, hb[2] = {Cx(3, 0), Cx(1, 0)};
    const Cx h0[4] = {Cx(2, 0), Cx(0, 1), Cx(0, -1), Cx(2, 0)};
    CHECK(cholesky(h, 2), "complex cholesky");
    choleskySolve(h, 2, hb);
    for (int i = 0; i < 2; ++i) {
        Cx r = h0[i * 2] * hb[0] + h0[i * 2 + 1] * hb[1];
        CHECK(std::abs(r - Cx(i == 0 ? 3 : 1, 0)) < 1e-14, "complex cholesky residual");
    }
    // Line fit through (1,1), (2,2), (3,2): slope 1/2, intercept 2/3.
    double m3[6] = {1, 1, 2, 1, 3, 1}, y[3] = {1, 2, 2}, x[2];
    CHECK(qrLeastSquares(m3, 3, 2, y, x, 1e-12) == 2, "line fit rank");
    CHECK(std::fabs(x[0] - 0.5) < 1e-14 && std::fabs(x[1] - 2.0 / 3.0) < 1e-14, "line fit %.17g %.17g", x[0], x[1]);
    // SVD of diag(3, 4) rotated: singular values 4, 3.
    double d[4] = {0, 3, 4, 0}, sg[2], v[4];
    CHECK(svdJacobi(d, 2, 2, sg, v) > 0, "svd converged");
    CHECK(std::fabs(sg[0] - 4) < 1e-14 && std::fabs(sg[1] - 3) < 1e-14, "svd closed form %.17g %.17g", sg[0], sg[1]);
}

template <typename T>
static void testIllConditioned(const char *name) {
    const int n = 12;
    Rng rng;
    std::vector<double> sig;
    const std::vector<T> A = illConditioned<T>(n, 1e8, rng, sig);
    const std::vector<T> xTrue = randomVec<T>(n, rng);
    const std::vector<T> b = matmul(A, xTrue, n, n, 1);

    // QR with column pivoting. Error in x is bounded by cond * eps (about 2e-8); allow 1e-6.
    std::vector<T> qa = A, qb = b, qx(static_cast<size_t>(n));
    CHECK(qrLeastSquares(qa.data(), n, n, qb.data(), qx.data(), 1e-14) == n, "%s qr rank", name);
    CHECK(relErr(qx, xTrue) < 1e-6, "%s qr error %.3g", name, relErr(qx, xTrue));

    // Jacobi SVD: singular values to high relative accuracy even for the smallest (1e-8), and the solve.
    std::vector<T> ua = A, V(static_cast<size_t>(n) * n);
    std::vector<double> s(static_cast<size_t>(n));
    CHECK(svdJacobi(ua.data(), n, n, s.data(), V.data()) > 0, "%s svd converged", name);
    for (int i = 0; i < n; ++i) CHECK(std::fabs(s[size_t(i)] - sig[size_t(i)]) < 1e-13, "%s sigma %d: %.17g vs %.17g", name, i, s[size_t(i)], sig[size_t(i)]);
    std::vector<T> sx(static_cast<size_t>(n));
    CHECK(svdSolve(ua.data(), s.data(), V.data(), n, n, b.data(), sx.data(), 1e-14) == n, "%s svd rank", name);
    CHECK(relErr(sx, xTrue) < 1e-6, "%s svd error %.3g", name, relErr(sx, xTrue));
    // U and V are unitary: V^H V = I.
    const std::vector<T> vv = matmul(adjoint(V, n, n), V, n, n, n);
    double dev = 0;
    for (int i = 0; i < n; ++i) for (int j = 0; j < n; ++j) dev = std::max(dev, mag(vv[size_t(i) * n + j] - (i == j ? T(1) : T(0))));
    CHECK(dev < 1e-13, "%s V orthogonality %.3g", name, dev);

    // Cholesky of a Hermitian positive-definite matrix with condition 1e8: H = A A^H has eigenvalues 1 .. 1e-16, so
    // build H = Q diag(1 .. 1e-8) Q^H instead.
    std::vector<T> q = unitary<T>(n, rng), qd = q;
    for (int i = 0; i < n; ++i) for (int j = 0; j < n; ++j) qd[size_t(i) * n + j] *= sig[size_t(j)];
    std::vector<T> H = matmul(qd, adjoint(q, n, n), n, n, n);
    for (int i = 0; i < n; ++i) for (int j = 0; j < i; ++j) { H[size_t(j) * n + i] = conj(H[size_t(i) * n + j]); }
    for (int i = 0; i < n; ++i) H[size_t(i) * n + i] = re(H[size_t(i) * n + i]);
    const std::vector<T> hb = matmul(H, xTrue, n, n, 1);
    std::vector<T> L = H, hx = hb;
    CHECK(cholesky(L.data(), n), "%s cholesky ill-conditioned", name);
    choleskySolve(L.data(), n, hx.data());
    CHECK(relErr(hx, xTrue) < 1e-6, "%s cholesky error %.3g", name, relErr(hx, xTrue));
}

static void testRankDeficientAndShapes() {
    // Rank 2 of 3 columns (column 2 = column 0 + column 1), 5 rows: a consistent system, residual ~ 0.
    const int m = 5, n = 3;
    Rng rng;
    std::vector<double> A(size_t(m) * n);
    for (int i = 0; i < m; ++i) { A[size_t(i) * n] = rng.next(); A[size_t(i) * n + 1] = rng.next(); A[size_t(i) * n + 2] = A[size_t(i) * n] + A[size_t(i) * n + 1]; }
    const double xs[3] = {0.7, -1.3, 0.0};
    std::vector<double> b(m), a2 = A, b2, x(n), u = A, v(n * n), sg(n), sx(n);
    for (int i = 0; i < m; ++i) b[size_t(i)] = A[size_t(i) * n] * xs[0] + A[size_t(i) * n + 1] * xs[1];
    b2 = b;
    CHECK(qrLeastSquares(a2.data(), m, n, b2.data(), x.data(), 1e-10) == 2, "qr detects rank 2");
    for (int i = 0; i < m; ++i) {
        double r = -b[size_t(i)];
        for (int j = 0; j < n; ++j) r += A[size_t(i) * n + j] * x[size_t(j)];
        CHECK(std::fabs(r) < 1e-13, "rank deficient residual %.3g", r);
    }
    CHECK(svdJacobi(u.data(), m, n, sg.data(), v.data()) > 0, "svd of rank-deficient");
    CHECK(sg[2] < 1e-14 * sg[0], "third singular value %.3g", sg[2]);
    CHECK(svdSolve(u.data(), sg.data(), v.data(), m, n, b.data(), sx.data(), 1e-10) == 2, "svd rank 2");
    // The SVD solution is the minimum-norm one: its norm is at most the QR basic solution's.
    double nq = 0, ns = 0;
    for (int j = 0; j < n; ++j) { nq += x[size_t(j)] * x[size_t(j)]; ns += sx[size_t(j)] * sx[size_t(j)]; }
    CHECK(ns <= nq + 1e-12, "minimum norm %.6g vs %.6g", ns, nq);
    // Zero matrix: rank 0, solution zero.
    double z[4] = {0, 0, 0, 0}, zb[2] = {1, 1}, zx[2] = {5, 5};
    CHECK(qrLeastSquares(z, 2, 2, zb, zx, 1e-12) == 0 && zx[0] == 0.0 && zx[1] == 0.0, "zero matrix");
}

static void testDeterminism() {
    Rng r1, r2;
    std::vector<double> s1, s2;
    auto A1 = illConditioned<Cx>(8, 1e6, r1, s1), A2 = illConditioned<Cx>(8, 1e6, r2, s2);
    std::vector<Cx> V1(64), V2(64);
    std::vector<double> g1(8), g2(8);
    svdJacobi(A1.data(), 8, 8, g1.data(), V1.data());
    svdJacobi(A2.data(), 8, 8, g2.data(), V2.data());
    CHECK(g1 == g2 && A1 == A2 && V1 == V2, "SVD is bit-identical between runs");
}

int main() {
    testClosedForm();
    testIllConditioned<double>("real");
    testIllConditioned<Cx>("complex");
    testRankDeficientAndShapes();
    testDeterminism();
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("linalg tests passed");
    return 0;
}
