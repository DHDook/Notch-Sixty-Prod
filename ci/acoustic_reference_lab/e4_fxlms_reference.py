#!/usr/bin/env python3
"""E4 S5: adaptive ANC (FxLMS) reference lab.

Builds the production core (C++20) with e4_fxlms_probe.c, runs it at the eight
standard rates, and checks every printed number against independent
predictions from the written rules (N60Fxlms.h) and the plant formula
(ci/e4_fxlms_plant.h):

- DEC: the decimation filter designed from the header's formula (Blackman
  windowed sinc, L = 16 D + 1, fc = 0.3 / D) has this gain at 150 and 500 Hz,
  and zero phase once its 8 D delay is removed.
- FIXED: with a path seed 0.8x and 30 deg off, the narrowband update's fixed
  point is W = -D / (S + lambda tau S_seed).
- PATH: the auxiliary-noise model converges to the plant's secondary path,
  including the one-buffer I/O delay.
- PROBE: the probe's RMS equals the configured -50 dBFS (RBJ Butterworth noise
  gain computed here from its impulse response).
"""
import cmath
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RT = ROOT / "NotchSixty/Audio/Realtime"
PROBE = ROOT / "ci/acoustic_reference_lab/e4_fxlms_probe.c"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
BUFFER = 256


def require(ok, detail):
    if not ok:
        raise AssertionError("E4 FxLMS reference failed: " + detail)


def build_and_run():
    cxx, cc = shutil.which("clang++"), shutil.which("clang")
    require(cxx is not None and cc is not None, "clang not installed")
    with tempfile.TemporaryDirectory(prefix="n60-e4-fxlms-") as work:
        obj, binary = Path(work) / "fxlms.o", Path(work) / "probe"
        steps = [
            [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-c", str(RT / "n60_fxlms.cpp"), "-o", str(obj)],
            [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-I" + str(ROOT / "ci"), str(PROBE), str(obj),
             "-lc++", "-lm", "-o", str(binary)],
        ]
        for step in steps:
            run = subprocess.run(step, capture_output=True, text=True, timeout=180)
            require(run.returncode == 0, "build:\n" + run.stderr)
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=300)
        require(run.returncode == 0 and not run.stderr, "probe:\n" + run.stderr)
        return run.stdout.splitlines()


def decimator_gain(rate, hz):
    d = int(rate // 4000)
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
    response = sum(h / total * cmath.exp(-1j * w * i) for i, h in enumerate(taps))
    return response * cmath.exp(1j * w * centre)


def plant_path(rate, hz):
    """S(f) of the shared plant: gain 0.5, 1 ms delay, 800 Hz one-pole, plus
    the one-buffer I/O delay."""
    a = math.exp(-2 * math.pi * 800.0 / rate)
    delay = round(0.001 * rate) + BUFFER
    w = 2 * math.pi * hz / rate
    return 0.5 * (1 - a) * cmath.exp(-1j * w * delay) / (1 - a * cmath.exp(-1j * w))


def probe_noise_gain(rate):
    """sqrt(sum h^2) of the RBJ low-pass (400 Hz, Q 1/sqrt 2) divided by the
    ENBW-based normalisation the core applies."""
    w0 = 2 * math.pi * 400.0 / rate
    alpha = math.sin(w0) / (2 * math.sqrt(0.5))
    a0 = 1 + alpha
    b0 = (1 - math.cos(w0)) / 2 / a0
    b1 = (1 - math.cos(w0)) / a0
    a1 = -2 * math.cos(w0) / a0
    a2 = (1 - alpha) / a0
    x1 = x2 = y1 = y2 = 0.0
    energy = 0.0
    for n in range(int(0.05 * rate)):
        x = 1.0 if n == 0 else 0.0
        y = b0 * x + b1 * x1 + b0 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x, y1, y
        energy += y * y
    enbw = 400.0 * (math.pi / 4) / math.sin(math.pi / 4)
    return math.sqrt(energy) / math.sqrt(2 * enbw / rate)


def main():
    seen = {"DEC": set(), "FIXED": set(), "PATH": set(), "PROBE": set()}
    for line in build_and_run():
        f = line.split()
        kind, rate = f[0], int(f[1])
        seen[kind].add(rate)
        if kind == "DEC":
            hz, got = float(f[2]), complex(float(f[3]), float(f[4]))
            want = decimator_gain(rate, hz)
            require(abs(want.imag) < 1e-9, "%d Hz: model filter not linear phase" % rate)
            require(abs(abs(got) - want.real) < 2e-5,
                    "%d Hz: decimator gain at %.0f Hz %.6f, model %.6f"
                    % (rate, hz, abs(got), want.real))
            require(abs(cmath.phase(got)) < 1e-4,
                    "%d Hz: decimator phase at %.0f Hz %.2e" % (rate, hz, cmath.phase(got)))
        elif kind == "FIXED":
            k, got = int(f[2]), complex(float(f[3]), float(f[4]))
            hz, amp, ph = ((60.0, 0.02, 0.7), (120.0, 0.015, -1.9))[k]
            s = plant_path(rate, hz)
            seed = s * 0.8 * cmath.exp(1j * math.pi / 6)
            want = -amp * cmath.exp(1j * ph) / (s + 0.5 * 0.25 * seed)
            require(abs(got - want) / abs(want) < 0.005,
                    "%d Hz tone %d: weight %s, fixed point %s" % (rate, k, got, want))
        elif kind == "PATH":
            got = complex(float(f[2]), float(f[3]))
            want = plant_path(rate, 60.0)
            ratio = got / want
            require(abs(20 * math.log10(abs(ratio))) < 0.5
                    and abs(math.degrees(cmath.phase(ratio))) < 3.0,
                    "%d Hz: path %.2f dB %.2f deg from the plant"
                    % (rate, 20 * math.log10(abs(ratio)), math.degrees(cmath.phase(ratio))))
        elif kind == "PROBE":
            got = float(f[2])
            want = 10 ** (-50 / 20) * probe_noise_gain(rate)
            require(abs(20 * math.log10(want / 10 ** (-50 / 20))) < 0.2,
                    "%d Hz: probe normalisation off by %.2f dB" % (rate, 20 * math.log10(want / 10 ** (-50 / 20))))
            require(abs(20 * math.log10(got / want)) < 0.3,
                    "%d Hz: probe RMS %.3f dBFS, model %.3f dBFS"
                    % (rate, 20 * math.log10(got), 20 * math.log10(want)))
    for kind, rates in seen.items():
        require(sorted(rates) == list(RATES), "probe did not report %s at every rate" % kind)
    print("E4 FxLMS reference: PASS at %d rates" % len(RATES))


if __name__ == "__main__":
    main()
