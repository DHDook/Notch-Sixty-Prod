#!/usr/bin/env python3
"""E4 S4: ANC howl-guard reference lab.

Builds the production guard (C++20) with e4_anc_guard_probe.c, runs it at the
eight standard rates, and checks every printed number against an independent
model of the written rules (N60AncGuard.h, docs/ANC_QUALIFICATION.md s3):

- GROWTH: block mean squares of the same synthetic tone, the 6 dB / 20 ms
  rule over three blocks, and the 50 ms trip target.
- RAMP: an RBJ band-pass of the boxcar-decimated error confirms band 6 is
  above its baseline in each of the first three blocks, so the trip falls at
  the end of block 3; the mute ramp is linear to zero over 10 ms.
"""
from array import array
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RT = ROOT / "NotchSixty/Audio/Realtime"
PROBE = ROOT / "ci/acoustic_reference_lab/e4_anc_guard_probe.c"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
TRIP_GROWTH, TRIP_ERROR = 1, 2
TOLERANCE = 2e-6


def require(ok, detail):
    if not ok:
        raise AssertionError("E4 ANC guard reference failed: " + detail)


def build_and_run():
    cxx, cc = shutil.which("clang++"), shutil.which("clang")
    require(cxx is not None and cc is not None, "clang not installed")
    with tempfile.TemporaryDirectory(prefix="n60-e4-guard-") as work:
        obj, binary = Path(work) / "guard.o", Path(work) / "probe"
        steps = [
            [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-c", str(RT / "n60_anc_guard.cpp"), "-o", str(obj)],
            [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), str(PROBE), str(obj), "-lc++", "-lm", "-o", str(binary)],
        ]
        for step in steps:
            run = subprocess.run(step, capture_output=True, text=True, timeout=180)
            require(run.returncode == 0, "build:\n" + run.stderr)
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=180)
        require(run.returncode == 0 and not run.stderr, "probe:\n" + run.stderr)
        return run.stdout.splitlines()


def block_frames(rate):
    return int(math.floor(rate * 0.010 + 0.5))


def expected_growth_trip(rate):
    onset = int(0.2 * rate)
    frames = int(0.4 * rate)
    tone = array("f", (
        10 ** (min(-50.0 + (0.0 if i < onset else 500.0 * (i / rate - 0.2)), -10.0) / 20)
        * math.sin(2 * math.pi * 60.0 * i / rate)
        for i in range(frames)))
    block = block_frames(rate)
    floor, ratio = 10 ** -6.0, 10 ** 0.6
    history, run = [], 0
    for n in range(frames // block):
        ms = sum(x * x for x in tone[n * block:(n + 1) * block]) / block
        if len(history) >= 2:
            growing = ms > floor and ms / max(history[-2], floor) > ratio
            run = run + 1 if growing else 0
            if run >= 3:
                return onset, (n + 1) * block
        history.append(ms)
    return onset, None


def band_six_above_baseline_each_block(rate):
    decimation = max(1, int(rate / 4000.0))
    fd = rate / decimation
    centre = 20.0 * (500.0 / 20.0) ** (6 / 15)
    w0 = 2 * math.pi * centre / fd
    alpha = math.sin(w0) / (2 * 4.3)
    a0 = 1 + alpha
    b0, b2, a1, a2 = alpha / a0, -alpha / a0, -2 * math.cos(w0) / a0, (1 - alpha) / a0
    block = block_frames(rate)
    err = array("f", (0.3 * math.sin(2 * math.pi * centre * i / rate)
                      for i in range(3 * block)))
    threshold = 10 ** (-40 / 10) * 10 ** (6 / 10)
    x1 = x2 = y1 = y2 = 0.0
    acc, count, sums, counts = 0.0, 0, [0.0] * 3, [0] * 3
    for i, e in enumerate(err):
        acc += e
        count += 1
        if count == decimation:
            x = acc / decimation
            y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2, x1, y2, y1 = x1, x, y1, y
            sums[i // block] += y * y
            counts[i // block] += 1
            acc, count = 0.0, 0
    return all(c > 0 and s / c > threshold for s, c in zip(sums, counts))


def main():
    lines = build_and_run()
    growth = {}
    ramps = {}
    for line in lines:
        f = line.split()
        if f[0] == "GROWTH":
            growth[int(f[1])] = (int(f[2]), int(f[3]), int(f[4]))
        elif f[0] == "RAMP":
            ramps.setdefault(int(f[1]), []).append((int(f[2]), int(f[3]), float(f[4])))
    require(sorted(growth) == list(RATES) and sorted(ramps) == list(RATES),
            "probe did not report every rate")

    for rate in RATES:
        onset, trip, reason = growth[rate]
        want_onset, want_trip = expected_growth_trip(rate)
        require(reason == TRIP_GROWTH, "%d Hz growth reason %d" % (rate, reason))
        require(onset == want_onset and trip == want_trip,
                "%d Hz growth trip %d, model %s" % (rate, trip, want_trip))
        require((trip - onset) / rate <= 0.050,
                "%d Hz growth trip %.1f ms after onset" % (rate, (trip - onset) * 1e3 / rate))

        require(band_six_above_baseline_each_block(rate),
                "%d Hz model: band 6 below threshold in an early block" % rate)
        length = int(math.floor(rate * 0.010 + 0.5))
        for start, k, value in ramps[rate]:
            require(start == 3 * block_frames(rate),
                    "%d Hz error trip at %d, want %d" % (rate, start, 3 * block_frames(rate)))
            want = 0.1 * max(0.0, 1.0 - (k + 1) / length)
            require(abs(value - want) <= TOLERANCE,
                    "%d Hz ramp[%d] %.9g, want %.9g" % (rate, k, value, want))
        print("E4 guard %6d Hz: growth trip +%.1f ms, ramp %d frames" %
              (rate, (trip - onset) * 1e3 / rate, length))
    print("E4 ANC guard reference: PASS at %d rates" % len(RATES))


if __name__ == "__main__":
    main()
