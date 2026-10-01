#!/usr/bin/env python3
from pathlib import Path

ui_files = sorted(Path("NotchSixty/UI").glob("*.swift"))
root = Path("NotchSixty/UI/ProductionRootView.swift").read_text()
eq = Path("NotchSixty/UI/ProductionEqualizerView.swift").read_text()
app = Path("NotchSixty/NotchSixtyApp.swift").read_text()
profiles = Path("NotchSixty/UI/ProductionProfileToolbar.swift").read_text()

assert "struct ProductionGlassPickerChromeModifier" in root, "shared production picker chrome modifier missing"
assert ".glassEffect(.regular, in: .capsule)" in root, "production picker chrome must use stable Liquid Glass"
assert ".padding(.horizontal, 6)" in root, "production picker chrome must keep a constant horizontal text inset"
assert ".glassEffect(.regular.interactive(), in: .capsule)" not in root, "Picker chrome must not layer interactive glass over native Picker interaction"

for path in ui_files:
    source = path.read_text()
    picker_count = source.count("Picker(")
    chrome_count = source.count(".productionGlassPickerChrome()")
    assert chrome_count == picker_count, f"{path}: {picker_count} Picker(s) but {chrome_count} production glass chrome modifier(s)"

start_marker = "private struct ProductionMenuBarView: View {"
end_marker = "\n@main\nstruct NotchSixtyApp: App {"
assert start_marker in app and end_marker in app, "production app-shell bounds not found"
production_shell = app.split(start_marker, 1)[1].split(end_marker, 1)[0]
assert production_shell.count(".productionGlassPickerChrome()") == production_shell.count("Picker("), "tray/settings Picker styling is incomplete"

bypass_start = eq.index('Toggle("Bypass"')
bypass_end = eq.index('Button {\n                    addBand()', bypass_start)
bypass = eq[bypass_start:bypass_end]
assert ".fixedSize(horizontal: true, vertical: false)" in bypass, "EQ Bypass must remain single-line"
assert ".layoutPriority(1)" in bypass, "EQ Bypass must keep enough layout priority to avoid wrapping"

assert profiles.count(".buttonStyle(.glass)") >= 2, "Content/System toolbar menus must retain glass button styling"
print("PR45 production control-style guard passed")
