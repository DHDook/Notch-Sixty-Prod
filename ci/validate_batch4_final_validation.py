#!/usr/bin/env python3
"""Batch 4 portable cross-feature interface, safety and handoff source gate.

No source-contract check replaces an Apple Silicon full XCTest or a
physical PR112 campaign. Actual head is validated in the final manifest.
"""
import json
from pathlib import Path

R = Path(__file__).resolve().parents[1]
paths = {
    "abx": "NotchSixty/Audio/Routing/BlindABXValidation.swift",
    "ui": "NotchSixty/UI/ProductionBlindListeningWorkspace.swift",
    "test": "NotchSixtyTests/BlindABXValidationTests.swift",
    "root": "NotchSixty/UI/ProductionRootView.swift",
    "guide": "NotchSixty/UI/ProductionUserGuideView.swift",
    "project": "NotchSixty.xcodeproj/project.pbxproj",
    "hand": "docs/BATCH4_FINAL_PRODUCT_HANDOFF.md",
    "manifest": "ci/build_batch4_final_handoff.py",
    "workflow": ".github/workflows/batch4-final-product-validation.yml",
}
texts = {key: (R / file).read_text() for key, file in paths.items()}

def require(condition, message):
    if not condition:
        raise AssertionError("Batch 4 regression: " + message)

for token in (
    "struct BlindABXSession", "currentHiddenXWasB",
    "Bool.random()", "heardCurrentX", "recordXPlayback",
    "exactOneSidedPValue", "BlindABXPreflight",
    "physicalAcceptanceComplete: false",
    "releaseAcceptanceComplete: false", "mayMergeIntoMain: false",
):
    require(token in texts["abx"], "independent blind and authority " + token)
for token in (
    "AVAudioFile(forReading:", "AVAudioPlayer(contentsOf:",
    "FileManager.default.temporaryDirectory", "clearTempFiles()",
    "startAccessingSecurityScopedResource()",
    "Stop live processing", "engine.lifecycleState == .idle",
    "RMS agreement within 0.10 dB", "20 * log10",
    "BlindABXPreflight.reasons", "volume = 0.2",
    "exportEvidence()", "fileExporter(",
):
    require(token in texts["ui"], "safe local ABX experience " + token)
for token in (
    "testABXKeepsXHiddenUntilCompletionAndRefusesEarlyExport",
    "testExactBinomialTailCalculationsAndCounts",
    "testIndependentRandomAssignmentsNotFixedBalance",
    "testABXPreflightProtectsRateLevelsLengthAndAlignment",
    "testABXExportIsRoundTrippableAndExposesNoHardwareAuthority",
):
    require(token in texts["test"], "actual ABX XCTest missing " + token)
require("case blindListening" in texts["root"]
        and "ProductionBlindListeningWorkspace(engine: engine)" in texts["root"],
        "real production Tools route absent")
require('id: "blind-listening"' in texts["guide"]
        and 'case .blindListening: return "blind-listening"' in texts["guide"],
        "in-app user guide missing or not searchable")
for name in ("BlindABXValidation.swift",
             "ProductionBlindListeningWorkspace.swift",
             "BlindABXValidationTests.swift"):
    require(texts["project"].count(name) >= 4,
            "Xcode PBX target missing " + name)
for token in (
    "H01", "H08", "384 kHz", "Core Audio", "headphone",
    "source rights", "App Store", "owner", "draft", "ABX",
):
    require(token.lower() in texts["hand"].lower(),
            "final handoff missing key safety context " + token)
for flag in ("physicalAcceptanceComplete", "mayMergeIntoMain",
             "productionAppleSigningComplete", "externalLegalIPReviewComplete",
             "liveFeedForwardANCAuthorized"):
    require(flag in texts["manifest"],
            "remote manifest lacks explicit false authority: " + flag)
require("full_xctest.ok" not in texts["workflow"] or
        "build_batch4_final_handoff.py" in texts["workflow"],
        "invalid gate marker provenance")
for old in (
    "N60RealtimeAudioBridgeConfigure", "N60RenderKernelConfigure",
    "AudioObjectSetPropertyData(", "CoreAudioBinauralHeadphoneTransportSession("
):
    require(old not in texts["abx"] and old not in texts["ui"],
            "ABX must not mutate live render or physical audio routing")
print("Batch 4 cross-feature UX, local ABX, provenance and no-release-authority: PASS")
