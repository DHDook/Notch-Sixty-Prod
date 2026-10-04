#!/usr/bin/env python3
from __future__ import annotations
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
TARGET = ROOT / "NotchSixty/State/ProductProfiles.swift"
WORKFLOW = ROOT / ".github/workflows/pr63-apply-profile-ordering.yml"
SELF = pathlib.Path(__file__)
text = TARGET.read_text(encoding="utf-8")

def once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} matched {count} times")
    text = text.replace(old, new, 1)

once(
'''            let playback = state.playback.applying(to: engine.playbackControlConfiguration)
            let gain = state.composingGain(over: engine.gainConfiguration)
            try engine.replaceMultiOutputRoutingConfiguration(state.outputRouting)
''',
'''            let playback = state.playback.applying(to: engine.playbackControlConfiguration)
            let gain = state.composingGain(over: engine.gainConfiguration)
            // Remove the previous system's semantic routing contract before
            // applying bass/routing state owned by the target system. The target
            // profile is reinstalled only after its bass-management dependency.
            try engine.replaceOutputDeviceProfileConfiguration(nil)
            try engine.replaceMultiOutputRoutingConfiguration(state.outputRouting)
''',
"apply profile ordering",
)
once(
'''            let playback = previous.playback.applying(to: engine.playbackControlConfiguration)
            let gain = previous.composingGain(over: engine.gainConfiguration)
            try? engine.replaceMultiOutputRoutingConfiguration(previous.outputRouting)
''',
'''            let playback = previous.playback.applying(to: engine.playbackControlConfiguration)
            let gain = previous.composingGain(over: engine.gainConfiguration)
            try? engine.replaceOutputDeviceProfileConfiguration(nil)
            try? engine.replaceMultiOutputRoutingConfiguration(previous.outputRouting)
''',
"rollback clear profile",
)
once(
'''            try? engine.replacePlaybackControlConfiguration(playback)
            try? engine.replaceOutputDeviceProfileConfiguration(nil)
            try? engine.replaceBassManagementConfiguration(previous.bassManagement)
''',
'''            try? engine.replacePlaybackControlConfiguration(playback)
            try? engine.replaceBassManagementConfiguration(previous.bassManagement)
''',
"remove late rollback clear",
)
TARGET.write_text(text, encoding="utf-8")
if WORKFLOW.exists(): WORKFLOW.unlink()
if SELF.exists(): SELF.unlink()
