from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def apply():
    validator = ROOT / "ci/validate_pr38_dynamics_ui.py"
    text = validator.read_text()
    text = text.replace(
        'ui = (ROOT / "NotchSixty/UI/ProductionDynamicsView.swift").read_text()\n',
        'ui = (ROOT / "NotchSixty/UI/ProductionDynamicsView.swift").read_text()\ntelemetry = (ROOT / "NotchSixty/UI/ProductionDynamicsTelemetryView.swift").read_text()\nengine = (ROOT / "NotchSixty/Audio/AudioIOEngine.swift").read_text()\nrender_h = (ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.h").read_text()\nrender_c = (ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c").read_text()\n'
    )
    text = text.replace(
        'require("ProductionDynamicsView.swift in Sources" in project, "production Dynamics view must be in target")\n',
        'require("ProductionDynamicsView.swift in Sources" in project, "production Dynamics view must be in target")\nrequire("ProductionDynamicsTelemetryView.swift in Sources" in project, "isolated Dynamics telemetry view must be in target")\n'
    )
    old = '''# No free-running telemetry was added to this first UI slice.
require("TimelineView" not in ui, "Dynamics workspace must not introduce unconditional polling")
require("Timer.publish" not in ui, "Dynamics workspace must not introduce unconditional timers")
'''
    new = '''# Live status is isolated to the selected processor editor. It reads direct
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
'''
    if old not in text:
        raise SystemExit("validator telemetry anchor missing")
    validator.write_text(text.replace(old, new, 1))

    audit = ROOT / "docs/PR38_LEGACY_DYNAMICS_CODE_AUDIT.md"
    text = audit.read_text()
    text = text.replace(
        "Status: **SOURCE INVENTORY COMPLETE; IMPLEMENTATION GAP CLOSURE IN PROGRESS**",
        "Status: **SOURCE INVENTORY COMPLETE; PRODUCTION PARITY UI IMPLEMENTED; HARDWARE ACCEPTANCE PENDING**",
    )
    text = text.replace(
        "- Wiener floor and attack/release are **confirmed Prod-gaps**.",
        "- Wiener floor and attack/release were **confirmed Prod-gaps** and are now restored by PR38 behind an explicit advanced-tuning override so named-preset sound remains unchanged by default.",
    )
    text = text.replace(
        "- named presets are a **confirmed Prod-gap** in the Swift control plane and will be restored in PR38 without changing the DSP.",
        "- named presets were a **confirmed Prod-gap** in the Swift control plane and are now restored in PR38 without changing Pause Gate DSP semantics.",
    )
    text = text.replace(
        "Commercial status: **Prod-present**. Production UI must expose the complete workflow, including Detect/status and per-harmonic depth editing. Tracking remains independently parked when OFF.",
        "Commercial status: **Prod-present**. PR38 now exposes the complete workflow, including one-shot Detect/status and per-harmonic depth editing. One-shot Detect temporarily enables the existing detector only for its measurement window, then restores the user's Continuous Tracking preference; Tracking remains parked when OFF.",
    )
    text = text.replace(
        "A processor being enabled does not imply its UI telemetry must also run when the editor is hidden.",
        "A processor being enabled does not imply its UI telemetry must also run when the editor is hidden. PR38 implements live status as a cancellable child of the selected processor editor at 8 Hz. Compressor/expander/limiter/GR/etc. values are direct runtime state already required by the active processor, so reading them does not enable the expensive render-kernel meter accumulator or a second analyzer pipeline. True analyzers/detectors such as Mains detection retain explicit activation semantics.",
    )
    audit.write_text(text)
