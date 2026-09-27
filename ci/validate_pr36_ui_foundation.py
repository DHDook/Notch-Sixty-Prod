#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
UI = (ROOT / "NotchSixty/UI/ProductionRootView.swift").read_text()
PROJECT = (ROOT / "NotchSixty.xcodeproj/project.pbxproj").read_text()
DOC = (ROOT / "docs/PR36_PRODUCTION_UI_FOUNDATION.md").read_text()


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        print(f"PR36 UI foundation validation: FAIL: {context} missing {needle!r}", file=sys.stderr)
        raise SystemExit(1)


def forbid(text: str, needle: str, context: str) -> None:
    if needle in text:
        print(f"PR36 UI foundation validation: FAIL: {context} must not contain {needle!r}", file=sys.stderr)
        raise SystemExit(1)


# Shipping target / platform language.
require(PROJECT, "MACOSX_DEPLOYMENT_TARGET = 27.0;", "project deployment target")
forbid(PROJECT, "MACOSX_DEPLOYMENT_TARGET = 14.2;", "project deployment target")

# macOS 27 native navigation + selective Liquid Glass control language.
require(UI, "NavigationSplitView", "production navigation")
require(UI, "GlassEffectContainer", "selective custom glass controls")
require(UI, ".buttonStyle(.glassProminent)", "primary glass action")
require(UI, ".glassEffect(.regular", "Liquid Glass status/control surface")

# Signature dashboard identity is a new clean-room stereo analog meter pair.
require(UI, "private struct SignatureVUMeter", "signature VU component")
require(UI, 'SignatureVUMeter(channel: "LEFT"', "left VU")
require(UI, 'SignatureVUMeter(channel: "RIGHT"', "right VU")
require(UI, "static let referenceDBFS = -18.0", "VU reference")
require(UI, "static let minimumVU = -20.0", "VU display floor")
require(UI, "static let maximumVU = 3.0", "VU display ceiling")

# Room Correction and Active Crossover belong to the dedicated speaker workspace.
require(UI, "case speakerSetup", "speaker setup route")
require(UI, "private struct ProductionSpeakerSetupView", "speaker setup surface")
require(UI, 'Text("Active Crossover")', "speaker setup crossover route")
require(UI, 'Text("Room Correction")', "speaker setup room-correction route")
require(DOC, "Room Correction and Active Crossover do not appear as dashboard control panels.", "information architecture contract")

# Engineering validation is intentionally retained during migration.
require(DOC, "Engineering Validation", "validation migration contract")
require(DOC, "handoff document", "post-merge handoff requirement")

print("PR36 production UI foundation: PASS")
