#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "NotchSixty/UI/ProductionDynamicsView.swift").read_text()
telemetry = (ROOT / "NotchSixty/UI/ProductionDynamicsTelemetryView.swift").read_text()
engine = (ROOT / "NotchSixty/Audio/AudioIOEngine.swift").read_text()
render_h = (ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.h").read_text()
render_c = (ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c").read_text()
root = (ROOT / "NotchSixty/UI/ProductionRootView.swift").read_text()
config = (ROOT / "NotchSixty/Audio/DynamicsConfiguration.swift").read_text()
compat = (ROOT / "NotchSixty/Audio/Realtime/N60DynamicsLegacyAdvanced.c").read_text()
audit = (ROOT / "docs/PR38_LEGACY_DYNAMICS_CODE_AUDIT.md").read_text()
project = (ROOT / "NotchSixty.xcodeproj/project.pbxproj").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR38 validation failed: {message}")


# Production route / target membership.
require("ProductionDynamicsView(engine: engine)" in root, "Dynamics must route to production workspace")
require("ProductionDynamicsView.swift in Sources" in project, "production Dynamics view must be in target")
require("ProductionDynamicsTelemetryView.swift in Sources" in project, "isolated Dynamics telemetry view must be in target")
require("dense dynamics editor will migrate" not in root.lower(), "Dynamics placeholder must not return")

# Source-first parity contract.
require("legacy source code" in audit.lower(), "audit must identify source code as parity authority")
require("documentation is deliberately excluded" in audit.lower(), "documentation must not become parity authority")

# Logical production grouping and complete module navigator.
for group in ["DYNAMICS", "RESTORATION", "LEVEL & DIALOGUE", "PROTECTION", "CONDITIONING"]:
    require(group in ui, f"missing production Dynamics group {group}")

required_modules = [
    "Compressor", "Multiband Compressor", "Expander", "Pause Gate", "Dynamic Gain Rider",
    "Spectral Denoiser", "De-Esser", "Mains Hum", "Infrasonic Filter",
    "LUFS Match", "Loudness Compensation", "Dialogue Leveler",
    "Limiter", "Soft Clipper", "Automatic Headroom", "Oversampling",
    "De-Harsh", "Stereo Widener", "Stereo Mode", "DC Offset Filter",
]
for module in required_modules:
    require(f'return "{module}"' in ui, f"missing production editor/navigation module: {module}")

# Important legacy subconfiguration must stay directly accessible.
for token in [
    "Program-Dependent Release", "Sidechain High-Pass", "Low / Mid Slope", "Mid / High Slope",
    "Dynamic-EQ Processing Mode", "Harmonic Depths", "Protect Frequency Range",
    "Capture Noise Profile", "Reset Profile", "Advanced Detection", "True-Peak Guard",
    "Asymmetry Trim", "Automatic Gain Compensation", "Mono Low Band",
]:
    require(token in ui, f"legacy/advanced subconfiguration missing: {token}")

# Pause Gate parity and product naming convention.
for preset in ["amplifierHiss", "sensitive", "relaxed", "broadcast", "custom"]:
    require(f"case {preset}" in config, f"Pause Gate preset missing: {preset}")
require("Attack = fade-out" in ui, "Pause Gate Attack must be explained as fade-out")
require("Release = fade-in" in ui, "Pause Gate Release must be explained as fade-in")
require("markCustomIfNeeded" in config, "manual Pause Gate changes must leave named preset mode")

# Denoiser parity. Named presets must preserve accepted tuning until explicit override.
for field in ["advancedTuningEnabled", "minimumGain", "attackMs", "releaseMs"]:
    require(field in config, f"denoiser advanced parity field missing: {field}")
require("advancedTuningEnabled = false" in config, "named denoiser presets must disable advanced override")
require("Override Preset Smoothing" in ui, "advanced denoiser tuning must be explicit")
require("N60DynamicsSnapshotSetSpectralDenoiserLegacyAdvanced" in compat, "denoiser compatibility setter missing")
require("denoiser->suppressionRelease = legacyAttackAlpha" in compat, "legacy Attack direction mapping regressed")
require("denoiser->suppressionAttack = legacyReleaseAlpha" in compat, "legacy Release direction mapping regressed")

# Old Dynamics placement is not binding for speaker/room workflows.
for forbidden in ["Bass Management", "FIR Correction", "Multi-Seat"]:
    require(f'return "{forbidden}"' not in ui, f"{forbidden} should live in its dedicated production workspace")

# Live status is isolated to the selected processor editor. It reads direct
# processor state only and never activates the render-kernel full meter stack.
require("TimelineView" not in ui and "TimelineView" not in telemetry, "Dynamics telemetry must not use free-running TimelineView redraws")
require("Timer.publish" not in ui and "Timer.publish" not in telemetry, "Dynamics telemetry must not use publisher timers")
require(".task(id: kind)" in telemetry, "selected Dynamics telemetry must have cancellable view lifetime")
require("125_000_000" in telemetry, "Dynamics live status polling should remain bounded at 8 Hz")
require("N60RealtimeAudioBridgeSetMeteringDemand" not in telemetry, "Dynamics status must not activate full meter accumulation")
require("ProductionDynamicsTelemetryView(engine: engine, kind:" in ui, "processor editors must host isolated telemetry children")

# Legacy one-shot Mains Detect must work independently of tracking preference.
require("detectMainsHumOnce" in engine, "one-shot Mains Detect control-plane method missing")
require("1_150_000_000" in engine, "one-shot Mains Detect must wait for a complete detector window")
require("Detecting…" in ui and "No stable mains tone detected." in ui, "production Mains Detect workflow missing")

# Gain Rider live parity uses protection-runtime state, not a new analyzer.
for token in ["gainRiderAttenuationDB", "sustainedLimiterGainReductionDB", "truePeakGuardActive"]:
    require(token in render_h and token in render_c, f"protection telemetry field missing: {token}")
require("Rider Attenuation" in telemetry, "Gain Rider live attenuation readout missing")

print("PR38 production Dynamics parity guard: PASS")
