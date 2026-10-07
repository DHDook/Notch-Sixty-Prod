#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXCHANGE_H = ROOT / "NotchSixty/Audio/Realtime/N60AudioUnitRackExchange.h"
EXCHANGE_C = ROOT / "NotchSixty/Audio/Realtime/N60AudioUnitRackExchange.c"
SWITCHBOARD = ROOT / "NotchSixty/Audio/AudioUnitLiveRackSwitchboard.swift"
MUTATION = ROOT / "NotchSixty/Audio/AudioUnitRackMutation.swift"
HOST = ROOT / "NotchSixty/Audio/AudioUnitHostController.swift"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
PRODUCT = ROOT / "NotchSixty/NotchSixtyApp.swift"
STEREO_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioError.swift"
NCHANNEL_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
BINAURAL_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioBinauralHeadphoneTransportSession.swift"
UI = ROOT / "NotchSixty/UI/ProductionPluginWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/AudioUnitRackMutationTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR82_LIVE_AUDIO_UNIT_RACK_MUTATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR82 validation failed: {message}")


def function_body(text: str, name: str) -> str:
    start = text.find(name)
    require(start >= 0, f"missing function {name}")
    brace = text.find("{", start)
    require(brace >= 0, f"missing body for {name}")
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace:index + 1]
    raise SystemExit(f"PR82 validation failed: unterminated {name}")


exchange_h = EXCHANGE_H.read_text()
exchange_c = EXCHANGE_C.read_text()
switchboard = SWITCHBOARD.read_text()
mutation = MUTATION.read_text()
host = HOST.read_text()
engine = ENGINE.read_text()
product = PRODUCT.read_text()
stereo_session = STEREO_SESSION.read_text()
nchannel_session = NCHANNEL_SESSION.read_text()
binaural_session = BINAURAL_SESSION.read_text()
ui = UI.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text().lower().replace("**", "")

for token in (
    "N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT 3u",
    "N60AudioUnitRackExchangeFindWritableSlot",
    "N60AudioUnitRackExchangePublish",
    "N60AudioUnitRackExchangeSlotIsReclaimable",
    "N60AudioUnitRackExchangeGetStatus",
    "N60AudioUnitRackExchangeAtomicsAreLockFree",
    "N60AudioUnitRackExchangeProcess",
):
    require(token in exchange_h, f"exchange header missing {token}")

for token in (
    "_Atomic uint32_t readers",
    "_Atomic uint32_t activeSlot",
    "_Atomic uint32_t requestedSlot",
    "_Atomic uint64_t renderedGeneration",
    "_Atomic uint64_t transitionFailureCount",
    "_Atomic uint32_t transitionPosition",
    "atomic_is_lock_free",
    "scratchOld",
    "scratchNew",
    "oldGain = 1.0f - alpha",
):
    require(token in exchange_c, f"exchange implementation missing {token}")

render = function_body(exchange_c, "bool N60AudioUnitRackExchangeProcess")
for forbidden in (
    "malloc(",
    "calloc(",
    "realloc(",
    "free(",
    "pthread_mutex",
    "dispatch_",
    "printf(",
    "fprintf(",
    "AVAudioUnit",
    "fullState",
):
    require(forbidden not in render,
            f"exchange render contains forbidden realtime token {forbidden}")

for token in (
    "final class AudioUnitLiveRackSwitchboard",
    "runtimesBySlot",
    "N60AudioUnitRackExchangeFindWritableSlot",
    "N60AudioUnitRackExchangePublish",
    "N60AudioUnitRackExchangeSlotIsReclaimable",
    "renderedGeneration",
    "transitionFailureCount",
    "latencyChangeRequiresRestart",
    "reclaimInactiveRuntimes",
):
    require(token in switchboard, f"switchboard missing {token}")

for token in (
    "enum AudioUnitRackMutation",
    "case install",
    "case remove",
    "case move",
    "case setBypassed",
    "case setWetDryMix",
    "case setOpaqueFullState",
    "AudioUnitRackMutationCandidate",
    "seamlessCrossfade",
    "controlledRestart",
):
    require(token in mutation, f"mutation model missing {token}")

candidate_body = function_body(host, "func makeMutationCandidate")
require("var configuration = try configuration(" in candidate_body,
        "candidate builder is not working on a local configuration")
require("backend.prepare(" in candidate_body,
        "candidate builder does not re-run offline preparation")
require("AudioUnitLiveRackRuntime.build" in candidate_body,
        "candidate builder does not construct a fresh immutable runtime")
require("rackConfiguration =" not in candidate_body,
        "candidate builder mutates committed rack state before activation")
require("quarantineComponent(" not in candidate_body,
        "failed candidate preparation must not quarantine current live state")

commit_body = function_body(host, "func commitMutationCandidate")
require("rackConfiguration = candidate.configuration" in commit_body,
        "candidate commit does not update rack configuration")
require("attachFaultMonitoring" in commit_body,
        "activated candidate runtime does not receive fault monitoring")

for token in (
    "private var stagedAudioUnitRack: AudioUnitLiveRackSwitchboard?",
    "audioUnitRackProcessingFormatForMutation",
    "activateAudioUnitRackMutation",
    "controlledRestartForAudioUnitRackMutation",
    "switchboard.transition",
    "previousSwitchboard",
    "stop()",
    "start(resetProcessingSessionCounters: false)",
):
    require(token in engine, f"engine mutation policy missing {token}")

activation_body = function_body(engine, "func activateAudioUnitRackMutation")
require(
    activation_body.find("switchboard.latencyFrames")
    < activation_body.find("switchboard.transition"),
    "same-latency guard must precede live switchboard transition"
)
require("controlledRestartForAudioUnitRackMutation" in activation_body,
        "latency-changing candidate lacks controlled restart")

for source, label in (
    (stereo_session, "stereo"),
    (nchannel_session, "semantic"),
    (binaural_session, "Virtual Speakers"),
):
    require("AudioUnitLiveRackSwitchboard?" in source,
            f"{label} session does not retain switchboard")
    require("AudioUnitLiveRackRuntime?" not in source,
            f"{label} session still owns a single runtime instead of switchboard")

product_mutation = function_body(product, "func mutateAudioUnitRack")
for token in (
    "audioUnitRackProcessingFormatForMutation",
    "makeMutationCandidate",
    "activateAudioUnitRackMutation",
    "commitMutationCandidate",
):
    require(token in product_mutation,
            f"product mutation transaction missing {token}")
require(
    product_mutation.find("makeMutationCandidate")
    < product_mutation.find("activateAudioUnitRackMutation")
    < product_mutation.find("commitMutationCandidate"),
    "product transaction must prepare -> activate -> commit"
)

# PR82 itself intentionally stopped at an engine-only mutation surface. Preserve
# those original UI-scope assertions on the PR82 branch, but do not make an
# inherited engine validator forbid PR83+ from deliberately consuming that
# surface. PR83 has its own stricter UI/editor boundary validator.
pr83_or_later = (ROOT / "docs/PR83_PLUGIN_RACK_UX.md").exists()
if not pr83_or_later:
    require('Label("Add Plug-in", systemImage: "plus")' in ui,
            "Add Plug-in affordance disappeared")
    require(".disabled(true)" in ui,
            "PR82 must not enable rack editing UI")
    for forbidden in ("requestViewController", "NSViewController", "viewConfiguration"):
        require(forbidden not in ui,
                f"vendor UI crossed PR82 scope with {forbidden}")

for token in (
    "testSwitchboardCrossfadesEqualLatencyGenerations",
    "testSwitchboardRejectsLatencyChangeWithoutRestart",
    "testMutationCandidateDoesNotCommitUntilExplicitCommit",
    "testReorderPreservesSlotIdentityAndDefersCommit",
    "testFailedCandidatePreparationLeavesCurrentRackUntouched",
):
    require(token in tests, f"PR82 XCTest coverage missing {token}")

for token in (
    "N60AudioUnitRackExchange.c in Sources",
    "AudioUnitLiveRackSwitchboard.swift in Sources",
    "AudioUnitRackMutation.swift in Sources",
    "AudioUnitRackMutationTests.swift in Sources",
):
    require(token in project, f"Xcode target wiring missing {token}")

for phrase in (
    "same total latency -> lock-free live crossfade",
    "changed latency    -> controlled transport restart",
    "only after successful restart",
    "does not quarantine or alter the currently playing instance",
    "full user-facing tail-drain semantics",
    "add plug-in stays disabled",
):
    require(phrase in doc, f"architecture doc missing '{phrase}'")

require((ROOT / "ci/validate_pr82_audio_unit_rack_exchange.c").exists(),
        "portable PR82 exchange simulator missing")
require((ROOT / "ci/validate_pr77_live_room_treatment.py").exists(),
        "inherited PR77 safety validation missing")
require((ROOT / "ci/validate_pr77_live_room_treatment.c").exists(),
        "inherited PR77 physical simulation missing")

print("PR82 transactional live Audio Unit rack mutation validation passed")
