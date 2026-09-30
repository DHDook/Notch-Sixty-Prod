#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ui = (ROOT / "NotchSixty/UI/ProductionDynamicsView.swift").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR42 Dynamics UI validation failed: {message}")


require("LabeledContent(title)" in ui, "numeric parameter rows must use semantic LabeledContent")
require(".textFieldStyle(.roundedBorder)" in ui, "numeric entry must retain native macOS field styling")
require(".background(.regularMaterial, in: .rect(cornerRadius: 22))" in ui, "processor editor must use adaptive material surface")
require(".stroke(.quaternary, lineWidth: 0.5)" in ui, "processor editor must retain subtle adaptive boundary")
require(".frame(width: 165, alignment: .leading)" not in ui, "fixed legacy parameter-label column must not return")
require(".background(.quaternary.opacity(0.22), in: .rect(cornerRadius: 22))" not in ui, "fixed quaternary processor card must not return")
require("ProductionDynamicsTelemetryView(engine: engine, kind:" in ui, "UI modernization must retain selected-processor telemetry")
require("Attack = fade-out" in ui and "Release = fade-in" in ui, "Pause Gate product convention must remain visible")

print("PR42 Dynamics current-macOS style guard: PASS")
