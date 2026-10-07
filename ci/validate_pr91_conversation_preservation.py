#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "NotchSixty/Audio/AmbientCompensation.swift"
CONTROLLER = ROOT / "NotchSixty/State/AmbientCompensationController.swift"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
KERNEL_H = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.h"
KERNEL_C = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c"
UI = ROOT / "NotchSixty/UI/ProductionActiveAcousticsWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/AmbientCompensationTests.swift"
DOC = ROOT / "docs/PR91_CONVERSATION_PRESERVATION.md"

def require(condition, message):
    if not condition:
        raise SystemExit(f"PR91 validation failed: {message}")

core = CORE.read_text()
controller = CONTROLLER.read_text()
engine = ENGINE.read_text()
kernel_h = KERNEL_H.read_text()
kernel_c = KERNEL_C.read_text()
ui = UI.read_text()
tests = TESTS.read_text()
doc = DOC.read_text().lower()

for token in (
    "enum ActiveAcousticsPlaybackAdaptationMode",
    "case musicFocus",
    "case conversationFocus",
    "var playbackAdaptationMode:",
    "effectivePlaybackAdaptationMode",
    "struct ConversationPreservationConfiguration",
    "struct ConversationPreservationPlanner",
    "func conversationEvidence(",
    "maximumOverallAttenuationDB = 4.0",
    "maximumPresenceCutDB = 3.0",
    "estimatedClearanceDB",
    "minimumAppliedGainDB",
):
    require(token in core, f"conversation policy missing {token}")

require(
    "playbackAdaptationMode ?? (enabled ? .musicFocus : .off)" in core,
    "legacy PR89 enabled-state migration is missing",
)

for token in (
    "setPlaybackAdaptationMode(",
    "updated.playbackAdaptationMode = mode",
    "updated.enabled = mode != .off",
    "engine.clearAmbientCompensationRuntimeTarget()",
    "case .musicFocus:",
    "case .conversationFocus:",
    "conversationPlanner.plan(",
):
    require(token in controller, f"controller integration missing {token}")

clear_pos = controller.find("engine.clearAmbientCompensationRuntimeTarget()", controller.find("func setPlaybackAdaptationMode"))
persist_pos = controller.find("try persist(updated)", controller.find("func setPlaybackAdaptationMode"))
start_pos = controller.find("try startMonitoring()", controller.find("func setPlaybackAdaptationMode"))
require(
    persist_pos >= 0 and clear_pos > persist_pos and start_pos > clear_pos,
    "mode switch must persist, return old overlay toward unity, then start the new policy",
)

for token in (
    "N60DSPGraphSnapshotSetActiveAcousticsAdaptation",
    "levelDB < -6.0 || levelDB > 6.0",
    "presenceSupportDB < -3.0 || presenceSupportDB > 2.0",
    "fabs(gains[index]) > 0.0001",
):
    require(token in kernel_h + kernel_c, f"signed realtime overlay missing {token}")

require(
    "N60DSPGraphSnapshotSetAmbientCompensation" in kernel_c,
    "retained PR89 boost-only graph API was removed",
)

for token in (
    "N60DSPGraphSnapshotSetActiveAcousticsAdaptation",
    "let positiveRecovery = max(target.levelDB, 0)",
    "abs(target.presenceSupportDB) > 0.000_1",
    "ambientCompensationRuntimeTarget.levelDB",
    "max(ambientTarget.levelDB, 0)",
):
    require(token in engine, f"engine coexistence/headroom integration missing {token}")

for token in (
    'return "Playback Adaptation"',
    'Text("Playback Adaptation")',
    "ActiveAcousticsPlaybackAdaptationMode.allCases",
    'Text("Active Quiet Zone")',
    '"Conversation Evidence"',
    '"Estimated Clearance"',
    "minimumAmbientAppliedGainDB",
):
    require(token in ui, f"unified Active Acoustics UI missing {token}")

for token in (
    "testLegacyEnabledStateMapsToMusicFocus",
    "testConversationEvidencePrefersSpeechShapedResidual",
    "testConversationFocusCreatesBoundedSubtractiveAdaptation",
    "testConversationFocusStaysAtUnityWithoutConversationEvidence",
    "testConversationEnvelopeUsesFastOnsetAndSlowRecovery",
    "testSignedActiveAcousticsGraphAcceptsConversationTarget",
):
    require(token in tests, f"PR91 behavioral tests missing {token}")

for phrase in (
    "off",
    "music focus",
    "conversation focus",
    "conversation focus + active quiet zone",
    "never boosts overall playback",
    "no microphone audio is persisted",
    "speech recognition or transcription",
):
    require(phrase in doc, f"PR91 contract missing '{phrase}'")

print("PR91 Conversation Preservation architecture validation passed")
