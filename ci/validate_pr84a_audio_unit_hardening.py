#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OFFLINE = ROOT / "NotchSixty/Audio/AudioUnitOfflinePreparation.swift"
HOST = ROOT / "NotchSixty/Audio/AudioUnitHostController.swift"
LIVE = ROOT / "NotchSixty/Audio/AudioUnitLiveRackRuntime.swift"
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
):
    require(token in live, f"live hardening missing {token}")

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
