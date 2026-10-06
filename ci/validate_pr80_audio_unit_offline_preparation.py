#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PREP = ROOT / "NotchSixty/Audio/AudioUnitOfflinePreparation.swift"
FOUNDATION = ROOT / "NotchSixty/Audio/AudioUnitHostFoundation.swift"
CONTROLLER = ROOT / "NotchSixty/Audio/AudioUnitHostController.swift"
UI = ROOT / "NotchSixty/UI/ProductionPluginWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/AudioUnitOfflinePreparationTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR80_AUDIO_UNIT_OFFLINE_PREPARATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR80 validation failed: {message}")


prep = PREP.read_text()
foundation = FOUNDATION.read_text()
controller = CONTROLLER.read_text()
ui = UI.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text().lower().replace("**", "")

for token in (
    "AudioUnitOfflinePreparationReport",
    "AudioUnitOfflinePreparing",
    "SystemAudioUnitOfflinePreparationBackend",
    "AVAudioUnit.instantiate",
    "setFormat",
    "maximumFramesToRender",
    "fullState",
    "allocateRenderResources",
    "internalRenderBlock",
    "AURenderPullInputBlock",
    "deallocateRenderResources",
    "au.reset()",
    "latencyStableAcrossReset",
    "tailStableAcrossReset",
    "renderResourcesReleased",
):
    require(token in prep, f"offline preparer missing {token}")

require("slotProbes: [UUID: AudioUnitProbeResult]" in foundation,
        "rack planner does not accept per-slot preparation evidence")
require("slotProbes[slot.id] ?? probesByID[component]" in foundation,
        "rack planner does not prefer exact slot preparation evidence")

for token in (
    "probesBySlotID",
    "offlineReportsBySlotID",
    "prepareSlotOffline",
    "offlinePreparationReport",
    "setOpaqueFullState",
    "probesBySlotID.removeValue(forKey: slotID)",
    "offlineReportsBySlotID.removeValue(forKey: slotID)",
    "slotProbes: probesBySlotID",
):
    require(token in controller, f"slot-specific controller policy missing {token}")

# Instantiation and render-resource APIs must be isolated to the offline preparer.
restricted = (
    "AVAudioUnit.instantiate(",
    ".allocateRenderResources()",
    ".internalRenderBlock",
)
for source in (ROOT / "NotchSixty").rglob("*.swift"):
    text = source.read_text()
    if source == PREP:
        continue
    for token in restricted:
        require(token not in text,
                f"{token} escaped offline preparer into {source.relative_to(ROOT)}")

# Production realtime/core paths must know nothing about Audio Units.
for relative in (
    "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c",
    "NotchSixty/Audio/Realtime/N60LiveNChannelBridge.h",
    "NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h",
    "NotchSixty/Audio/AudioIOEngine.swift",
):
    text = (ROOT / relative).read_text()
    require("AVAudioUnit" not in text and "AUAudioUnit" not in text,
            f"Audio Unit object leaked into production path {relative}")
    require("AudioUnitOfflinePreparation" not in text,
            f"offline preparer leaked into production path {relative}")

# PR79 rack/product safety remains in force even though PR80 legitimately
# crosses the instantiation boundary in one isolated file.
for token in (
    "defaultSlotCount = 4",
    "maximumSlotCount = 8",
    "maximumChannelCount = 32",
    "maximumLatencySeconds = 10.0",
    "maximumTailSeconds = 120.0",
    "latencyMatchedBypass",
    "missingBypassLatency",
):
    require(token in foundation, f"inherited host policy missing {token}")

require('Label("Add Plug-in", systemImage: "plus")' in ui,
        "Plug-ins UI lost Add Plug-in affordance")
require(".disabled(true)" in ui,
        "Add Plug-in must remain disabled in PR80")
for token in (
    "NSViewController",
    "requestViewController",
    "viewConfiguration",
    "AVAudioUnit.instantiate(",
):
    require(token not in ui,
            f"PR80 UI crossed vendor/live boundary with {token}")
require("NOT IN LIVE PATH" in ui,
        "Plug-ins UI no longer declares live-path boundary")

for token in (
    "testAppleLowPassCanInstantiateAllocateRenderResetAndTearDownOffline",
    "testCapturedAppleStateCanRoundTripThroughFreshOfflineInstance",
    "testSameComponentCanHaveDifferentPreparedLatencyPerSlot",
    "testChangingOpaqueStateInvalidatesOnlyThatSlotPreparation",
    "testOfflineStateRestoreFailureQuarantinesAndForcesBypass",
    "testReportRejectsUnreleasedResourcesAndNondeterministicLatency",
):
    require(token in tests, f"PR80 XCTest coverage missing {token}")

for token in (
    "AudioUnitOfflinePreparation.swift in Sources",
    "AudioUnitOfflinePreparationTests.swift in Sources",
):
    require(token in project, f"Xcode target wiring missing {token}")

for phrase in (
    "real audio units may now be instantiated",
    "entirely off the realtime production path",
    "per-slot preparation",
    "changing a slot's opaque state",
    "render resources are no longer allocated",
    "not in live path",
    "future pr81",
):
    require(phrase in doc, f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr77_live_room_treatment.py").exists(),
        "inherited PR77 safety validation missing")
require((ROOT / "ci/validate_pr77_live_room_treatment.c").exists(),
        "inherited PR77 physical simulation missing")

print("PR80 Audio Unit offline preparation structural validation passed")
