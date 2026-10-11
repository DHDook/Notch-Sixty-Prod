#!/usr/bin/env python3
import argparse
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CC = os.environ.get("CC", "clang")

METRIC_PATTERN = re.compile(
    r"^(?P<name>[a-z0-9-]+): "
    r"(?P<ns>[0-9]+(?:\.[0-9]+)?) ns/frame, theoretical "
    r"(?P<core>[0-9]+(?:\.[0-9]+)?)% of one core at 96 kHz "
    r"\((?P<seconds>[0-9]+(?:\.[0-9]+)?) s / "
    r"(?P<frames>[0-9]+) frames"
)
BRIDGE_COUNTER_PATTERN = re.compile(
    r"capture callbacks=(?P<capture>[0-9]+) "
    r"output callbacks=(?P<output>[0-9]+)"
)
RSS_PATTERN = re.compile(
    r"^\s*(?P<bytes>[0-9]+)\s+maximum resident set size\s*$",
    re.MULTILINE,
)
TIME_PATTERN = re.compile(
    r"^\s*(?P<real>[0-9]+(?:\.[0-9]+)?) real\s+"
    r"(?P<user>[0-9]+(?:\.[0-9]+)?) user\s+"
    r"(?P<sys>[0-9]+(?:\.[0-9]+)?) sys\s*$",
    re.MULTILINE,
)

EXPECTED_RENDER_CASES = {
    "global-bypass",
    "unity-parked",
    "compressor",
    "full-metering",
}
EXPECTED_BRIDGE_CASES = {
    "bridge-unity-512",
    "bridge-output-vu-512",
}


def run_checked(argv: list[str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        if result.stdout:
            print(result.stdout)
        if result.stderr:
            print(result.stderr)
        raise SystemExit(
            f"PR101 resource baseline failed ({result.returncode}): "
            + " ".join(argv)
        )
    return result


def realtime_sources(include_bridge: bool) -> list[str]:
    sources = sorted(
        str(path.relative_to(ROOT))
        for path in (ROOT / "NotchSixty/Audio/Realtime").glob("*.c")
    )
    if not include_bridge:
        sources = [
            source
            for source in sources
            if not source.endswith("N60RealtimeAudioBridge.c")
        ]
    return sources


def compile_benchmarks(tmpdir: Path) -> dict[str, Path]:
    render = tmpdir / "pr101-render-o3"
    bridge = tmpdir / "pr101-bridge-o3"

    render_command = [
        CC,
        "-std=c11",
        "-O3",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-arch",
        "arm64",
        "-include",
        "stddef.h",
        "-INotchSixty/Audio/Realtime",
        "ci/benchmark_pr35_render_kernel.c",
        *realtime_sources(include_bridge=False),
        "-framework",
        "Accelerate",
        "-o",
        str(render),
    ]
    bridge_command = [
        CC,
        "-std=c11",
        "-O3",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-arch",
        "arm64",
        "-include",
        "stddef.h",
        "-INotchSixty/Audio/Realtime",
        "ci/benchmark_pr35_realtime_bridge.c",
        *realtime_sources(include_bridge=True),
        "-framework",
        "Accelerate",
        "-framework",
        "CoreAudio",
        "-o",
        str(bridge),
    ]

    run_checked(render_command)
    run_checked(bridge_command)
    return {"renderKernel": render, "realtimeBridge": bridge}


def parse_run(name: str, output: str, time_output: str) -> dict[str, Any]:
    metrics: dict[str, dict[str, Any]] = {}
    for line in output.splitlines():
        match = METRIC_PATTERN.match(line.strip())
        if not match:
            continue
        case = match.group("name")
        ns_per_frame = float(match.group("ns"))
        one_core = float(match.group("core"))
        seconds = float(match.group("seconds"))
        frames = int(match.group("frames"))
        if (
            not math.isfinite(ns_per_frame)
            or ns_per_frame <= 0
            or not math.isfinite(one_core)
            or one_core <= 0
            or not math.isfinite(seconds)
            or seconds <= 0
            or frames <= 0
        ):
            raise SystemExit(
                f"PR101 resource baseline produced invalid metric for {case}"
            )
        entry: dict[str, Any] = {
            "nsPerFrame": ns_per_frame,
            "theoreticalOneCorePercentAt96k": one_core,
            "measurementSeconds": seconds,
            "measuredFrames": frames,
        }
        counter_match = BRIDGE_COUNTER_PATTERN.search(line)
        if counter_match:
            capture = int(counter_match.group("capture"))
            output_callbacks = int(counter_match.group("output"))
            if capture <= 0 or output_callbacks <= 0 or capture != output_callbacks:
                raise SystemExit(
                    f"PR101 bridge callback counters invalid for {case}: "
                    f"{capture}/{output_callbacks}"
                )
            entry["captureCallbacks"] = capture
            entry["outputCallbacks"] = output_callbacks
        metrics[case] = entry

    expected = (
        EXPECTED_RENDER_CASES
        if name == "renderKernel"
        else EXPECTED_BRIDGE_CASES
    )
    if set(metrics) != expected:
        raise SystemExit(
            f"PR101 {name} cases mismatch: expected {sorted(expected)}, "
            f"got {sorted(metrics)}"
        )

    rss_match = RSS_PATTERN.search(time_output)
    time_match = TIME_PATTERN.search(time_output)
    return {
        "cases": metrics,
        "maximumResidentSetBytes": (
            int(rss_match.group("bytes")) if rss_match else None
        ),
        "processTime": (
            {
                "realSeconds": float(time_match.group("real")),
                "userSeconds": float(time_match.group("user")),
                "systemSeconds": float(time_match.group("sys")),
            }
            if time_match
            else None
        ),
    }


def measure(binary_name: str, binary: Path, repeats: int) -> dict[str, Any]:
    runs: list[dict[str, Any]] = []
    for index in range(repeats):
        result = run_checked(["/usr/bin/time", "-l", str(binary)])
        parsed = parse_run(binary_name, result.stdout, result.stderr)
        parsed["repeat"] = index + 1
        runs.append(parsed)
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")

    case_names = sorted(runs[0]["cases"])
    aggregate: dict[str, dict[str, Any]] = {}
    for case in case_names:
        ns_samples = [run["cases"][case]["nsPerFrame"] for run in runs]
        core_samples = [
            run["cases"][case]["theoreticalOneCorePercentAt96k"]
            for run in runs
        ]
        aggregate[case] = {
            "sampleCount": len(ns_samples),
            "nsPerFrame": {
                "samples": ns_samples,
                "minimum": min(ns_samples),
                "median": statistics.median(ns_samples),
                "mean": statistics.fmean(ns_samples),
                "maximum": max(ns_samples),
                "populationStdDev": statistics.pstdev(ns_samples),
            },
            "theoreticalOneCorePercentAt96k": {
                "samples": core_samples,
                "minimum": min(core_samples),
                "median": statistics.median(core_samples),
                "mean": statistics.fmean(core_samples),
                "maximum": max(core_samples),
                "populationStdDev": statistics.pstdev(core_samples),
            },
        }

    rss_samples = [
        run["maximumResidentSetBytes"]
        for run in runs
        if run["maximumResidentSetBytes"] is not None
    ]
    return {
        "runs": runs,
        "aggregate": aggregate,
        "maximumResidentSetBytes": {
            "samples": rss_samples,
            "minimum": min(rss_samples) if rss_samples else None,
            "median": statistics.median(rss_samples) if rss_samples else None,
            "maximum": max(rss_samples) if rss_samples else None,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.repeats < 3:
        raise SystemExit("PR101 resource baseline requires at least 3 repeats")

    compiler = run_checked([CC, "--version"]).stdout.splitlines()[0]
    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr101-resource-") as tmp:
        binaries = compile_benchmarks(Path(tmp))
        measurements = {
            name: measure(name, binary, args.repeats)
            for name, binary in binaries.items()
        }

    report = {
        "schemaVersion": 1,
        "campaign": "PR101_CI_RESOURCE_BASELINE",
        "evidenceAuthority": "macOSCI",
        "purpose": "relative-baseline-and-trend-observation",
        "hardPerformanceThresholdsApplied": False,
        "repeats": args.repeats,
        "sampleRateHz": 96000,
        "bufferFrames": 512,
        "compiler": compiler,
        "platform": platform.platform(),
        "machine": platform.machine(),
        "githubSHA": os.environ.get("GITHUB_SHA"),
        "measurements": measurements,
        "resourceStabilityAccepted": False,
        "physicalAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "doesNotEstablish": [
            "hosted-CI performance SLA",
            "production Mac CPU budget",
            "long-duration memory-leak absence",
            "thermal stability",
            "real device recovery",
            "speaker safety",
            "physical acoustic acceptance",
        ],
    }

    args.report.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(report, indent=2, sort_keys=True)
    args.report.write_text(rendered + "\n")
    print("\n=== PR101 resource baseline report ===")
    print(rendered)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
