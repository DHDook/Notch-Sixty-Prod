#!/usr/bin/env python3
from pathlib import Path
import sys

PROFILES = Path("NotchSixty/State/ProductProfiles.swift").read_text()
TOOLBAR = Path("NotchSixty/UI/ProductionProfileToolbar.swift").read_text()
APP = Path("NotchSixty/NotchSixtyApp.swift").read_text()
ROOT = Path("NotchSixty/UI/ProductionRootView.swift").read_text()


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        print(f"PR39 profile layers: FAIL: missing {context}: {needle!r}", file=sys.stderr)
        raise SystemExit(1)


require(PROFILES, "struct ContentPresetState: Codable", "versioned Content Preset state")
for field in ["stereoEQ", "inputPreampDB", "headroomAttenuationDB", "dynamics"]:
    require(PROFILES, field, f"Content Preset field {field}")
require(PROFILES, "struct PlaybackSystemState: Codable", "versioned Playback System state")
for field in ["associatedOutputUID", "outputGainDB", "bassManagement", "roomCorrection", "speakerIR"]:
    require(PROFILES, field, f"Playback System field {field}")
require(PROFILES, "globalBypassed and auditionMode are session state", "session-state exclusion")
require(PROFILES, "result.outputGainDB = outputGainDB", "system-owned output trim")
require(PROFILES, "result.inputPreampDB = inputPreampDB", "content-owned input gain")
require(PROFILES, "profiles-v1.json", "versioned on-disk persistence")
require(PROFILES, "try data.write(to: storageURL, options: .atomic)", "atomic persistence")
require(TOOLBAR, "Content Presets", "production Content Preset selector")
require(TOOLBAR, "Playback Systems", "production Playback System selector")
require(TOOLBAR, "Associate with Current Output", "manual output association")
require(APP, "let profiles: ProductProfileController", "product-level profile ownership")
require(APP, "profiles.restoreSelectedLayers()", "saved layer restoration")
require(ROOT, "ProductionProfileToolbar(profiles: product.profiles", "production toolbar wiring")
print("PR39 profile layers: PASS")
