#!/usr/bin/env python3
"""Permanent PR68 validation for dashboard VU polish and software volume-key resolution."""

from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
ROOT_VIEW = ROOT / "NotchSixty/UI/ProductionRootView.swift"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR68 validation failed: {message}")


def block(text: str, start: str, end: str) -> str:
    require(start in text and end in text, f"unable to isolate {start}")
    return text.split(start, 1)[1].split(end, 1)[0]


def main() -> None:
    for path in (ROOT_VIEW, ENGINE, APP):
        require(path.exists(), f"{path.name} is missing")

    root = ROOT_VIEW.read_text(encoding="utf-8")
    engine = ENGINE.read_text(encoding="utf-8")
    app = APP.read_text(encoding="utf-8")

    # VU presentation: calibrated scale remains, but presentation is the new
    # shallow/pivot-hidden vintage face with an actual Liquid Glass overlay.
    require("static let startAngleDegrees = 224.0" in root, "shallow VU start angle is missing")
    require("static let sweepDegrees = 92.0" in root, "92-degree flattened VU sweep is missing")
    require("0 VU = −18 dBFS" in root, "VU calibration legend changed unexpectedly")
    require("height * 1.14" in root, "VU virtual pivot is not below the visible face")
    require("radius: radius * 0.62" in root and "radius: radius * 0.985" in root,
            "short visible needle segment is missing")
    meter = block(root, "private struct StereoSignatureVUMeter: View {", "private struct ProductionActiveCrossoverView: View {")
    require(".glassEffect(.regular, in: .rect(cornerRadius: 22))" in meter,
            "Liquid Glass meter overlay is missing")
    require("Color(red: 0.96, green: 0.91, blue: 0.76)" in meter,
            "warm seventies meter face is missing")
    require("Path(ellipseIn:" not in meter, "needle pivot cap must remain hidden")
    require("hotArc" in meter, "positive VU hot zone is missing")
    require('specifier: "%.1f"' in root, "fine master-volume readout precision is missing")

    # Volume keys: no fixed 1/16 callback remains. The intercepted keyboard
    # event carries direction only; software-DSP mode computes the selected step.
    require("softwareVolumeKeyStepDenominator: Int = 16" in engine,
            "default 1/16 software volume resolution is missing")
    require("denominator == 16 || denominator == 32 || denominator == 64" in engine,
            "volume resolution allow-list is missing")
    require("handleGlobalVolumeKey(direction: 1.0)" in engine,
            "volume-up callback is not resolution-independent")
    require("handleGlobalVolumeKey(direction: -1.0)" in engine,
            "volume-down callback is not resolution-independent")
    require("handleGlobalVolumeKey(delta: 1.0 / 16.0)" not in engine,
            "legacy fixed 1/16 volume-up step remains")
    key_handler_prefix = block(
        engine,
        "private func handleGlobalVolumeKey(direction: Double) {",
        "let level = min("
    )
    require("masterVolumeCapabilities.controlMode == .softwareDSP" in key_handler_prefix,
            "volume-key stepping is not restricted to software DSP mode")
    require("direction / Double(softwareVolumeKeyStepDenominator)" in key_handler_prefix,
            "selected denominator is not used by the volume-key handler")
    require("masterVolumeController." not in key_handler_prefix,
            "volume-key preflight must not write physical-device volume")

    # Application-level persistence rather than Playback System / preset state.
    require("private enum ApplicationVolumeStepResolution: Int" in app,
            "application volume resolution enum is missing")
    for raw in ("case standard = 16", "case fine = 32", "case precision = 64"):
        require(raw in app, f"missing volume option: {raw}")
    require('static let volumeStepResolution = "application.volumeStepResolution"' in app,
            "volume resolution UserDefaults key is missing")
    require("defaults.set(volumeStepResolution.rawValue, forKey: Key.volumeStepResolution)" in app,
            "volume resolution is not persisted")
    require("audioEngine.setSoftwareVolumeKeyStepDenominator(volumeStepResolution.denominator)" in app,
            "persisted volume resolution is not applied to the engine")
    require('settingsCard(title: "Volume Keys"' in app,
            "Volume Keys Settings card is missing")
    require("1/16 = 6.25%" in app and "1/32 = 3.125%" in app and "1/64 = 1.5625%" in app,
            "Settings step-size explanation is missing")
    require("preferences.apply(to: product.audioEngine)" in app,
            "application preference is not applied to the live engine")

    # PR68 is UI/control-plane only. No new realtime C/C++ implementation file
    # or external dependency is expected for these quality-of-life changes.
    require("import ServiceManagement" in app and "import SwiftUI" in app,
            "unexpected application integration change")

    print("PR68 VU + volume polish validation passed")


if __name__ == "__main__":
    main()
