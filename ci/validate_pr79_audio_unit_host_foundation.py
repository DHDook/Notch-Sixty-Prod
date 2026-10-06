#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FOUNDATION = ROOT / "NotchSixty/Audio/AudioUnitHostFoundation.swift"
CONTROLLER = ROOT / "NotchSixty/Audio/AudioUnitHostController.swift"
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
PRODUCT = ROOT / "NotchSixty/NotchSixtyApp.swift"
UI = ROOT / "NotchSixty/UI/ProductionPluginWorkspace.swift"
ROOT_VIEW = ROOT / "NotchSixty/UI/ProductionRootView.swift"
TESTS = ROOT / "NotchSixtyTests/AudioUnitHostFoundationTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR79_AUDIO_UNIT_HOST_FOUNDATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR79 validation failed: {message}")


foundation = FOUNDATION.read_text()
controller = CONTROLLER.read_text()
profiles = PROFILES.read_text()
product = PRODUCT.read_text()
ui = UI.read_text()
root_view = ROOT_VIEW.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()

for token in (
    "AudioUnitComponentIdentity",
    "AudioUnitRackConfiguration",
    "defaultSlotCount = 4",
    "maximumSlotCount = 8",
    "maximumChannelCount = 32",
    "maximumOpaqueStateBytes = 8 * 1_024 * 1_024",
    "maximumTotalOpaqueStateBytes = 32 * 1_024 * 1_024",
    "AudioUnitQuarantineRegistry",
    "AudioUnitProbeResult",
    "maximumLatencySeconds = 10.0",
    "maximumTailSeconds = 120.0",
    "AudioUnitRackPreparationPlanner",
    "latencyMatchedBypass",
    "dryCompensationFrames",
    "missingBypassLatency",
):
    require(token in foundation, f"host model missing {token}")

for token in (
    "AVAudioUnitComponentManager.shared()",
    "kAudioUnitType_Effect",
    "kAudioUnitType_MusicEffect",
    "supportsNumberInputChannels",
    "passesAUVal",
    "isSandboxSafe",
    "AudioUnitHostProbeBackend",
    "AudioUnitComponentLifecycleState",
    "case probing",
    "case prepared",
    "case quarantined",
    "installComponent",
    "setBypassed",
    "executionPlan",
):
    require(token in controller, f"host controller missing {token}")

combined_host = foundation + "\n" + controller
for forbidden in (
    "AVAudioUnit.instantiate(",
    "AUAudioUnit.instantiate(",
    "allocateRenderResources(",
    "deallocateRenderResources(",
    "internalRenderBlock",
    "renderBlock",
    "AudioDeviceCreateIOProcID",
    "N60LiveNChannelRenderProcessFrame",
    "N60RealtimeAudioBridge",
):
    require(forbidden not in combined_host,
            f"PR79 crosses live/instantiation boundary with {forbidden}")

content_start = profiles.index("struct ContentPresetState")
system_start = profiles.index("struct PlaybackSystemControlState")
content_section = profiles[content_start:system_start]
require("audioUnitRack: AudioUnitRackConfiguration" in content_section,
        "Audio Unit rack is not Content Preset state")
require("decodeIfPresent" in content_section and "audioUnitRack" in content_section,
        "legacy Content Preset rack migration is missing")

playback_system_start = profiles.index("struct PlaybackSystemState")
playback_system_end = profiles.index("struct PlaybackSystemProfile")
system_state_section = profiles[playback_system_start:playback_system_end]
require("audioUnitRack" not in system_state_section,
        "Audio Unit rack must not be owned by Playback System state")

for token in (
    "let audioUnitHost: AudioUnitHostController",
    "audioUnitHost.rackConfiguration",
    "replaceRackConfiguration(state.audioUnitRack)",
):
    require(token in profiles, f"Content Preset integration missing {token}")

require("let audioUnitHost: AudioUnitHostController" in product,
        "ProductController does not own the Audio Unit host")
require("audioUnitHost: audioUnitHost" in product,
        "ProductProfileController does not share the product Audio Unit host")

for token in (
    "host.scan(format: processingFormat)",
    "Compatibility Catalog",
    "NOT IN LIVE PATH",
    'Label("Add Plug-in", systemImage: "plus")',
    ".disabled(true)",
    "Rack state follows the selected Content Preset",
):
    require(token in ui, f"Plug-ins workspace missing {token}")

for forbidden in (
    "AVAudioUnit.instantiate(",
    "AUAudioUnit.instantiate(",
    "requestRoomTreatmentArm(",
):
    require(forbidden not in ui,
            f"Plug-ins UI crosses a prohibited boundary with {forbidden}")

for token in (
    'case dashboard',
    'case speakers',
    'case activeAcoustics',
    'case plugins',
    'Section("PLAYBACK")',
    'Section("SYSTEM")',
    'Section("EXTENSIONS")',
    'ProductionActiveAcousticsWorkspace(engine: engine)',
):
    require(token in root_view, f"inherited PR78 navigation invariant missing {token}")
require('case activeCrossover' not in root_view,
        "legacy Active Crossover navigation case returned")

require("host: product.audioUnitHost" in root_view,
        "production Plug-ins route is not wired to the product host")

for token in (
    "testSystemCatalogMetadataDiscoveryIsStable",
    "testRackRoundTripPreservesOpaqueStateAndLatencyMetadata",
    "testLegacyContentPresetWithoutRackDecodesToEmptyRack",
    "testActiveExecutionPlanAggregatesLatencyTailAndWetDryDelay",
    "testMissingComponentFallsBackOnlyWithKnownLatency",
    "testMissingComponentWithoutKnownLatencyFailsClosed",
    "testUnsupportedSurroundLayoutUsesKnownLatencyMatchedBypass",
    "testQuarantinedComponentCannotProcess",
    "testHostControllerScanInstallProbeAndEnableLifecycle",
    "testProbeFailureQuarantinesComponent",
    "testOpaqueStateSizeIsBounded",
):
    require(token in tests, f"PR79 XCTest coverage missing {token}")

for token in (
    "AudioUnitHostFoundation.swift in Sources",
    "AudioUnitHostController.swift in Sources",
    "AudioUnitHostFoundationTests.swift in Sources",
):
    require(token in project, f"Xcode target wiring missing {token}")

normalized_doc = doc.lower()
for phrase in (
    "playback/content state",
    "does not put third-party audio units in the realtime render graph",
    "symmetric channel layouts only",
    "latency-matched dry bypass",
    "quarantine",
    "no component is opened during discovery",
    "future live-host pr",
):
    require(phrase in normalized_doc,
            f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr78_ui_information_architecture.py").exists(),
        "inherited PR78 UI validation is missing")
require((ROOT / "ci/validate_pr77_live_room_treatment.py").exists(),
        "inherited PR77 safety validation is missing")
require((ROOT / "ci/validate_pr77_live_room_treatment.c").exists(),
        "inherited PR77 physical simulation is missing")

print("PR79 Audio Unit host foundation structural validation passed")
