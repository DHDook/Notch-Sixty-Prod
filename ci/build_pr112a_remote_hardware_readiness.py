#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

GATES = ["H01", "H02", "H03", "H04", "H05", "H06", "H07", "H08"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    report = {
        "schemaVersion": 1,
        "campaign": "PR112A_REMOTE_HARDWARE_READINESS",
        "commitSHA": args.commit,
        "branch": args.branch,
        "evidenceAuthority": "remoteSoftware",
        "catalogGates": GATES,
        "remoteAcceptanceInfrastructureReady": True,
        "physicalAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "liveFeedForwardANCAuthorized": False,
        "mayMergeIntoMain": False,
        "physicalEvidenceSuppliedByCI": False,
        "doesNotEstablish": [
            "real device unplug/replug recovery",
            "real sleep/wake recovery",
            "physical thermal/endurance behavior",
            "speaker/emergency-mute safety",
            "calibrated microphone placement or identity",
            "physical acoustic improvement",
            "safe same-clock electrical reference wiring",
            "protected exposed-driver safety",
            "live speaker-connected feed-forward ANC safety",
            "production signing or App Store acceptance",
            "merge authorization",
        ],
    }

    if len(args.commit) < 7:
        raise SystemExit("PR112A readiness report requires a concrete commit SHA")
    if not args.branch.strip():
        raise SystemExit("PR112A readiness report requires a branch")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    # Fail closed if a future edit accidentally raises remote authority.
    for key in (
        "physicalAcceptanceComplete",
        "releaseAcceptanceComplete",
        "liveFeedForwardANCAuthorized",
        "mayMergeIntoMain",
        "physicalEvidenceSuppliedByCI",
    ):
        if report[key] is not False:
            raise SystemExit(f"PR112A remote authority escalated unexpectedly: {key}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
