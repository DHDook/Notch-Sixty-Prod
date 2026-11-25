#!/usr/bin/env python3
"""E13 S12 (G29): the generic HRTF at the eight standard rates against an independent model.

Builds the production core's hrtf.cpp (C++20) with e13_generic_hrtf_probe.cpp and checks every printed number against a
separate implementation of the published model (rigid sphere radius 0.0875 m, ears at +-100 degrees, c = 343 m/s):

- DELAY: Woodworth arrival delay per ear, plus the guard frames and the group delay at DC of the Brown-Duda head-shadow
  filter (1 + alpha s T)/(1 + s T), discretised by the bilinear transform at the rate, within 0.15 sample.
- LEVEL: magnitude at 500 Hz, 2 kHz and 8 kHz equals that filter's discrete response within 0.6 dB.
- ITD: the interaural delay of a source at 90 degrees right equals the closed form (a/c)(170 degrees - 90 degrees + cos 10 degrees)
  within 0.2 sample (the shadow's own delay differs between the ears and is included).
No measured third-party data is used.
"""
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
A, C, GUARD = 0.0875, 343.0, 8
EAR_AZ = (-100.0, 100.0)  # left, right


def require(ok, detail):
    if not ok:
        raise AssertionError("E13 generic HRTF reference failed: " + detail)


def unit(az, el):
    a, e = math.radians(az), math.radians(el)
    return (math.sin(a) * math.cos(e), math.cos(a) * math.cos(e), math.sin(e))


def psi(az, el, ear):
    s, v = unit(az, el), unit(EAR_AZ[ear], 0.0)
    return math.acos(max(-1.0, min(1.0, sum(x * y for x, y in zip(s, v)))))


def delay_s(p):
    ac = A / C
    return ac + (-ac * math.cos(p) if p < math.pi / 2 else ac * (p - math.pi / 2))


def alpha(p):
    return 1.05 + 0.95 * math.cos(math.degrees(p) * math.pi / 150.0)


def shadow(rate, al, f):
    """Bilinear-discretised (1 + al s T)/(1 + s T) at frequency f."""
    t = A / (2 * C)
    z1 = complex(math.cos(-2 * math.pi * f / rate), math.sin(-2 * math.pi * f / rate))
    s = 2 * rate * (1 - z1) / (1 + z1)
    return (1 + al * s * t) / (1 + s * t)


def dc_group_delay(rate, al):
    """Group delay in samples of the discretised shadow filter as f -> 0 (numerical phase derivative)."""
    f = 1.0
    h1, h2 = shadow(rate, al, f), shadow(rate, al, 2 * f)
    d = (math.atan2(h1.imag, h1.real) - math.atan2(h2.imag, h2.real)) / (2 * math.pi * f) * rate
    return d


def build_and_run():
    cxx = shutil.which("clang++")
    require(cxx is not None, "clang++ not installed")
    with tempfile.TemporaryDirectory(prefix="n60-e13-hrtf-") as work:
        binary = Path(work) / "probe"
        cmd = [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror", "-fno-exceptions", "-fno-rtti",
               "-I" + str(ROOT / "core/include"), "-I" + str(ROOT / "core/src"),
               str(ROOT / "ci/acoustic_reference_lab/e13_generic_hrtf_probe.cpp"), str(ROOT / "core/src/hrtf.cpp"), "-o", str(binary)]
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        require(run.returncode == 0, "build:\n" + run.stderr[-2000:])
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=600)
        require(run.returncode == 0, "probe exit %d" % run.returncode)
        return run.stdout.splitlines()


def main():
    rows = {}
    for line in build_and_run():
        f = line.split()
        if f and f[0] == "HRTF":
            rows[(int(float(f[1])), float(f[2]), float(f[3]), int(f[4]))] = (int(f[5]), float(f[6]), [float(x) for x in f[7:]])
    require(len(rows) == 8 * 10 * 2, "expected 160 rows, got %d" % len(rows))
    worst_delay = worst_level = 0.0
    for (rate, az, el, ear), (taps, centroid, mags) in sorted(rows.items()):
        p = psi(az, el, ear)
        expect = delay_s(p) * rate + GUARD + dc_group_delay(rate, alpha(p))
        worst_delay = max(worst_delay, abs(centroid - expect))
        require(abs(centroid - expect) <= 0.15, "%d Hz az %g el %g ear %d: delay %.3f vs %.3f samples" % (rate, az, el, ear, centroid, expect))
        for f, got in zip((500.0, 2000.0, 8000.0), mags):
            want = 20 * math.log10(abs(shadow(rate, alpha(p), f)))
            worst_level = max(worst_level, abs(got - want))
            require(abs(got - want) <= 0.6, "%d Hz az %g el %g ear %d: %g Hz %.3f vs %.3f dB" % (rate, az, el, ear, f, got, want))
    for rate in RATES:
        l, r = rows[(rate, 90.0, 0.0, 0)], rows[(rate, 90.0, 0.0, 1)]
        shadow_l = dc_group_delay(rate, alpha(psi(90, 0, 0)))
        shadow_r = dc_group_delay(rate, alpha(psi(90, 0, 1)))
        itd = (l[1] - shadow_l) - (r[1] - shadow_r)
        closed = (A / C) * (math.radians(170) - math.pi / 2 + math.cos(math.radians(10))) * rate
        require(abs(itd - closed) <= 0.2, "%d Hz: ITD %.3f vs closed form %.3f samples" % (rate, itd, closed))
    print("E13 generic HRTF reference: PASS at %d rates (worst delay error %.3f samples, worst level error %.3f dB)" % (
        len(RATES), worst_delay, worst_level))


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
