#!/usr/bin/env python3
"""E33 S20 part 3 (G77): per-speaker-group EQ on a 5.1 session, linear phase, at the eight standard rates.

Builds the production core (C++20) and the linear-phase designer with e33_eq_groups_probe.cpp, then checks every
printed number against an independent RBJ-cookbook model:

- ALIGNMENT: every lane (centre with its own FIR, the others on the session FIR, the LFE on the alignment delta)
  peaks at the same frame, so a group list never skews the speakers against each other.
- REACH: the centre's magnitude is the session curve plus its group curve at the probe frequencies; the other
  covered lanes follow the session curve only; the LFE is flat.
"""
import math
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
FREQS = (150.0, 250.0, 800.0, 3000.0, 8000.0)
SESSION = (250.0, 3.0, 1.0)
GROUP = (800.0, -6.0, 1.4)
TOLERANCE_DB = 0.25
CENTRE, LFE = 2, 3


def require(ok, detail):
    if not ok:
        raise AssertionError("E33 EQ groups reference failed: " + detail)


def peaking_db(rate, band, f):
    centre, gain, q = band
    a = 10 ** (gain / 40)
    w0 = 2 * math.pi * centre / rate
    alpha = math.sin(w0) / (2 * q)
    cw = math.cos(w0)
    b = (1 + alpha * a, -2 * cw, 1 - alpha * a)
    den = (1 + alpha / a, -2 * cw, 1 - alpha / a)
    w = 2 * math.pi * f / rate
    z = [complex(math.cos(-k * w), math.sin(-k * w)) for k in range(3)]
    num = sum(b[k] * z[k] for k in range(3))
    dd = sum(den[k] * z[k] for k in range(3))
    return 20 * math.log10(abs(num / dd))


def build_and_run():
    cxx = shutil.which("clang++")
    require(cxx is not None, "clang++ not installed")
    sources = [ROOT / "core" / "src" / (name + ".cpp") for name in core_sources()]
    with tempfile.TemporaryDirectory(prefix="n60-e33-groups-") as work:
        binary = Path(work) / "probe"
        design_obj = Path(work) / "design.o"
        cc = shutil.which("clang")
        require(cc is not None, "clang not installed")
        run = subprocess.run([cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-I" + str(ROOT / "NotchSixty/Audio/Realtime"),
                              "-I" + str(ROOT / "core/include"), "-c",
                              str(ROOT / "ci/acoustic_reference_lab/e33_eq_groups_design.c"), "-o", str(design_obj)],
                             capture_output=True, text=True, timeout=300)
        require(run.returncode == 0, "design build:\n" + run.stderr[-2000:])
        cmd = [cxx, "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror", "-fno-exceptions", "-fno-rtti",
               "-I" + str(ROOT / "core/include"), "-I" + str(ROOT / "core/src"),
               str(ROOT / "ci/acoustic_reference_lab/e33_eq_groups_probe.cpp"), str(design_obj)] + [str(s) for s in sources] + ["-o", str(binary)]
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
        require(run.returncode == 0, "build:\n" + run.stderr[-2000:])
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=600)
        require(run.returncode == 0, "probe exit %d" % run.returncode)
        return run.stdout.splitlines()


def core_sources():
    import re
    text = (ROOT / "core/sources.cmake").read_text()
    block = text[text.index("set(N60_CORE_SOURCES"):]
    block = block[:block.index(")")]
    return re.findall(r"src/([A-Za-z0-9_/]+)\.cpp", block)


def main():
    lanes = {}
    for line in build_and_run():
        f = line.split()
        if f and f[0] == "LANE":
            lanes.setdefault(int(f[1]), {})[int(f[2])] = (int(f[3]), [float(x) for x in f[4:]])
    require(sorted(lanes) == list(RATES), "probe did not report every rate")
    for rate in RATES:
        delays = {lane: v[0] for lane, v in lanes[rate].items()}
        require(len(set(delays.values())) == 1, "%d Hz lane delays differ: %s" % (rate, delays))
        for lane, (_, mags) in lanes[rate].items():
            for f, got in zip(FREQS, mags):
                if lane == LFE:
                    want = 0.0
                else:
                    want = peaking_db(rate, SESSION, f) + (peaking_db(rate, GROUP, f) if lane == CENTRE else 0.0)
                require(abs(got - want) <= TOLERANCE_DB,
                        "%d Hz lane %d at %g Hz: %.3f dB, model %.3f" % (rate, lane, f, got, want))
        print("E33 groups %6d Hz: 6 lanes aligned at %d frames, centre = session + group" % (rate, delays[0]))
    print("E33 EQ groups reference: PASS at %d rates" % len(RATES))


if __name__ == "__main__":
    try:
        main()
    except AssertionError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
