#!/usr/bin/env python3
"""E33 S27 (G52): the linear-phase EQ at its four lengths and the eight standard rates.

Builds the production core (C++20) with e33_eq_linear_length_probe.cpp and checks every printed number against an
independent RBJ-cookbook peaking model of a narrow bass cut (40 Hz, -9 dB, Q 3):

- DELAY: the peak tap sits exactly at half the length, and the tap count is 2 L + 1 (261121 at 384 kHz and 340 ms, inside
  the 262144-tap limit).
- ACCURACY: the largest error over the probe frequencies falls as the length grows; the 340 ms design is within 0.75 dB of the
  model at every rate, and the 21 ms design visibly cannot follow a 13 Hz-wide band (more than 1 dB).
- The core's reported error (sampled every 1/48 octave) is within 0.35 dB of the largest error seen at the probe frequencies.
"""
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
LENGTHS = (21, 85, 170, 340)
FREQS = (20.0, 30.0, 40.0, 50.0, 70.0, 150.0, 1000.0, 8000.0)
BAND = (40.0, -9.0, 3.0)
MAX_TAPS = 262144


def require(ok, detail):
    if not ok:
        raise AssertionError("E33 EQ linear length reference failed: " + detail)


def f32(x):
    return struct.unpack('f', struct.pack('f', x))[0]


def peaking_db(rate, band, f):
    centre, gain, q = band
    a = 10 ** (gain / 40)
    w0 = 2 * math.pi * centre / rate
    alpha = math.sin(w0) / (2 * q)
    cw = math.cos(w0)
    b = (1 + alpha * a, -2 * cw, 1 - alpha * a)
    den = (1 + alpha / a, -2 * cw, 1 - alpha / a)
    # The engine runs float32 coefficients (a0 = 1). At 384 kHz a 40 Hz pole pair sits at radius 1 - 3e-4, so float32 rounding
    # of a1 and a2 alone moves the 40 Hz gain by about 1.9 dB; the FIR matches what the engine's biquad does, so the model uses
    # the same rounded coefficients.
    b = tuple(f32(x / den[0]) for x in b)
    den = (1.0, f32(den[1] / den[0]), f32(den[2] / den[0]))
    w = 2 * math.pi * f / rate
    z = [complex(math.cos(-k * w), math.sin(-k * w)) for k in range(3)]
    return 20 * math.log10(abs(sum(b[k] * z[k] for k in range(3)) / sum(den[k] * z[k] for k in range(3))))


def core_sources():
    import re
    text = (ROOT / "core/sources.cmake").read_text()
    block = text[text.index("set(N60_CORE_SOURCES"):]
    block = block[:block.index(")")]
    return re.findall(r"src/([A-Za-z0-9_/]+)\.cpp", block)


def build_and_run():
    cxx = shutil.which("clang++")
    require(cxx is not None, "clang++ not installed")
    sources = [ROOT / "core" / "src" / (name + ".cpp") for name in core_sources()]
    with tempfile.TemporaryDirectory(prefix="n60-e33-linlen-") as work:
        binary = Path(work) / "probe"
        cmd = [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror", "-fno-exceptions", "-fno-rtti",
               "-I" + str(ROOT / "core/include"), "-I" + str(ROOT / "core/src"),
               str(ROOT / "ci/acoustic_reference_lab/e33_eq_linear_length_probe.cpp")] + [str(s) for s in sources] + ["-o", str(binary)]
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        require(run.returncode == 0, "build:\n" + run.stderr[-2000:])
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=900)
        require(run.returncode == 0, "probe exit %d" % run.returncode)
        return run.stdout.splitlines()


def main():
    rows = {}
    for line in build_and_run():
        f = line.split()
        if f and f[0] == "LEN":
            rows[(int(float(f[1])), int(float(f[2])))] = (int(f[3]), int(f[4]), float(f[5]), [float(x) for x in f[6:]])
    for rate in RATES:
        previous = 1e9
        for ms in LENGTHS:
            require((rate, ms) in rows, "missing %d Hz %d ms" % (rate, ms))
            taps, peak, reported, mags = rows[(rate, ms)]
            require(taps == 2 * peak + 1, "%d Hz %d ms: %d taps, peak tap at %d" % (rate, ms, taps, peak))
            require(taps <= MAX_TAPS, "%d Hz %d ms: %d taps exceeds the limit" % (rate, ms, taps))
            err = max(abs(m - peaking_db(rate, BAND, f)) for f, m in zip(FREQS, mags))
            require(reported + 0.35 >= err, "%d Hz %d ms: reported %.3f below seen %.3f" % (rate, ms, reported, err))
            require(err <= previous + 0.05, "%d Hz %d ms: error %.3f grew from %.3f" % (rate, ms, err, previous))
            previous = err
            if ms == 21:
                require(err > 1.0, "%d Hz: 21 ms followed a 13 Hz band to %.3f dB" % (rate, err))
            if ms == 340:
                require(err <= 0.75, "%d Hz 340 ms: %.3f dB from the model" % (rate, err))
                if rate == 384000:
                    require(taps == 261121, "384 kHz 340 ms taps %d" % taps)
        print("E33 linear length %6d Hz: error %s dB at 21, 85, 170, 340 ms" % (
            rate, ", ".join("%.2f" % max(abs(m - peaking_db(rate, BAND, f)) for f, m in zip(FREQS, rows[(rate, ms)][3])) for ms in LENGTHS)))
    print("E33 EQ linear length reference: PASS at %d rates" % len(RATES))


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
