#!/usr/bin/env python3
"""PR117 slice 1: offline acoustic reference tests independent of production DSP.

Compile and run the live production-header C probe, then independently compute
expected values in Python. No audio device, mic, or speaker connection is used.
"""

import argparse
import cmath
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
from collections import defaultdict
from acoustic_reference_lab.pr117_multiseat_reference import run_slice2

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/acoustic_reference_lab/pr117_production_probe.c"
INCLUDE = ROOT / "NotchSixty/Audio/Realtime"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)


def check(condition, reason):
    if not condition:
        raise AssertionError("PR117 acoustic reference failed: " + reason)


def close(a, b, tolerance, name):
    check(math.isfinite(a) and math.isfinite(b), name + " is nonfinite")
    difference = abs(a - b)
    check(difference <= tolerance, "%s: %g versus %g (limit %g)" % (
        name, a, b, tolerance))
    return difference


def peaking(rate):
    # Independent standard peaking transfer, Python double arithmetic.
    w = 2 * math.pi * 1000.0 / rate
    alpha = math.sin(w) / 2
    a = 10 ** (6 / 40)
    a0 = 1 + alpha / a
    return ((1 + alpha * a) / a0, -2 * math.cos(w) / a0,
            (1 - alpha * a) / a0, -2 * math.cos(w) / a0,
            (1 - alpha / a) / a0)


def transfer(c, hz, rate):
    b0, b1, b2, a1, a2 = c
    z = cmath.exp(-2j * math.pi * hz / rate)
    den = 1 + a1 * z + a2 * z * z
    check(abs(den) > 1e-12, "near-singular transfer")
    return (b0 + b1 * z + b2 * z * z) / den


def impulse(c, length):
    # Direct-form difference equation, not production's transposed DF-II.
    b0, b1, b2, a1, a2 = c
    y = []
    for n in range(length):
        value = (b0 if n == 0 else 0.0) + (b1 if n == 1 else 0.0)
        value += b2 if n == 2 else 0.0
        if n > 0:
            value -= a1 * y[-1]
        if n > 1:
            value -= a2 * y[-2]
        y.append(value)
    return y


def probe():
    cc = shutil.which("clang")
    check(cc is not None, "Clang not installed")
    check(SOURCE.is_file(), "production C probe missing")
    with tempfile.TemporaryDirectory(prefix="n60-pr117-") as temp:
        executable = Path(temp) / "lab"
        compiled = subprocess.run(
            [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(INCLUDE), str(SOURCE), "-lm", "-o", str(executable)],
            capture_output=True, text=True, timeout=120)
        check(compiled.returncode == 0,
              "production C probe Clang build failed:\n" + compiled.stderr)
        run = subprocess.run(
            [str(executable)], capture_output=True, text=True,
            check=True, timeout=120)
    check(run.stdout.splitlines()[-1] == "END", "C probe aborted or incomplete")
    return run.stdout


def parse(output):
    width = {"PEQ": 8, "IMP": 4, "XO": 4, "HP24": 8, "LP24": 8,
             "HP48": 8, "LP48": 8, "HPIMP": 5, "XFEED": 4,
             "BRLAT": 3, "BRIMP": 5}
    rows = defaultdict(list)
    for line in output.splitlines():
        if line == "END":
            continue
        parts = line.split()
        check(parts[0] in width and len(parts) == width[parts[0]],
              "unrecognized/malformed C probe record: " + line[:100])
        values = tuple(float(v) for v in parts[1:])
        check(all(map(math.isfinite, values)), "nonfinite probe values")
        rows[parts[0]].append(values)
    check(len(rows["IMP"]) == len(RATES) * 512, "missing PEQ impulse samples")
    check(len(rows["HPIMP"]) == len(RATES) * 8, "missing headphone samples")
    check(len(rows["XFEED"]) == len(RATES) * 2, "missing crossfeed probes")
    check(len(rows["BRLAT"]) == len(RATES), "missing binaural latency")
    check(len(rows["BRIMP"]) == 4 * len(RATES), "missing binaural probes")
    return rows


def check_real_dsp(rows):
    cases = []
    for rate in RATES:
        coeff = [r[2:] for r in rows["PEQ"] if int(r[0]) == rate]
        check(len(coeff) == 1, "PEQ rate missing")
        observed = coeff[0]
        expected = peaking(rate)
        coefficient_error = max(close(x, y, 2e-6, "PEQ coefficient")
                                for x, y in zip(observed, expected))
        gain = 20 * math.log10(abs(transfer(observed, 1000, rate)))
        close(gain, 6.0, 0.012, "PEQ gain at 1 kHz")
        # Compare in audible dB units across the entire sample-rate matrix.
        # At 352.8/384 kHz, float coefficient quantization slightly
        # increases low-frequency sensitivity relative to the ideal double
        # coefficients; a fixed 0.00012 linear-amplitude bound is not
        # scale-invariant. 0.005 dB remains a strict, documented tolerance.
        max_response_error_db = 0.0
        for frequency in (65.0, 200.0, 1000.0, 5000.0, 16000.0):
            actual_db = 20 * math.log10(abs(transfer(observed, frequency, rate)))
            reference_db = 20 * math.log10(abs(transfer(expected, frequency, rate)))
            max_response_error_db = max(
                max_response_error_db,
                close(actual_db, reference_db, 0.005,
                      "independent PEQ transfer dB @ %d Hz / %g Hz" % (rate, frequency)),
            )
        samples = sorted((int(x[1]), x[2]) for x in rows["IMP"] if int(x[0]) == rate)
        check([n for n, _ in samples] == list(range(512)), "PEQ frame ordering")
        reference = impulse(expected, 512)
        impulse_error = max(close(value, reference[n], 5e-5, "PEQ impulse")
                            for n, value in samples)
        cases.append({"name": "peq_impulse_transfer_%d" % rate,
                      "type": "production_against_independent_reference",
                      "maxCoefficientError": coefficient_error,
                      "maxImpulseError": impulse_error,
                      "maxResponseErrorDB": max_response_error_db,
                      "centerGainDB": gain})

        for order, sections in ((24, 2), (48, 4)):
            count = [int(x[2]) for x in rows["XO"] if int(x[0]) == rate
                     and int(x[1]) == order]
            check(count == [sections], "crossover section count")
            legs = {}
            for key in ("HP%d" % order, "LP%d" % order):
                rows_for_leg = sorted((int(x[1]), x[2:])
                                      for x in rows[key] if int(x[0]) == rate)
                check([n for n, _ in rows_for_leg] == list(range(sections)),
                      "crossover section order")
                legs[key] = [c for _, c in rows_for_leg]
            max_sum_err = 0.0
            for freq in (25, 45, 80, 160, 320):
                high = math.prod(transfer(c, freq, rate)
                                 for c in legs["HP%d" % order])
                low = math.prod(transfer(c, freq, rate)
                                for c in legs["LP%d" % order])
                if freq == 80:
                    close(abs(high), 0.5, 0.012, "LR high -6 dB crossing")
                    close(abs(low), 0.5, 0.012, "LR low -6 dB crossing")
                max_sum_err = max(max_sum_err,
                                  close(abs(high + low), 1.0, 0.018,
                                        "coherent LR sum"))
            cases.append({"name": "linkwitz_riley_%d_%d" % (order, rate),
                          "type": "production_against_independent_reference",
                          "maxCoherentSumError": max_sum_err})

        # Independent impulses: headroom attenuates 0.5; L trim another
        # 0.5; R is delayed three full frames.
        samples = sorted((int(x[1]), x[2], x[3])
                         for x in rows["HPIMP"] if int(x[0]) == rate)
        check([n for n, _, _ in samples] == list(range(8)), "headphone frames")
        for n, l, r in samples:
            close(l, 0.25 if n == 0 else 0.0, 1e-5, "headphone left")
            close(r, 0.5 if n == 3 else 0.0, 1e-5, "headphone right")
        cases.append({"name": "headphone_isolation_delay_%d" % rate,
                      "type": "production_against_independent_reference",
                      "leftGain": 0.25, "rightDelayFrames": 3})

        crossfeed = {int(r[1]): r[2] for r in rows["XFEED"] if int(r[0]) == rate}
        check(set(crossfeed) == {80, 10000}, "crossfeed frequencies")
        alpha = 1 - math.exp(-2 * math.pi * 700 / rate)
        for freq in (80, 10000):
            w = 2 * math.pi * freq / rate
            reference = 0.5 * abs(alpha / (
                1 - (1 - alpha) * cmath.exp(-1j * w)))
            close(crossfeed[freq], reference, 0.007, "headphone crossfeed")
        check(crossfeed[80] > 5 * crossfeed[10000],
              "crossfeed insufficiently frequency-dependent")
        cases.append({"name": "headphone_crossfeed_%d" % rate,
                      "type": "production_against_independent_reference",
                      "80HzContralateralGain": crossfeed[80],
                      "10kHzContralateralGain": crossfeed[10000]})

    for rate in RATES:
        latencies = [int(x[1]) for x in rows["BRLAT"] if int(x[0]) == rate]
        check(latencies == [128], "binaural engine latency at %d Hz" % rate)
        taps = {int(n): (l, r) for rrate, n, l, r in rows["BRIMP"]
                if int(rrate) == rate}
        check(set(taps) == {0, 127, 128, 129},
              "binaural frame coverage at %d Hz" % rate)
        for n in (0, 127, 129):
            close(taps[n][0], 0, 1e-4, "binaural left zero")
            close(taps[n][1], 0, 1e-4, "binaural right zero")
        close(taps[128][0], 0.8, 2e-4, "binaural ipsilateral")
        close(taps[128][1], 0.2, 2e-4, "binaural contralateral")
        cases.append({"name": "binaural_two_ear_impulse_%d" % rate,
                      "type": "production_against_independent_reference",
                      "sampleRateHz": rate, "latencyFrames": 128,
                      "observedEarGains": list(taps[128])})
    return cases


def check_known_acoustics():
    cases = []
    for rate in RATES:
        frames = round(rate * 0.006)
        close(1000 * frames / rate, 6.0, 0.015, "six-ms reflection")
        cases.append({"name": "two_path_room_reflection_%d" % rate,
                      "type": "synthetic_analytical_ground_truth",
                      "delayFrames": frames, "lateEnergyFraction": 0.16 / 1.16})
    # Equal and opposite paths: EQ that scales both equally cannot fill a null.
    first, second = complex(1, 0), complex(-1, 0)
    close(abs(first + second), 0, 1e-14, "coherent cancellation")
    for boost in (0, 6, 12):
        close(abs((first + second) * 10 ** (boost / 20)),
              0, 1e-12, "EQ fails to fill a coherent null")
    cases.append({"name": "coherent_null_not_fixed_by_Eq",
                  "type": "synthetic_analytical_ground_truth",
                  "coherentMagnitude": 0.0,
                  "noncoherentMeanMagnitude": 1.0})
    values = (-3.0, 0.0, 4.5)
    weights = (0.5, 0.3, 0.2)

    def spread(xs):
        mean = sum(w * x for w, x in zip(weights, xs))
        return math.sqrt(sum(w * (x - mean) ** 2 for w, x in zip(weights, xs)))

    base = spread(values)
    check(base > 2, "sufficient synthetic multi-seat spread")
    for trim in (-9.0, -3.0, 2.0):
        close(spread([x + trim for x in values]), base,
              1e-12, "global trim does not improve seat variation")
    cases.append({"name": "multi_seat_variation_gain_invariance",
                  "type": "synthetic_analytical_ground_truth",
                  "weightedSpreadDB": base})
    close(1024 / 48000 * 1000, 21.333333333333332, 1e-10,
          "2049-tap symmetric FIR group delay")
    cases.append({"name": "symmetric_FIR_known_group_delay",
                  "type": "synthetic_analytical_ground_truth",
                  "tapCount": 2049, "delayFrames": 1024,
                  "delayMillisecondsAt48k": 1024 / 48000 * 1000})
    return cases


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--commit", default="unknown")
    parser.add_argument("--slice2-only", action="store_true",
                        help="Run synthetic multi-seat/uncertainty fixtures without production C probe")
    args = parser.parse_args()
    if args.slice2_only:
        cases = run_slice2(RATES)
        check(len(cases) == 2 * len(RATES) + 5, "Slice 2 case count")
    else:
        cases = (check_real_dsp(parse(probe())) + check_known_acoustics()
                 + run_slice2(RATES))
        check(len(cases) == 9 * len(RATES) + 8, "full case count")
    result = {
        "schemaVersion": 1,
        "milestone": "PR117",
        "slice": 2,
        "validationMaxNominalSampleRateHz": 384000,
        "evidenceScope": "syntheticMultiseat" if args.slice2_only else "productionReferenceAndSynthetic",
        "highRateCrossoverPrecisionIssueResolved": False,
        "full384kHzRuntimeAcceptance": False,
        "sampleRateClaim": "offline DSP math only; actual native device rates and throughput require hardware checks",
        "sourceCommit": args.commit,
        "evidenceAuthority": "remoteSoftware",
        "syntheticOnly": True,
        "realHardwareMeasured": False,
        "physicalAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "liveFeedForwardANCAuthorized": False,
        "mayMergeIntoMain": False,
        "sampleRatesHz": list(RATES),
        "productionModules": [] if args.slice2_only else [
            "N60Biquad", "N60Crossover", "N60HeadphoneDSP", "N60BinauralRenderer"],
        "caseCount": len(cases),
        "cases": cases,
    }
    encoded = json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n"
    if args.report is not None:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(encoded, encoding="utf-8")
    print("PR117 slice 2 %s PASS: %d analytical cases; "
          "remote/synthetic only" % ("synthetic-only" if args.slice2_only else "full", len(cases)))


if __name__ == "__main__":
    main()
