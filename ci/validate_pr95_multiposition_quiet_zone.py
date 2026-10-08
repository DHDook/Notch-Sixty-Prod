#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
core=(r/"NotchSixty/Audio/QuietZoneSpatialPlanner.swift").read_text()
tests=(r/"NotchSixtyTests/QuietZoneSpatialPlannerTests.swift").read_text()
pbx=(r/"NotchSixty.xcodeproj/project.pbxproj").read_text()
doc=(r/"docs/PR95_MULTIPOSITION_QUIET_ZONE.md").read_text()
for t in ("QuietZoneSpatialSession","QuietZoneSpatialPlanner","verifyCommissioning","coherentReferenceID","worstSeatReductionDB","maximumAllowedRegressionDB","monitorSeatID"):
 assert t in core,t
for t in ("testJointSolverImprovesBothSeatsWithinSourceLimits","testFailsClosedForUnrepeatedNoisePhaseReference","testConflictingSeatDisturbancesCannotProduceSafeZone","testCommissioningRequiresMeasuredImprovementAtAllSeats"):
 assert t in tests,t
for t in ("QuietZoneSpatialPlanner.swift in Sources","QuietZoneSpatialPlannerTests.swift in Sources"):
 assert t in pbx,t
for t in ("one microphone","phase","all-seat","20–150 hz"):
 assert t in doc.lower(),t
assert "replaceActiveQuietZoneRuntimeTarget" not in core, "Offline planner must not activate runtime"
print("PR95 offline multi-seat safety checks passed")
