#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

POLICY = ROOT / "NotchSixty/Audio/AmbientCompensation.swift"
ANALYZER = ROOT / "NotchSixty/Audio/AmbientFieldAnalyzer.swift"
MONITOR_H = ROOT / "NotchSixty/Audio/Realtime/N60AmbientMonitorBridge.h"
MONITOR_C = ROOT / "NotchSixty/Audio/Realtime/N60AmbientMonitorBridge.c"
BRIDGE_H = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h"
BRIDGE_C = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c"
KERNEL_H = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.h"
KERNEL_C = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c"
TRANSPORT = ROOT / "NotchSixty/Audio/CoreAudio/AmbientMonitorTransport.swift"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
CONTROLLER = ROOT / "NotchSixty/State/AmbientCompensationController.swift"
UI = ROOT / "NotchSixty/UI/ProductionActiveAcousticsWorkspace.swift"
ROOT_UI = ROOT / "NotchSixty/UI/ProductionRootView.swift"
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"
TESTS = ROOT / "NotchSixtyTests/AmbientCompensationTests.swift"
PROFILE_TESTS = ROOT / "NotchSixtyTests/RoomCorrectionProjectControllerTests.swift"
DOC = ROOT / "docs/PR89_AMBIENT_COMPENSATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR89 validation failed: {message}")


def text(path: Path) -> str:
    require(path.exists(), f"missing {path.relative_to(ROOT)}")
    return path.read_text(errors="ignore")


policy = text(POLICY)
analyzer = text(ANALYZER)
monitor_h = text(MONITOR_H)
monitor_c = text(MONITOR_C)
bridge_h = text(BRIDGE_H)
bridge_c = text(BRIDGE_C)
kernel_h = text(KERNEL_H)
kernel_c = text(KERNEL_C)
transport = text(TRANSPORT)
engine = text(ENGINE)
profiles = text(PROFILES)
controller = text(CONTROLLER)
ui = text(UI)
root_ui = text(ROOT_UI)
app = text(APP)
tests = text(TESTS)
profile_tests = text(PROFILE_TESTS)
doc = text(DOC).lower()

# Policy contract.
for token in (
    "enum AmbientActivityClass",
    "case quiet",
    "case normal",
    "case busy",
    "case party",
    "struct AmbientCompensationConfiguration",
    "hardMaximumLevelCompensationDB = 6.0",
    "maximumLevelCompensationDB = 3.0",
    "minimumSeparationConfidence = 0.75",
    "attackSeconds = 6.0",
    "releaseSeconds = 20.0",
    "struct AmbientCompensationPlanner",
    "maximumLowSupportDB = 2.0",
    "maximumPresenceSupportDB = 2.0",
    "maximumDetailSupportDB = 1.5",
    "activityHysteresisDB = 1.5",
    "struct AmbientCompensationEnvelope",
    "case playbackModelRequired",
    "case lowSeparationConfidence",
    "case nonstationaryTransient",
):
    require(token in policy, f"policy missing {token}")

require(
    "availableHeadroomDB" in policy
    and "minimumSeparationConfidence" in policy,
    "planner does not enforce headroom/confidence inputs",
)

# Existing playback-aware analyzer remains the separation authority.
for token in (
    "case modeledPlaybackSubtraction",
    "case playbackModelUnavailable",
    "AmbientPlaybackSourceReference",
    "acousticImpulseResponse",
):
    require(token in analyzer, f"ambient analyzer missing {token}")

# Realtime mic callback must remain copy-only.
for token in (
    "N60AmbientMonitorBridgeCreate",
    "N60AmbientMonitorBridgeProcessPlanar",
    "N60AmbientMonitorBridgeReadFrames",
    "N60AmbientMonitorIOProc",
    "_Atomic uint64_t writeIndex",
    "_Atomic uint64_t readIndex",
    "droppedFrames",
):
    require(token in monitor_c or token in monitor_h, f"monitor bridge missing {token}")

io_match = re.search(
    r"OSStatus N60AmbientMonitorIOProc\([\s\S]*?\n\}",
    monitor_c,
)
require(io_match is not None, "ambient monitor callback not found")
io_body = io_match.group(0).lower()
for forbidden in (
    "malloc(",
    "calloc(",
    "free(",
    "printf(",
    "fprintf(",
    "os_log",
    "mutex",
    "lock(",
    "fft",
    "vDSP",
):
    require(
        forbidden.lower() not in io_body,
        f"ambient IOProc contains forbidden realtime operation {forbidden}",
    )

# Ambient playback reference must be an independent SPSC consumer.
for token in (
    "N60_AMBIENT_REFERENCE_CAPACITY_FRAMES",
    "N60AmbientPlaybackReferenceFrame",
    "ambientReferenceWriteIndex",
    "ambientReferenceReadIndex",
    "N60RealtimeAudioBridgeReadAmbientReferenceFrames",
    "N60RealtimeAudioBridgeSetAmbientReferenceDemand",
):
    require(token in bridge_h or token in bridge_c, f"playback reference missing {token}")

require(
    "analysisReadIndex" in bridge_c
    and "ambientReferenceReadIndex" in bridge_c,
    "ambient reference incorrectly reuses production analysis consumer index",
)
require(
    "const float finalLeft = processed.left * gain;" in bridge_c
    and "const float finalRight = processed.right * gain;" in bridge_c
    and "ambientReferenceFrames" in bridge_c,
    "rendered reference is not captured from final stereo transport values",
)

# Dedicated DSP stage: no user EQ slots, protection remains downstream.
for token in (
    "N60_AMBIENT_COMPENSATION_BAND_COUNT 3u",
    "N60AmbientCompensationSnapshot",
    "ambientCompensationRuntime",
    "ambientCompensationLevelGain",
    "N60DSPGraphSnapshotSetAmbientCompensation",
    "N60BiquadFilterTypeLowShelf",
    "N60BiquadFilterTypePeaking",
    "N60BiquadFilterTypeHighShelf",
):
    require(token in kernel_h or token in kernel_c, f"DSP overlay missing {token}")

ambient_process = kernel_c.find("const float ambientLevelGain")
dynamics_process = kernel_c.find(
    "N60DynamicsProcessCoreStereoFrameWithMasterGain",
    ambient_process if ambient_process >= 0 else 0,
)
require(
    ambient_process >= 0 and dynamics_process > ambient_process,
    "ambient stage is not upstream of dynamics/protection",
)
require(
    "levelDB < 0.0 || levelDB > 6.0" in kernel_c
    and "lowSupportDB < 0.0 || lowSupportDB > 2.0" in kernel_c
    and "presenceSupportDB < 0.0 || presenceSupportDB > 2.0" in kernel_c
    and "detailSupportDB < 0.0 || detailSupportDB > 1.5" in kernel_c,
    "realtime snapshot setter lacks hard compensation bounds",
)

# Control plane / persistence.
for token in (
    "ambientCompensation: AmbientCompensationConfiguration?",
    "replaceSelectedSystemAmbientCompensation",
):
    require(token in profiles, f"Playback System persistence missing {token}")

for token in (
    "ambientCompensationRuntimeTarget",
    "ambientCompensationAvailableHeadroomDB",
    "replaceAmbientCompensationRuntimeTarget",
    "insufficientDigitalHeadroom",
    "attachAmbientCompensation(to: &graph)",
):
    require(token in engine, f"engine overlay integration missing {token}")

finalizer = re.search(
    r"private func applyAudioUnitRackLatency\([\s\S]*?\n    \}",
    engine,
)
require(finalizer is not None, "central graph finalizer missing")
require(
    "attachAmbientCompensation(to: &graph)" in finalizer.group(0),
    "ambient overlay is not centrally attached to every stereo graph rebuild",
)

# Live monitor transport/controller.
for token in (
    "final class AmbientMonitorTransport",
    "AudioDeviceCreateIOProcID",
    "N60AmbientMonitorIOProc",
    "readAvailableFrames",
):
    require(token in transport, f"input-only monitor transport missing {token}")

for token in (
    "final class AmbientCompensationController",
    "pollIntervalNanoseconds",
    "maximumHistoryFrames = 65_536",
    "playbackModelPositionID",
    "roomProjectMatchesSelectedMicrophone",
    "stableID == selected.uid",
    "inputChannelIndex",
    "playbackReferenceSampleRateMismatch",
    "analysis.separationMode",
    "== .microphoneOnly",
    "minimumSeparationConfidence",
    "captureQuietBaseline",
    "engine.ambientCompensationAvailableHeadroomDB",
    "Task.detached",
):
    require(token in controller, f"ambient controller missing {token}")

require(
    "running playback must never use a microphone-only" in controller.lower(),
    "running playback lacks explicit mic-only startup hold",
)

# Product/UI.
for token in (
    "let ambientCompensation: AmbientCompensationController",
    "ambientCompensation.prepareForUse()",
    "ambientCompensation.stopMonitoring()",
):
    require(token in app, f"product lifecycle missing {token}")

for token in (
    "ambient: product.ambientCompensation",
    "microphone: product.calibration",
    "projects: product.roomCorrectionProjects",
):
    require(token in root_ui, f"Active Acoustics route missing {token}")

for token in (
    'Text("Ambient Compensation")',
    "Set Current Room as Quiet Baseline",
    "Allow bounded level compensation",
    "Available Content Preset headroom",
    "Room Activity",
    "Separation Confidence",
    "Low Support",
    "Presence",
    "Detail",
    "holdReasonText",
):
    require(token in ui, f"Ambient Compensation UI missing {token}")

# Required tests.
for token in (
    "testPartyLevelCompensationCannotExceedAvailableHeadroom",
    "testAudiblePlaybackWithoutAcousticModelFailsClosed",
    "testNonstationaryEventIsRejected",
    "testEnvelopeRisesFasterThanItReleases",
    "testAmbientMonitorBridgePreservesUnreadFramesAndCountsDrops",
    "testAmbientMonitorBridgeWrapsWithoutReordering",
    "testAmbientGraphSnapshotAcceptsOnlyBoundedOverlay",
    "testAmbientGraphOverlayDoesNotConsumeUserEQSlots",
):
    require(token in tests, f"ambient tests missing {token}")

require(
    "testAmbientCompensationPersistsWithPlaybackSystemOnly"
    in profile_tests,
    "Playback System ambient persistence test missing",
)

for phrase in (
    "must never mistake",
    "known existing digital headroom",
    "attack/rise time",
    "release/fall time",
    "playback model unavailable",
    "control-plane only",
    "active quiet zone",
):
    require(phrase in doc, f"PR89 contract missing '{phrase}'")

print("PR89 ambient compensation architecture validation passed")
