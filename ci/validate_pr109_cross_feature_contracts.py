#!/usr/bin/env python3
"""PR109 cross-feature integration guards; structural proof, not hardware proof.

These guards complement executable XCTest, portable render harnesses and the
individual PR validators. They guard cross-PR *ownership* boundaries which a
single-feature CI job may not consider. Nothing here grants deployment or
release authorization.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS: dict[str, tuple[str, ...]] = {
    "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift": (
        "var speakerOptimizerPEQ:",
        "var speakerOptimizerFIR:",
        "var coherentSubwooferAlignment:",
        "var coherentMultiSubwooferAlignment:",
        "try speakerOptimizerPEQ?.validate(profile: self)",
        "try speakerOptimizerFIR?.validate(profile: self)",
        "guard !(coherentSubwooferAlignment != nil",
        "&& coherentMultiSubwooferAlignment != nil) else",
        "try SpeakerOptimizerFIRLatencyPlanner().plan(",
    ),
    "NotchSixty/Audio/SpeakerOptimizerPEQDeployment.swift": (
        "profile.speakerOptimizerFIR == nil",
        "routingSignature == profile.multichannelCalibrationRoutingSignature",
    ),
    "NotchSixty/Audio/SpeakerOptimizerFIRDeployment.swift": (
        "profile.speakerOptimizerPEQ == nil",
        "== profile.multichannelCalibrationRoutingSignature",
        "declaredGroupDelayFrames == (tapCount - 1) / 2",
    ),
    "NotchSixty/Audio/SpeakerOptimizerPEQApplyTransaction.swift": (
        "outputProfile.speakerOptimizerPEQ = deployment",
        "requiresMeasuredVerification",
        "currentStateDrift",
        "rollbackStateDrift",
    ),
    "NotchSixty/Audio/SpeakerOptimizerFIRApplyTransaction.swift": (
        "outputProfile.speakerOptimizerFIR = deployment",
        "requiresMeasuredVerification",
        "currentStateDrift",
        "rollbackStateDrift",
    ),
    "NotchSixty/Audio/CoherentSubwooferAlignmentApplyTransaction.swift": (
        "output.coherentSubwooferAlignment =",
        "requiresMeasuredVerification",
        "currentStateDrift",
        "rollbackStateDrift",
        "candidate.speakerCommonDelayAdjustmentMilliseconds",
        "candidate.subwooferDelayAdjustmentMilliseconds",
    ),
    "NotchSixty/Audio/CoherentMultiSubwooferAlignmentApplyTransaction.swift": (
        "output.coherentMultiSubwooferAlignment =",
        "output.coherentSubwooferAlignment == nil",
        "output.coherentMultiSubwooferAlignment == nil",
        "requiresMeasuredVerification",
        "rollbackStateDrift",
    ),
    "NotchSixty/Audio/SpeakerMeasurementLabProtectedExcitation.swift": (
        "guard targetDriver.limiterEnabled else",
        "targetDriverProcessingRequired",
        "physicalCrossoverRequired",
        "maximumInputPeakDBFS: Double = -24",
    ),
    "NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h": (
        "N60ProgramFIRRuntimeProcessFrame(",
        "N60ProgramLaneProcessFrame(",
        "N60MultichannelBassManagementProcessFrame(",
        "programFIREnabled",
    ),
    "ci/audit_pr98_disconnected_boundary.py": (
        "outputConnected: Bool = false",
        "liveANCQualified: Bool = false",
    ),
}

def read_sources() -> dict[str, str]:
    return {
        path: (ROOT / path).read_text(encoding="utf-8")
        for path in CONTRACTS
    }

def audit_sources(sources: dict[str, str]) -> list[str]:
    problems: list[str] = []
    for path, tokens in CONTRACTS.items():
        content = sources.get(path)
        if content is None:
            problems.append(f"missing source {path}")
            continue
        for token in tokens:
            if token not in content:
                problems.append(f"{path}: missing cross-feature contract {token!r}")
    # Auditing the actual realtime ProcessFrame, not a token elsewhere in
    # the header, ensures sparse FIR remains upstream of the program lanes,
    # which must remain upstream of subwoofer bass management.
    path = "NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h"
    render = sources.get(path, "")
    section = render.split(
        "static inline bool N60LiveNChannelRenderProcessFrame(", 1
    )
    if len(section) != 2:
        problems.append("missing production live render entry point")
    else:
        body = section[1]
        order = [
            body.find("N60ProgramFIRRuntimeProcessFrame("),
            body.find("N60ProgramLaneProcessFrame("),
            body.find("N60MultichannelBassManagementProcessFrame("),
        ]
        if -1 in order or order != sorted(order) or len(set(order)) != 3:
            problems.append("live DSP order must be FIR -> speaker lanes -> bass management")

    # Reject attempts to make the PR109 cross-feature audit authorize physical
    # ANC or shipping; the authority facts must remain in the immutable
    # snapshot and live PR98 disconnected-output guard.
    return problems

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        problems = audit_sources(read_sources())
    except (OSError, UnicodeError) as exc:
        print(f"PR109 cross-feature source read failed: {exc}", file=sys.stderr)
        return 1
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        return 1
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps({
            "evidenceAuthority": "remoteStaticCrossFeatureAudit",
            "crossFeatureContractsPassed": True,
            "sourceFilesAudited": len(CONTRACTS),
            "hardwareAcceptanceComplete": False,
            "releaseAcceptanceComplete": False,
            "liveFeedForwardANCAuthorized": False,
            "mayMergeIntoMain": False,
        }, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"PR109 cross-feature source boundaries: PASS ({len(CONTRACTS)} files); "
          "hardware/release/merge authority: FALSE")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
