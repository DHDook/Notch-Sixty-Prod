#!/usr/bin/env python3
"""E4 S9a: feed-forward shadow canceller reference lab.

Builds the production cores (C++20) with e4_ff_shadow_probe.c, runs them at the
eight standard rates, and checks every printed number against independent
predictions from the written rules (N60Fxlms.h):

- BAND: a cosine on the error microphone reaches the error meter through the
  decimator (Blackman windowed sinc, L = 16 D + 1, fc = 0.3 / D) and the band
  filter (two RBJ second-order Butterworth high-passes at 20 Hz, two RBJ
  low-passes at 200 Hz, all at fd), so the meter reads
  |H_dec(f)|^2 |H_hp(f)|^4 |H_lp(f)|^4 of the cosine's power.
- FIXED: with both path estimates 0.5 z^-8, a disturbance 0.5 x delayed by 20
  decimated samples and a zero seed, the two channels see identical inputs and
  stay equal, and 0.5 W_L + 0.5 W_R must equal -0.5 z^-12 in band. So each
  channel's response at 60 Hz is -0.5 exp(-j 2 pi 60 * 12 / fd).
"""
import cmath
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RT = ROOT / "NotchSixty/Audio/Realtime"
PROBE = ROOT / "ci/acoustic_reference_lab/e4_ff_shadow_probe.c"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)


def require(ok, detail):
    if not ok:
        raise AssertionError("E4 feed-forward shadow reference failed: " + detail)


def build_and_run():
    cxx, cc = shutil.which("clang++"), shutil.which("clang")
    require(cxx is not None and cc is not None, "clang not installed")
    with tempfile.TemporaryDirectory(prefix="n60-e4-ff-shadow-") as work:
        objects = [Path(work) / "fxlms.o", Path(work) / "shadow.o"]
        binary = Path(work) / "probe"
        steps = [
            [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-c", str(RT / "n60_fxlms.cpp"), "-o", str(objects[0])],
            [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-c", str(RT / "n60_ff_shadow.cpp"), "-o", str(objects[1])],
            [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), str(PROBE), *map(str, objects),
             "-lc++", "-lm", "-o", str(binary)],
        ]
        for step in steps:
            run = subprocess.run(step, capture_output=True, text=True, timeout=180)
            require(run.returncode == 0, "build:\n" + run.stderr)
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=300)
        require(run.returncode == 0 and not run.stderr, "probe:\n" + run.stderr)
        return run.stdout.splitlines()


def decimation(rate):
    d = int(rate // 4000)
    return d, rate / d


def decimator_gain(rate, hz):
    d, _ = decimation(rate)
    length = 16 * d + 1
    fc = 0.3 / d
    centre = (length - 1) / 2
    taps = []
    for i in range(length):
        t = i - centre
        x = 2 * math.pi * fc * t
        sinc = 1.0 if t == 0 else math.sin(x) / x
        w = (0.42 - 0.5 * math.cos(2 * math.pi * i / (length - 1))
             + 0.08 * math.cos(4 * math.pi * i / (length - 1)))
        taps.append(2 * fc * sinc * w)
    total = sum(taps)
    w = 2 * math.pi * hz / rate
    return abs(sum(h / total * cmath.exp(-1j * w * i) for i, h in enumerate(taps)))


def rbj(kind, corner, fd, hz):
    """|H| of the RBJ cookbook second-order Butterworth (Q = 1 / sqrt 2)."""
    w0 = 2 * math.pi * corner / fd
    alpha = math.sin(w0) / (2 * math.sqrt(0.5))
    c = math.cos(w0)
    if kind == "lp":
        b = ((1 - c) / 2, 1 - c, (1 - c) / 2)
    else:
        b = ((1 + c) / 2, -(1 + c), (1 + c) / 2)
    a = (1 + alpha, -2 * c, 1 - alpha)
    z = cmath.exp(-1j * 2 * math.pi * hz / fd)
    return abs((b[0] + b[1] * z + b[2] * z * z) / (a[0] + a[1] * z + a[2] * z * z))


def main():
    lines = build_and_run()
    band = {}
    fixed = {}
    for line in lines:
        parts = line.split()
        if parts[0] == "BAND":
            band[(int(parts[1]), int(parts[2]))] = float(parts[3])
        elif parts[0] == "FIXED":
            fixed[(int(parts[1]), int(parts[2]))] = complex(float(parts[3]), float(parts[4]))
    require(len(band) == 3 * len(RATES) and len(fixed) == 2 * len(RATES), "missing probe lines")

    worst_band = 0.0
    worst_mag = worst_phase = 0.0
    for rate in RATES:
        _, fd = decimation(rate)
        for hz in (15, 60, 300):
            gain = (decimator_gain(rate, hz) * rbj("hp", 20.0, fd, hz) ** 2
                    * rbj("lp", 200.0, fd, hz) ** 2)
            expected = 20 * math.log10(gain)
            error = abs(band[(rate, hz)] - expected)
            worst_band = max(worst_band, error)
            require(error < 0.1, f"BAND {rate} Hz at {hz} Hz: {band[(rate, hz)]:.3f} dB, "
                                 f"expected {expected:.3f} dB")
        target = -0.5 * cmath.exp(-1j * 2 * math.pi * 60.0 * 12 / fd)
        for ch in (0, 1):
            w = fixed[(rate, ch)]
            mag = abs(20 * math.log10(abs(w) / abs(target)))
            phase = abs(math.degrees(cmath.phase(w / target)))
            worst_mag, worst_phase = max(worst_mag, mag), max(worst_phase, phase)
            require(mag < 0.05 and phase < 0.5,
                    f"FIXED {rate} Hz ch {ch}: {w:.5f}, expected {target:.5f}")
        require(abs(fixed[(rate, 0)] - fixed[(rate, 1)]) < 1e-6,
                f"FIXED {rate} Hz: channels differ ({fixed[(rate, 0)]} vs {fixed[(rate, 1)]})")
    print(f"E4 feed-forward shadow reference: PASS at {len(RATES)} rates "
          f"(band within {worst_band:.3f} dB; fixed point within {worst_mag:.3f} dB, "
          f"{worst_phase:.2f} deg)")


if __name__ == "__main__":
    main()
