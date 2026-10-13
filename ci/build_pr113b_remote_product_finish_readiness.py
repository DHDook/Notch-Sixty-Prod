#!/usr/bin/env python3
"""Build the machine-readable PR113B remote product-finish readiness artifact."""
import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--commit", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    payload = {
        "schema": "PR113B_REMOTE_PRODUCT_FINISH_READINESS",
        "schemaVersion": 1,
        "commit": args.commit,
        "branch": args.branch,
        "remoteProductFinishComplete": True,
        "abComparisonAvailable": True,
        "measuredLevelMatchAvailable": True,
        "backupRestoreAvailable": True,
        "fullFidelityMeasurementExportAvailable": True,
        "safeLaunchRecoveryAvailable": True,
        "headroomAssistantAvailable": True,
        "gettingStartedCoverageComplete": True,
        "backupDoesNotCarryPhysicalAcceptanceAuthority": True,
        "recoveryStateExcludedFromGeneralBackup": True,
        "measurementExportIsReadOnly": True,
        "headroomAssistantIsAdvisoryAndExplicitApply": True,
        "physicalAcceptanceComplete": False,
        "releaseAcceptanceComplete": False,
        "liveFeedForwardANCAuthorized": False,
        "mayMergeIntoMain": False,
        "physicalEvidenceSuppliedByCI": False,
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
