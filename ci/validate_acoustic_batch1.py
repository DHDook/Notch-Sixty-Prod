#!/usr/bin/env python3
"""Batch 1 acoustic-reference integration gate.

Runs existing independent production/acoustic suites together, verifies rate
coverage and evidence authority, and produces one exact-head report. Targeted
C/Python checks are inexpensive; native SOFA-file XCTest and full app Release
/ XCTest remain the explicitly gated macOS integration job.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RATES = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
SUITES = (
    ("production_acoustics", "ci/validate_pr117_acoustic_reference_lab.py", 80),
    ("fir_latency_headroom", "ci/validate_pr117b_fir_latency_headroom.py", 19),
    ("sofa_spatial_renderer", "ci/validate_pr117c_spatial_reference.py", 42),
)
SAFETY = ("physicalAcceptanceComplete", "releaseAcceptanceComplete",
          "liveFeedForwardANCAuthorized", "mayMergeIntoMain")


def require(condition: bool, reason: str) -> None:
    if not condition:
        raise AssertionError("Acoustic Batch 1: " + reason)


def run(args: list[str], timeout: int = 180) -> None:
    result = subprocess.run(
        [sys.executable, *args], cwd=ROOT, capture_output=True,
        text=True, check=False, timeout=timeout
    )
    if result.returncode:
        raise AssertionError(
            "Acoustic Batch 1 command failed: %s\n%s\n%s" %
            (" ".join(args), result.stdout[-7000:], result.stderr[-7000:])
        )
    print(result.stdout.strip())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    parser.add_argument("--commit", default=os.environ.get("N60_COMMIT", "unknown"))
    arguments = parser.parse_args()
    suite_evidence = []
    with tempfile.TemporaryDirectory(prefix="n60-acoustic-batch1-") as folder:
        for suite_id, script, expected_count in SUITES:
            path = Path(folder) / (suite_id + ".json")
            run([script, "--commit", arguments.commit, "--report", str(path)])
            evidence = json.loads(path.read_text(encoding="utf-8"))
            require(evidence.get("sourceCommit") == arguments.commit,
                    "commit mismatch: " + suite_id)
            require(evidence.get("sampleRatesHz") == RATES,
                    "complete 44.1/48-family rates through 384 kHz absent: " + suite_id)
            require(evidence.get("caseCount") == expected_count,
                    "case count mismatch: " + suite_id)
            require(evidence.get("evidenceAuthority") == "remoteSoftware"
                    and evidence.get("syntheticOnly") is True,
                    "software/synthetic authority lost: " + suite_id)
            for field in SAFETY:
                require(evidence.get(field) is False,
                        "unsafe positive claim %s in %s" % (field, suite_id))
            cases = evidence.get("cases")
            require(isinstance(cases, list) and len(cases) == expected_count,
                    "case list incomplete: " + suite_id)
            names = [case["name"] for case in cases]
            require(len(names) == len(set(names)),
                    "duplicate case identities: " + suite_id)
            suite_evidence.append({
                "suite": suite_id,
                "fixtureCount": expected_count,
                "source": script,
                "status": "passed",
                "sourceCommit": arguments.commit,
            })
    # The product already has a real SOFA/HDF5 reader. These contracts verify
    # its ownership and test-fixture boundary cheaply on both platforms.
    for script in (
        "ci/validate_pr117d_real_sofa.py",
        "ci/validate_pr85_native_sofa.py",
        "ci/validate_pr117a_crossover_precision.py",
        "ci/validate_pr112a_hardware_acceptance.py",
    ):
        args = [script]
        if script.endswith("validate_pr117a_crossover_precision.py"):
            args.append("--source-only")
        run(args)

    fixture_count = sum(x["fixtureCount"] for x in suite_evidence)
    require(fixture_count == 141, "expected 141 independent reference cases")
    result = {
        "schemaVersion": 1,
        "milestone": "ACOUSTIC_BATCH_1",
        "sourceCommit": arguments.commit,
        "status": "portable_reference_passed",
        "totalIndependentReferenceCases": fixture_count,
        "supportedNumericalSampleRatesHz": RATES,
        "suites": suite_evidence,
        "realSOFAFileTests": "separate Apple Silicon XCTest acceptance",
        "native384kHzAudioTransportVerified": False,
        "automaticSOFASampleRateConversionVerified": False,
        "realHardwareMeasured": False,
        "evidenceAuthority": "remoteSoftware",
        "syntheticOnly": True,
        "physicalAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "liveFeedForwardANCAuthorized": False,
        "mayMergeIntoMain": False,
        "fullAppIntegrationPassed": False,
        "externalLegalReviewComplete": False,
    }
    output = json.dumps(result, sort_keys=True, indent=2, allow_nan=False) + "\n"
    if arguments.report:
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(output, encoding="utf-8")
    print("Acoustic Batch 1 reference PASS: %d cases at eight standard rates"
          " through 384 kHz; hardware and release acceptance pending" % fixture_count)


if __name__ == "__main__":
    main()
