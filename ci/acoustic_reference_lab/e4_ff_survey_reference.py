#!/usr/bin/env python3
"""E4 S9b1: feed-forward survey reference lab.

Builds the production cores (C++20) with e4_ff_survey_probe.c, runs them at the
eight standard rates, and checks every printed number against independent
predictions from the written rules (N60Fxlms.h) and the plant formula
(ci/e4_fxlms_plant.h). The plant sits between the reference microphone (white
noise x, 0.1 RMS) and the error microphone: gain 0.5, a 1 ms delay rounded to
native frames, and an 800 Hz impulse-invariant one-pole,
    P(f) = 0.5 (1 - a) exp(-j w d) / (1 - a exp(-j w)),  a = exp(-2 pi 800 / fs).

- H: noiseless, the H1 transfer at each band equals P(f) (within 0.05 dB and
  0.5 deg; the residual is the window's self-overlap at the 1 ms lag).
- G: with independent white microphone noise of 0.02 RMS, the coherence is
  |P|^2 sx^2 / (|P|^2 sx^2 + sn^2): x and the noise are white at the native
  rate and pass the same decimator, so their densities keep that ratio. Each
  band is within four random errors (Bendat and Piersol, table 9.6, with
  segments / 2 independent averages), and the mean over the bands within
  three standard errors of the mean.
"""
import cmath
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RT = ROOT / "NotchSixty/Audio/Realtime"
PROBE = ROOT / "ci/acoustic_reference_lab/e4_ff_survey_probe.c"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
SX, SN = 0.1, 0.02


def require(ok, detail):
    if not ok:
        raise AssertionError("E4 feed-forward survey reference failed: " + detail)


def build_and_run():
    cxx, cc = shutil.which("clang++"), shutil.which("clang")
    require(cxx is not None and cc is not None, "clang not installed")
    with tempfile.TemporaryDirectory(prefix="n60-e4-ff-survey-") as work:
        objects = [Path(work) / "fxlms.o", Path(work) / "survey.o"]
        binary = Path(work) / "probe"
        steps = [
            [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-c", str(RT / "n60_fxlms.cpp"), "-o", str(objects[0])],
            [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-c", str(RT / "n60_ff_survey.cpp"), "-o", str(objects[1])],
            [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(RT), "-I" + str(ROOT / "ci"), str(PROBE), *map(str, objects),
             "-lc++", "-lm", "-o", str(binary)],
        ]
        for step in steps:
            run = subprocess.run(step, capture_output=True, text=True, timeout=180)
            require(run.returncode == 0, "build:\n" + run.stderr)
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=300)
        require(run.returncode == 0 and not run.stderr, "probe:\n" + run.stderr)
        return run.stdout.splitlines()


def plant(rate, hz):
    a = math.exp(-2 * math.pi * 800.0 / rate)
    d = round(0.001 * rate)
    w = 2 * math.pi * hz / rate
    return 0.5 * (1 - a) * cmath.exp(-1j * w * d) / (1 - a * cmath.exp(-1j * w))


def main():
    transfer, coherence, segments = {}, {}, {}
    for line in build_and_run():
        p = line.split()
        if p[0] == "H":
            transfer.setdefault(int(p[1]), []).append((float(p[2]), complex(float(p[3]), float(p[4]))))
        elif p[0] == "G":
            coherence.setdefault(int(p[1]), []).append((float(p[2]), float(p[3])))
        elif p[0] == "SEG":
            segments[int(p[1])] = int(p[2])
    require(all(len(transfer.get(r, [])) == 16 and len(coherence.get(r, [])) == 16 for r in RATES),
            "missing probe lines")

    worst_db = worst_deg = worst_g = worst_mean = 0.0
    for rate in RATES:
        for hz, h in transfer[rate]:
            want = plant(rate, hz)
            db = abs(20 * math.log10(abs(h) / abs(want)))
            deg = abs(math.degrees(cmath.phase(h / want)))
            worst_db, worst_deg = max(worst_db, db), max(worst_deg, deg)
            require(db < 0.05 and deg < 0.5, f"H {rate} Hz at {hz:.1f} Hz: {h:.5f}, expected {want:.5f}")
        nd = segments[rate] / 2
        errors, offsets = [], []
        for hz, g2 in coherence[rate]:
            s = abs(plant(rate, hz)) ** 2 * SX * SX
            want = s / (s + SN * SN)
            error = math.sqrt(2) * (1 - want) * math.sqrt(want) / math.sqrt(nd)
            errors.append(error)
            offsets.append(g2 - want)
            worst_g = max(worst_g, abs(g2 - want) / (4 * error))
            require(abs(g2 - want) < 4 * error,
                    f"G {rate} Hz at {hz:.1f} Hz: {g2:.4f}, expected {want:.4f} +/- {4 * error:.4f}")
        mean = sum(offsets) / len(offsets)
        bound = 3 * (sum(errors) / len(errors)) / math.sqrt(len(errors))
        worst_mean = max(worst_mean, abs(mean) / bound)
        require(abs(mean) < bound, f"G {rate} Hz: mean coherence offset {mean:.4f} beyond {bound:.4f}")
    print(f"E4 feed-forward survey reference: PASS at {len(RATES)} rates "
          f"(transfer within {worst_db:.3f} dB, {worst_deg:.2f} deg; coherence bands at "
          f"{worst_g:.2f} and mean at {worst_mean:.2f} of their bounds)")


if __name__ == "__main__":
    main()
