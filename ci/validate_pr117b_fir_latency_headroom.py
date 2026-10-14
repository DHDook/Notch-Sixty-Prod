#!/usr/bin/env python3
"""PR117B Slice 3: independent FIR response, headroom and true-peak oracles.

Compares a real N60ProgramFIRRuntime C probe with independently assembled
time-domain convolution. Remaining cases are synthetic known-math fixtures,
not hardware measurements or tests of a production true-peak limiter.
"""

import argparse
import cmath
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/acoustic_reference_lab/pr117b_fir_probe.c"
HEADER_DIR = ROOT / "NotchSixty/Audio/Realtime"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
TAPS = (0.0625, 0.25, 0.375, 0.25, 0.0625)
FRAMES = 264
PARTITION = 256


def require(value, reason):
    if not value:
        raise AssertionError("PR117B FIR reference failed: " + reason)


def close(a, b, bound, reason):
    require(math.isfinite(a) and math.isfinite(b), reason + " nonfinite")
    delta = abs(a - b)
    require(delta <= bound, f"{reason}: actual {a:.10g} expected {b:.10g} delta {delta:.5g}")
    return delta


def production_impulse():
    compiler = shutil.which("clang")
    require(compiler is not None, "Clang required")
    with tempfile.TemporaryDirectory(prefix="n60-pr117b-") as folder:
        binary = Path(folder) / "fir_ref_probe"
        cc = subprocess.run(
            [compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(HEADER_DIR), str(SOURCE), "-lm", "-o", str(binary)],
            capture_output=True, text=True, check=False, timeout=120)
        require(cc.returncode == 0, "FIR probe compilation failed:\n" + cc.stderr)
        run = subprocess.run([str(binary)], capture_output=True, text=True,
                             check=False, timeout=120)
    require(run.returncode == 0 and not run.stderr,
            "FIR probe failed:\n" + run.stderr)
    lines = run.stdout.splitlines()
    require(lines[-1:] == ["END"], "FIR probe incomplete")
    info = lines[0].split()
    require(info == ["FIRINFO", "256", "2", "5", "1"],
            "FIR program latency or channel count changed")
    records = []
    for n, line in enumerate(lines[1:-1]):
        x = line.split()
        require(len(x) == 4 and x[0] == "FIR" and x[1] == str(n),
                "bad FIR output index")
        records.append((float(x[2]), float(x[3])))
    require(len(records) == FRAMES, "FIR data incomplete")
    worst = 0.0
    for n, (left, right) in enumerate(records):
        # Direct convolution of x[n]=0.5*delta[n] and the known 5 taps,
        # independently shifted by the program's 256-frame engine delay.
        k = n - PARTITION
        expected_l = 0.5 * TAPS[k] if 0 <= k < len(TAPS) else 0.0
        expected_r = 0.25 if n == 0 else 0.0  # inactive channel passthrough
        worst = max(worst, close(left, expected_l, 2e-5, "FIR impulse left"),
                    close(right, expected_r, 2e-6, "FIR inactive right"))
    return {
        "name": "production_partitioned_FIR_vs_direct_convolution",
        "type": "production_against_independent_reference",
        "engineLatencyFrames": PARTITION,
        "declaredGroupDelayFrames": 2,
        "activeChannelCount": 1,
        "maximumSampleAbsError": worst,
    }


def analytical_response(rate):
    """Two independent formulations of a five-tap symmetric low-pass."""
    errors = []
    for hz in (40.0, 80.0, 1000.0, 0.10 * rate, 0.40 * rate):
        omega = 2 * math.pi * hz / rate
        dft = sum(tap * cmath.exp(-1j * omega * n)
                  for n, tap in enumerate(TAPS))
        closed_form = cmath.exp(-2j * omega) * (
            0.375 + 0.5 * math.cos(omega) + 0.125 * math.cos(2 * omega)
        )
        errors.append(close(abs(dft - closed_form), 0, 1e-12,
                            "FIR transfer closed form"))
    close(sum(TAPS), 1.0, 1e-15, "FIR DC normalization")
    return {
        "name": "symmetric_FIR_response_%d" % rate,
        "type": "synthetic_analytical_ground_truth",
        "maxComplexError": max(errors),
        "dcGain": sum(TAPS),
    }


def intrinsic_latency(rate):
    # Engine delay 256 and a five-tap symmetric linear-phase group delay 2.
    group_delay_frames = (len(TAPS) - 1) // 2
    require(group_delay_frames == 2, "incorrect linear-phase group delay")
    pipeline_frames = PARTITION + group_delay_frames
    effective_ms = 1000 * pipeline_frames / rate
    close(effective_ms * rate / 1000, 258, 1e-12, "frame/ms conversion")
    return {
        "name": "FIR_latency_accounting_%d" % rate,
        "type": "synthetic_analytical_ground_truth",
        "engineLatencyFrames": PARTITION,
        "intrinsicGroupDelayFrames": group_delay_frames,
        "effectiveImpulseCenterFrames": pipeline_frames,
        "effectiveMilliseconds": effective_ms,
    }


def headroom_budget():
    # L1 amplitude is a conservative, adversarial no-clipping bound and
    # is not identical to a music-signal peak or an acoustic SPL limit.
    aggressive = (0.7, 0.7)
    taps_sum = sum(abs(x) for x in aggressive)
    required_db = 20 * math.log10(taps_sum)
    max_output = sum(x for x in aggressive)  # bounded input [1,1]
    close(max_output, 1.4, 1e-14, "adversarial FIR overshoot")
    close(max_output * 10 ** (-required_db / 20), 1.0,
          1e-12, "headroom makes FIR sum safe")
    require(required_db > 2.9, "headroom example lacks overshoot")
    return {
        "name": "FIR_L1_headroom_bound",
        "type": "synthetic_analytical_ground_truth",
        "tapAbsoluteSum": taps_sum,
        "minimumAttenuationDB": required_db,
        "notAcousticSPL": True,
    }


def intersample_peak():
    # Precisely known band-limited sine below Nyquist; sample peaks can
    # understate its continuous-time peak. Do not assume any particular
    # shipping oversampler filter or limiter threshold from this example.
    omega = math.pi / 2
    wave = lambda time: 0.9 * math.sin(omega * (time + 0.5))
    sample_peak = max(abs(wave(n)) for n in range(64))
    quarter_grid_peak = max(abs(wave(n / 4)) for n in range(64 * 4))
    close(sample_peak, 0.9 / math.sqrt(2), 1e-13,
          "known sine sample peak")
    close(quarter_grid_peak, 0.9, 1e-13,
          "known sine 4x intermediate peak")
    gap_db = 20 * math.log10(quarter_grid_peak / sample_peak)
    close(gap_db, 20 * math.log10(math.sqrt(2)), 1e-12,
          "analytical intersample overshoot dB")
    return {
        "name": "known_analytic_intersample_true_peak",
        "type": "synthetic_analytical_ground_truth",
        "samplePeakLinear": sample_peak,
        "continuousAnd4xPeakLinear": quarter_grid_peak,
        "gapDB": gap_db,
        "verifiedProductionLimiter": False,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--commit", default="unknown")
    args = parser.parse_args()
    cases = [production_impulse()]
    for rate in RATES:
        cases.append(analytical_response(rate))
        cases.append(intrinsic_latency(rate))
    cases.extend([headroom_budget(), intersample_peak()])
    require(len(cases) == 19, "FIR reference case count changed")
    report = {
        "schemaVersion": 1,
        "milestone": "PR117B",
        "slice": 3,
        "sourceCommit": args.commit,
        "sampleRatesHz": list(RATES),
        "caseCount": len(cases),
        "evidenceAuthority": "remoteSoftware",
        "syntheticOnly": True,
        "physicalAcceptanceComplete": False,
        "full384kHzRuntimeAcceptance": False,
        "releaseAcceptanceComplete": False,
        "liveFeedForwardANCAuthorized": False,
        "mayMergeIntoMain": False,
        "cases": cases,
    }
    data = json.dumps(report, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(data, encoding="utf-8")
    print(f"PR117B FIR/latency/headroom reference PASS: {len(cases)} cases")


if __name__ == "__main__":
    main()
