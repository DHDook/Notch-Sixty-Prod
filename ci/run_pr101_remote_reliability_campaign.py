#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CC = os.environ.get("CC", "clang")


def command(*parts: str) -> list[str]:
    return list(parts)


def c_compile(output: Path, *sources: str) -> list[str]:
    return [
        CC,
        "-std=c11",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-INotchSixty/Audio/Realtime",
        *sources,
        "-lm",
        "-o",
        str(output),
    ]


def run_step(argv: list[str]) -> dict:
    started = time.monotonic()
    result = subprocess.run(
        argv,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    elapsed = time.monotonic() - started
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    return {
        "command": argv,
        "exitCode": result.returncode,
        "elapsedSeconds": round(elapsed, 6),
    }


def scenario(requirement_id: str, title: str, commands: list[list[str]]) -> dict:
    print(f"\n=== PR101 deterministic scenario: {requirement_id} — {title} ===")
    steps = []
    for argv in commands:
        step = run_step(argv)
        steps.append(step)
        if step["exitCode"] != 0:
            return {
                "requirementID": requirement_id,
                "title": title,
                "status": "failed",
                "steps": steps,
            }
    return {
        "requirementID": requirement_id,
        "title": title,
        "status": "passed",
        "steps": steps,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr101-") as tmp:
        tmpdir = Path(tmp)
        scenarios = [
            scenario(
                "stereoTransport",
                "Stereo adaptive-clock transport",
                [
                    command(sys.executable, "ci/validate_pr70_stereo_adaptive_src.py"),
                    c_compile(
                        tmpdir / "pr69-adaptive-src",
                        "ci/validate_pr69_adaptive_src.c",
                        "NotchSixty/Audio/Realtime/N60AdaptiveSampleRate.c",
                    ),
                    command(str(tmpdir / "pr69-adaptive-src")),
                    c_compile(
                        tmpdir / "pr70-stereo-transport",
                        "ci/validate_pr70_stereo_transport_sim.c",
                        "NotchSixty/Audio/Realtime/N60AdaptiveSampleRate.c",
                    ),
                    command(str(tmpdir / "pr70-stereo-transport")),
                ],
            ),
            scenario(
                "semanticMultichannel",
                "Semantic N-channel adaptive-clock transport",
                [
                    command(sys.executable, "ci/validate_pr71_nchannel_adaptive_src.py"),
                    c_compile(
                        tmpdir / "pr71-nchannel-asrc",
                        "ci/validate_pr71_nchannel_adaptive_src.c",
                        "NotchSixty/Audio/Realtime/N60AdaptiveSampleRate.c",
                    ),
                    command(str(tmpdir / "pr71-nchannel-asrc")),
                ],
            ),
            scenario(
                "headphoneSpatialRuntime",
                "Headphone, binaural, and head-tracking integration",
                [
                    command(sys.executable, "ci/validate_pr66_head_tracking.py"),
                ],
            ),
            scenario(
                "audioUnitFaultContainment",
                "Audio Unit rack exchange and stage-fault containment",
                [
                    command(sys.executable, "ci/validate_pr84a_audio_unit_hardening.py"),
                    c_compile(
                        tmpdir / "pr84a-rack-exchange",
                        "ci/validate_pr82_audio_unit_rack_exchange.c",
                        "NotchSixty/Audio/Realtime/N60AudioUnitRackExchange.c",
                        "NotchSixty/Audio/Realtime/N60AudioUnitLiveRackBridge.c",
                    ),
                    command(str(tmpdir / "pr84a-rack-exchange")),
                    c_compile(
                        tmpdir / "pr84a-stage-fault-gate",
                        "ci/validate_pr84a_audio_unit_stage_fault_gate.c",
                        "NotchSixty/Audio/Realtime/N60AudioUnitRackExchange.c",
                        "NotchSixty/Audio/Realtime/N60AudioUnitLiveRackBridge.c",
                    ),
                    command(str(tmpdir / "pr84a-stage-fault-gate")),
                ],
            ),
            scenario(
                "roomTreatmentFailClosed",
                "Room Treatment transition and physical-output safety simulation",
                [
                    command(sys.executable, "ci/validate_pr76_treatment_transition.py"),
                    c_compile(
                        tmpdir / "pr76-treatment-transition",
                        "ci/validate_pr76_treatment_transition.c",
                    ),
                    command(str(tmpdir / "pr76-treatment-transition")),
                    command(sys.executable, "ci/validate_pr77_live_room_treatment.py"),
                    c_compile(
                        tmpdir / "pr77-live-room-treatment",
                        "ci/validate_pr77_live_room_treatment.c",
                    ),
                    command(str(tmpdir / "pr77-live-room-treatment")),
                ],
            ),
            scenario(
                "activeAcousticsFailClosed",
                "Feed-forward runtime disconnected-output boundary",
                [
                    command(sys.executable, "ci/validate_pr98_feedforward_runtime.py"),
                    command(sys.executable, "ci/audit_pr98_disconnected_boundary.py"),
                ],
            ),
        ]

    failed = [item for item in scenarios if item["status"] != "passed"]
    report = {
        "schemaVersion": 1,
        "campaign": "PR101_REMOTE_DETERMINISTIC_RELIABILITY",
        "evidenceAuthority": "deterministicSimulation",
        "scenarioCount": len(scenarios),
        "passedScenarioCount": len(scenarios) - len(failed),
        "failedScenarioCount": len(failed),
        "scenarios": scenarios,
        "physicalAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "doesNotEstablish": [
            "real device unplug/replug recovery",
            "real sleep/wake recovery",
            "prolonged thermal stability",
            "speaker safety",
            "physical acoustic acceptance",
            "live feed-forward ANC authorization",
        ],
    }

    rendered = json.dumps(report, indent=2, sort_keys=True)
    print("\n=== PR101 deterministic campaign report ===")
    print(rendered)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(rendered + "\n")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
