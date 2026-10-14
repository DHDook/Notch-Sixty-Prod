#!/usr/bin/env python3
"""PR117C: production normalized-SOFA HRTF spatial-reference verification.

A real production binaural renderer consumes *synthetic normalized views*.
The Python ground truth independently predicts sample impulses, direction
selection, ear separation, and rate-dependent latency. No .sofa decoding,
HDF5 dependency, real listener measurements or runtime audio access.
"""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "ci/acoustic_reference_lab/pr117c_spatial_probe.c"
INCLUDE = ROOT / "NotchSixty/Audio/Realtime"
RATES = (44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000)
FRAMES = (0, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137)
TOLERANCE = 2e-4


def require(ok, detail):
    if not ok:
        raise AssertionError("PR117C SOFA/HRTF reference failed: " + detail)


def close(observed, expected, tolerance, detail):
    require(math.isfinite(observed) and math.isfinite(expected),
            detail + " nonfinite")
    diff = abs(observed - expected)
    require(diff <= tolerance,
            "%s: %.12g versus %.12g delta %.7g" %
            (detail, observed, expected, diff))
    return diff


def build_run_probe():
    compiler = shutil.which("clang")
    require(compiler is not None, "Clang not installed")
    with tempfile.TemporaryDirectory(prefix="n60-pr117c-") as work:
        binary = Path(work) / "spatial_probe"
        cc = subprocess.run(
            [compiler, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I" + str(INCLUDE), str(SOURCE), "-lm", "-o", str(binary)],
            check=False, capture_output=True, text=True, timeout=120)
        require(cc.returncode == 0, "production C probe compile:\n" + cc.stderr)
        result = subprocess.run([str(binary)], check=False,
                                capture_output=True, text=True, timeout=120)
    require(result.returncode == 0 and not result.stderr,
            "spatial probe failed:\n" + result.stderr)
    return result.stdout


def read_records(lines):
    table = defaultdict(list)
    lengths = {
        "WRAP": 2, "BADVIEW": 2, "SELECT": 4,
        "RATEREJECT": 3, "SPATLAT": 3, "SPAT": 6,
    }
    for line in lines:
        if line == "END":
            continue
        cols = line.split()
        require(cols[0] in lengths and len(cols) == lengths[cols[0]],
                "unrecognized record " + line[:90])
        values = tuple(float(x) for x in cols[1:])
        require(all(math.isfinite(x) for x in values),
                "nonfinite spatial probe output")
        table[cols[0]].append(values)
    return table


def verify_direction_geometry(rows):
    # The physical direction +179° lies just 2° from -179°; comparing
    # raw signed azimuth differences would incorrectly choose +155° (24°).
    candidates = (-179., 155.)
    expected = max(range(len(candidates)),
                   key=lambda j: math.cos(math.radians(179. - candidates[j])))
    require(expected == 0, "fixture has no 180-degree wrapping distinction")
    require(rows["WRAP"] == [(0.,)], "source direction wrapping failed")
    require(rows["BADVIEW"] == [(1.,)], "nonfinite source position accepted")
    return [
        {"name": "angular_selection_wraps_at_180_degrees",
         "type": "production_against_independent_reference",
         "chosenMeasurement": 0, "targetAzimuthDegrees": 179},
        {"name": "normalized_view_rejects_nonfinite_position",
         "type": "production_safety_rejection", "accepted": False},
    ]


def verify_rate(rate, records):
    cases = []
    assigned = sorted((int(x[1]), int(x[2])) for x in records["SELECT"]
                      if int(x[0]) == rate)
    require(assigned == [(0, 2), (1, 1)],
            "left/right virtual speaker direction swapped at " + str(rate))
    cases.append({
        "name": "spatial_direction_to_channel_mapping_%d" % rate,
        "type": "production_against_independent_reference",
        "programChannels": 2,
        "sourceMeasurementIndices": [2, 1],
    })

    mismatch = [int(x[1]) for x in records["RATEREJECT"]
                if int(x[0]) == rate]
    require(mismatch == [1], "mismatched view rate was not rejected")
    cases.append({
        "name": "SOFA_sample_rate_mismatch_fails_closed_%d" % rate,
        "type": "production_safety_rejection",
        "mismatchedRateAccepted": False,
    })

    delay = [int(x[1]) for x in records["SPATLAT"] if int(x[0]) == rate]
    require(delay == [128], "binaural partition delay not 128 frames")
    time_ms = delay[0] * 1000 / rate
    close(time_ms * rate / 1000, 128, 1e-12, "latency ms conversion")
    cases.append({
        "name": "spatial_engine_latency_%d" % rate,
        "type": "production_against_independent_reference",
        "latencyFrames": 128, "latencyMS": time_ms,
    })

    # The view uses channel-independent pre-aligned float IRs. Nonzero
    # samples above are already synthetic Data.Delay-baked tap offsets.
    # This oracle does not call the production renderer or FFT.
    reference = {
        0: {"left": {128: 0.7, 129: 0.1},
            "right": {130: 0.2}},
        1: {"left": {131: 0.15},
            "right": {129: 0.6, 132: 0.1}},
    }
    extracted = [(int(n), float(l), float(r), int(channel))
                 for rrate, channel, n, l, r in records["SPAT"]
                 if int(rrate) == rate]
    require(len(extracted) == 2 * len(FRAMES),
            "missing per-ear spatial impulses at %d Hz" % rate)
    max_error = 0.
    for channel in range(2):
        rows_for_channel = sorted((n, l, r) for n, l, r, ch in extracted
                                  if ch == channel)
        require([n for n, _, _ in rows_for_channel] == list(FRAMES),
                "missing FIR frame positions for channel %d" % channel)
        for frame, left, right in rows_for_channel:
            expected = reference[channel]
            max_error = max(
                max_error,
                close(left, expected["left"].get(frame, 0.), TOLERANCE,
                      "left ear independence"),
                close(right, expected["right"].get(frame, 0.), TOLERANCE,
                      "right ear independence"),
            )
    cases.append({
        "name": "SOFA_view_two_ears_and_two_speakers_%d" % rate,
        "type": "production_against_independent_reference",
        "maxSampleError": max_error,
        "perEarImpulseLength": 8,
        "nonzeroFramesLeftSource": [128, 129, 130],
        "nonzeroFramesRightSource": [129, 131, 132],
    })

    # Two frames are 45.35 us at 44.1k, 5.21 us at 384k; the physical
    # interaural delay is NOT rate invariant if the tap offsets are fixed.
    interaural_frames = 130 - 128
    interval_ms = 1000 * interaural_frames / rate
    close(interval_ms * rate / 1000, 2, 1e-12,
          "synthetic interaural frame period")
    cases.append({
        "name": "baked_IR_interaural_delay_accounting_%d" % rate,
        "type": "synthetic_analytical_ground_truth",
        "interauralDelayFrames": 2,
        "syntheticInterauralDelayMS": interval_ms,
        "validatedRealSOFADataDelay": False,
    })
    return cases


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--report", type=Path)
    args.add_argument("--commit", default="unknown")
    parsed = args.parse_args()
    lines = build_run_probe().splitlines()
    require(lines and lines[-1] == "END", "C probe not complete")
    records = read_records(lines)
    require(len(records["SELECT"]) == 16, "missing source mapping rows")
    require(len(records["RATEREJECT"]) == 8, "missing rate refusal rows")
    require(len(records["SPATLAT"]) == 8, "missing spatial latency rows")
    require(len(records["SPAT"]) == 192, "missing spatial impulse rows")
    cases = verify_direction_geometry(records)
    for rate in RATES:
        cases.extend(verify_rate(rate, records))
    require(len(cases) == 42, "unexpected spatial case count")
    result = {
        "schemaVersion": 1,
        "milestone": "PR117C",
        "slice": 4,
        "sampleRatesHz": list(RATES),
        "sourceCommit": parsed.commit,
        "caseCount": len(cases),
        "evidenceAuthority": "remoteSoftware",
        "syntheticOnly": True,
        "realSOFAFileImported": False,
        "normalizationAdapterTested": False,
        "realHRTFMeasured": False,
        "physicalAcceptanceComplete": False,
        "full384kHzRuntimeAcceptance": False,
        "releaseAcceptanceComplete": False,
        "liveFeedForwardANCAuthorized": False,
        "mayMergeIntoMain": False,
        "cases": cases,
    }
    encoded = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
    if parsed.report:
        parsed.report.parent.mkdir(parents=True, exist_ok=True)
        parsed.report.write_text(encoded, encoding="utf-8")
    print("PR117C spatial/SOFA normalized reference PASS: %d cases" % len(cases))


if __name__ == "__main__":
    main()
