#!/usr/bin/env python3
"""E4 S18a: remote tonal worker core reference lab.

Builds the production core (C++20) with e4_remote_tonal_probe.c, runs it at the
eight standard rates on a static one-tone plant, and checks the converged
weight against the closed form of the modified FxLMS rule written in
N60RemoteTonal.h (Bjarnason 1995; Kuo and Morgan 1996, sec. 4.5):

    e_v = M - Shat (Gbar - W),  W <- (1 - lambda dt) W - a e_v / Shat,
    a = 1 - exp(-dt / tau),     M = D + S Gbar.

With Shat = S and no dither Gbar = W, so the fixed point of the recursion is
    W = -a D / (lambda dt S + a S) = -D / (S (1 + lambda dt / a)),
which is -D / S without leakage. dt is the 250 ms block and tau is 0.5 s.
"""
import cmath
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RT = ROOT / "NotchSixty/Audio/Realtime"
PROBE = ROOT / "ci/acoustic_reference_lab/e4_remote_tonal_probe.c"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
D = 0.01 * cmath.exp(0.7j)
S = 0.8 * cmath.exp(-0.4j)
DT, TAU = 0.25, 0.5


def require(ok, detail):
    if not ok:
        raise AssertionError("E4 remote tonal reference failed: " + detail)


def build_and_run():
    cxx, cc = shutil.which("clang++"), shutil.which("clang")
    require(cxx is not None and cc is not None, "clang not installed")
    with tempfile.TemporaryDirectory(prefix="n60-e4-remote-tonal-") as work:
        obj = Path(work) / "remote.o"
        binary = Path(work) / "probe"
        steps = [
            [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror", "-include", "stddef.h",
             "-I" + str(RT), "-c", str(RT / "n60_remote_tonal.cpp"), "-o", str(obj)],
            [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-include", "stddef.h",
             "-I" + str(RT), str(PROBE), str(obj), "-lc++", "-lm", "-o", str(binary)],
        ]
        for step in steps:
            run = subprocess.run(step, capture_output=True, text=True, timeout=180)
            require(run.returncode == 0, "build:\n" + run.stderr)
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=300)
        require(run.returncode == 0 and not run.stderr, "probe:\n" + run.stderr)
        return run.stdout.splitlines()


def main():
    lines = build_and_run()
    seen = 0
    for line in lines:
        parts = line.split()
        require(parts[0] == "FIXED" and len(parts) == 5, "unexpected line: " + line)
        rate, leak = float(parts[1]), float(parts[2])
        got = complex(float(parts[3]), float(parts[4]))
        a = 1.0 - math.exp(-DT / TAU)
        want = -D / (S * (1.0 + leak * DT / a))
        err = abs(got - want) / abs(want)
        require(err < 2e-3, f"{rate:.0f} Hz leak {leak}: got {got}, want {want} (error {err:.2e})")
        seen += 1
    require(seen == 2 * len(RATES), f"expected {2 * len(RATES)} results, got {seen}")
    print(f"e4_remote_tonal_reference: ok ({seen} cases)")


if __name__ == "__main__":
    main()
