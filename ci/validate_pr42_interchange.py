#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
toolbar = (ROOT / "NotchSixty/UI/ProductionProfileToolbar.swift").read_text()
entitlements = (ROOT / "NotchSixty/NotchSixty.entitlements").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR42 interchange validation failed: {message}")


# Reachable production UI.
for token in [
    "Import Preset / EQ…",
    "REW Filter Text…",
    "EasyEffects Equalizer…",
    "CamillaDSP YAML…",
]:
    require(token in toolbar, f"missing production interchange action: {token}")

require("PresetInterchange" in toolbar, "pure interchange codec is missing")
require("replaceStereoEQConfiguration" in toolbar, "imports must terminate in the commercial stereo-EQ model")
require("saveCurrentContentPreset" in toolbar, "successful imports must become commercial Content Presets")

# Legacy native preset migration contract.
for token in ["activeBandCount", "leftBands", "rightBands", "channelMode", "qFromBandwidthOctaves"]:
    require(token in toolbar, f"legacy preset migration contract missing: {token}")
require("globalBypass" in toolbar and "intentionally not restored" in toolbar,
        "legacy Global Bypass must remain transient")
require("legacyAttack" in toolbar and "pauseGate.releaseMs" in toolbar,
        "legacy Pause Gate Attack must map to commercial Release")
require("legacyRelease" in toolbar and "pauseGate.attackMs" in toolbar,
        "legacy Pause Gate Release must map to commercial Attack")
require("Historical Constant-Q and Linkwitz target state" in toolbar,
        "legacy persistence defect must be surfaced rather than guessed")

# REW audited subset.
for token in ["PK", "LS", "HS", "LP", "HP", "BP", "NOTCH", "BW(?:/60)?"]:
    require(token in toolbar, f"REW mapping missing: {token}")
require("no usable" in toolbar.lower() and "filters" in toolbar.lower(),
        "empty REW import must fail explicitly")

# EasyEffects audited subset and ownership boundary.
for token in ["equalizer#0", "split-channels", "input-gain", "output-gain", "Bell", "Band-pass"]:
    require(token in toolbar, f"EasyEffects contract missing: {token}")
require("Playback System layer" in toolbar,
        "EasyEffects output gain must not silently overwrite system-owned output trim")

# CamillaDSP commercial exporter foundation.
for token in ["type: Values", "BiquadCombo", "pipeline:", "CHANGE_ME_CAPTURE", "channels: [0]", "channels: [1]"]:
    require(token in toolbar, f"CamillaDSP export contract missing: {token}")
require("Linkwitz Transform" in toolbar and "omitted" in toolbar,
        "unsupported coefficient-level export must be explicit rather than approximated")

# App Sandbox must permit user-initiated exports.
require("com.apple.security.files.user-selected.read-write" in entitlements,
        "sandbox must allow user-selected import/export")
require("com.apple.security.files.user-selected.read-only" not in entitlements,
        "read-only sandbox entitlement must not coexist with export workflow")

print("PR42 preset/interchange closure guard: PASS")
