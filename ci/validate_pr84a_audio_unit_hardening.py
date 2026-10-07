#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OFFLINE = ROOT / "NotchSixty/Audio/AudioUnitOfflinePreparation.swift"
HOST = ROOT / "NotchSixty/Audio/AudioUnitHostController.swift"
LIVE = ROOT / "NotchSixty/Audio/AudioUnitLiveRackRuntime.swift"
LIVE_BRIDGE = ROOT / "NotchSixty/Audio/Realtime/N60AudioUnitLiveRackBridge.h"
EXCHANGE_H = ROOT / "NotchSixty/Audio/Realtime/N60AudioUnitRackExchange.h"
EXCHANGE_C = ROOT / "NotchSixty/Audio/Realtime/N60AudioUnitRackExchange.c"
EXCHANGE_TEST = ROOT / "ci/validate_pr82_audio_unit_rack_exchange.c"
GATE_TEST = ROOT / "ci/validate_pr84a_audio_unit_stage_fault_gate.c"
OFFLINE_TESTS = ROOT / "NotchSixtyTests/AudioUnitOfflinePreparationTests.swift"
LIVE_TESTS = ROOT / "NotchSixtyTests/AudioUnitLiveRackRuntimeTests.swift"
MUTATION_TESTS = ROOT / "NotchSixtyTests/AudioUnitRackMutationTests.swift"
DOC = ROOT / "docs/PR84A_AUDIO_UNIT_HARDENING.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR84A validation failed: {message}")


def function_body_after(text: str, anchor: str, name: str) -> str:
    scope = text.find(anchor)
    require(scope >= 0, f"missing scope {anchor}")
    start = text.find(name, scope)
    require(start >= 0, f"missing function {name} after {anchor}")
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
    raise SystemExit(f"PR84A validation failed: unterminated {name}")


offline = OFFLINE.read_text()
host = HOST.read_text()
live = LIVE.read_text()
live_bridge = LIVE_BRIDGE.read_text()
exchange_h = EXCHANGE_H.read_text()
exchange_c = EXCHANGE_C.read_text()
exchange_test = EXCHANGE_TEST.read_text()
offline_tests = OFFLINE_TESTS.read_text()
live_tests = LIVE_TESTS.read_text()
mutation_tests = MUTATION_TESTS.read_text()
doc = DOC.read_text().lower().replace("**", "")

for token in (
    "enum AudioUnitOpaqueStateCodec",
    "decodeDictionary",
    "encodeDictionary",
    "maximumOpaqueStateBytes",
    "func validate(\n        for format: AudioUnitRackProcessingFormat",
    "rmsByChannel.count == format.channelCount",
    "maximumAbsoluteSample.isFinite",
    "stateRecaptured == hasCapturedState",
    "probe.supportsFullState == hasCapturedState",
):
    require(token in offline, f"offline hardening missing {token}")

for token in (
    "AudioUnitOpaqueStateCodec.validate(slot.opaqueFullState)",
    "AudioUnitOpaqueStateCodec.validate(\n                    slot.opaqueFullState",
    "candidatePreparationFailed",
    "liveBuildFailureSlot",
    "forLiveBuildError",
):
    require(token in host, f"host state/live-build hardening missing {token}")

for token in (
    "case liveInvalidLatency",
    "case liveInvalidTail",
    "enum AudioUnitLiveRackControlPlaneIssue",
    "enum AudioUnitLiveTimingValidator",
    "seconds.isFinite",
    "AudioUnitProbeResult.maximumLatencySeconds",
    "AudioUnitProbeResult.maximumTailSeconds",
    "func controlPlaneHealthIssue()",
    "func controlPlaneHealthIssues()",
    "reportedControlPlaneFaultSlots",
    "issue.description",
    "case stageFaultGateAllocationFailed",
    "N60AudioUnitStageFaultGateCreate",
    "N60AudioUnitStageFaultGateDestroy",
    "N60AudioUnitStageFaultGateTrip",
    "N60AudioUnitStageFaultGateIsTripped",
    "struct AudioUnitLiveRenderWatchdog",
    "severeOverrunMultiplier = 4.0",
    "minimumBudgetSeconds = 0.010",
    "consecutiveOverrunLimit = 3",
    "mach_absolute_time()",
    "N60AudioUnitLiveRackFaultCPUOverrun",
):
    require(token in live, f"live hardening missing {token}")

require(
    "N60AudioUnitLiveRackFaultCPUOverrun = 4" in live_bridge,
    "live fault ABI missing CPU-overrun reason",
)

for token in (
    "N60AudioUnitStageFaultGateCreate",
    "N60AudioUnitStageFaultGateDestroy",
    "N60AudioUnitStageFaultGateTrip",
    "N60AudioUnitStageFaultGateIsTripped",
):
    require(token in exchange_h, f"stage fault gate header missing {token}")

for token in (
    "struct N60AudioUnitStageFaultGate",
    "_Atomic bool tripped",
    "atomic_is_lock_free(&gate->tripped)",
    "memory_order_release",
    "memory_order_acquire",
):
    require(token in exchange_c, f"stage fault gate implementation missing {token}")

require(GATE_TEST.exists(), "portable stage fault gate proof missing")
for token in (
    "N60AudioUnitLiveRackProcessorHasFault(processor)",
    "N60AudioUnitLiveRackProcessorHasFault(\n            &requested->processor)",
):
    require(
        token in exchange_c,
        f"generation exchange missing candidate fault rejection {token}",
    )
for token in (
    "recordFault",
    "softFaultLatch",
    "fault-latched candidate replaced active generation",
):
    require(
        token in exchange_test,
        f"exchange simulator missing fault-latched candidate coverage {token}",
    )

stage_render = function_body_after(
    live,
    "final class AudioUnitLiveProcessStage",
    "func process("
)
require(
    "N60AudioUnitStageFaultGateIsTripped(faultGate)" in stage_render,
    "live process stage does not fail closed through the atomic gate",
)
require(
    "N60AudioUnitStageFaultGateTrip(faultGate)" in stage_render,
    "live process stage does not latch realtime render faults",
)
require(
    "renderWatchdog.observe" in stage_render
    and "N60AudioUnitLiveRackFaultCPUOverrun" in stage_render,
    "live process stage does not fail closed on sustained CPU abuse",
)
for forbidden in (
    "controlPlaneHealthIssue",
    "withAUAudioUnit",
    ".latency",
    ".tailTime",
    "DispatchQueue",
    "PropertyListSerialization",
    "AudioUnitOpaqueStateCodec",
):
    require(
        forbidden not in stage_render,
        f"realtime stage process contains control-plane token {forbidden}",
    )

render = function_body_after(
    live,
    "final class AudioUnitLiveRackRuntime",
    "func process("
)
for forbidden in (
    "controlPlaneHealthIssues",
    "controlPlaneHealthIssue",
    "withAUAudioUnit",
    ".latency",
    ".tailTime",
    "DispatchQueue",
    "PropertyListSerialization",
    "AudioUnitOpaqueStateCodec",
):
    require(
        forbidden not in render,
        f"realtime runtime process contains control-plane token {forbidden}",
    )

for token in (
    "testOpaqueStateCodecRejectsMalformedAndNonDictionaryState",
    "testPreparationReportRejectsForgedNonFiniteMetrics",
    "testMalformedStoredStateQuarantinesBeforeBackendPreparation",
    "testClearingQuarantineStillRequiresFreshPreparation",
    "testDeterministicFormatMatrixPreparesAcrossRatesAndLayouts",
    "testRepeatedStatePreparationCyclesDoNotReuseStaleEvidence",
):
    require(token in offline_tests, f"offline abuse coverage missing {token}")

for token in (
    "testRenderWatchdogRequiresSustainedSevereOverrun",
    "testLiveTimingValidatorRejectsPathologicalValues",
    "testControlPlaneHealthCollectionSurfacesInjectedLatencyDrift",
    "testControlPlaneHealthCollectionSurfacesInjectedInvalidTail",
    "testInitialLiveBuildFailureQuarantinesUnavailableComponent",
    "PR84InjectedHealthStage",
):
    require(token in live_tests, f"live abuse coverage missing {token}")

for token in (
    "testInjectedPreparationFailureMatrixPreservesCommittedRack",
    "testMalformedReplacementStateFailsBeforeBackendAndStaysAtomic",
    "PR84FaultPreparationBackend",
):
    require(token in mutation_tests, f"transaction abuse coverage missing {token}")

for phrase in (
    "failed mutation candidate never alters the committed rack",
    "latency or tail drift after live activation",
    "hardening logic remains off the realtime callback",
    "44.1, 48, and 96 khz",
    "pr84b",
):
    require(phrase in doc, f"hardening contract missing '{phrase}'")

print("PR84A deterministic Audio Unit hardening validation passed")
