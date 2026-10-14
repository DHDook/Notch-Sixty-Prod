#!/usr/bin/env python3
"""Bounded source-only Release/performance/asset audit for final Notch Sixty RC.

No runtime instrumentation. Not a physical CPU, dropout or latency benchmark.
"""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[1]

def require(ok, message):
    if not ok:
        raise SystemExit("Final RC hardening: " + message)

project = (ROOT / "NotchSixty.xcodeproj/project.pbxproj").read_text()
config = re.search(
    r'A10000000000000000000065 /\* Release \*/ = \{(.*?)\n\s*\};',
    project, re.S
)
require(config is not None, "missing Release configuration")
release = config.group(1)
require("SWIFT_COMPILATION_MODE = wholemodule;" in release,
        "Release whole-module build lost")
require("MACOSX_DEPLOYMENT_TARGET = 27.0;" in release,
        "owner-selected macOS 27 minimum changed")
require("SWIFT_ACTIVE_COMPILATION_CONDITIONS" not in release,
        "unexpected Release debug compilation conditions")
require("ENABLE_TESTABILITY = YES" not in release,
        "testability turned on for Release")
require("-Onone" not in release, "Release optimizations disabled")

ui = re.search(r'A40000000000000000000050 /\* UI \*/ = \{(.*?)\};', project, re.S)
ui_ref = "F64000000000000000000015 /* ProductionMultichannelCalibrationWorkspace.swift */"
require(ui is not None and ui.group(1).count(ui_ref) == 1,
        "duplicate UI project file reference")

assets = ROOT / "NotchSixty/Assets.xcassets"
entries = json.loads((assets / "AppIcon.appiconset/Contents.json").read_text())["images"]
require(len(entries) == 10 and len({e["filename"] for e in entries}) == 10,
        "macOS AppIcon must have ten unique supported sizes")
require(all(e.get("idiom") == "mac" and not e.get("appearances") for e in entries),
        "unsupported dark macOS AppIcon appearance slot")
require(all((assets / "AppIcon.appiconset" / e["filename"]).is_file()
            for e in entries), "missing Finder AppIcon raster")
for v in ("Light", "Dark"):
    require((assets / f"DockIcon{v}.imageset/DockIcon{v}@2x.png").is_file(),
            f"approved DockIcon{v} missing")
app = (ROOT / "NotchSixty/NotchSixtyApp.swift").read_text()
require('NSImage.Name(useDarkIcon ? "DockIconDark" : "DockIconLight")' in app,
        "runtime Dock appearance selection changed")

icon_root = ROOT / "design/app-icons"
manifest = json.loads((icon_root / "generated-icon-manifest.json").read_text())
require(manifest["generatedSlotCount"] == 14, "generated icon count changed")
outputs = manifest["outputsSHA256"]
require(len(outputs) == 14, "all fourteen icon output digests are required")
for relative, digest in outputs.items():
    p = ROOT / relative
    require(p.is_file(), "missing generated approved image: " + relative)
    require(hashlib.sha256(p.read_bytes()).hexdigest() == digest,
            "approved icon output hash drift: " + relative)
for name, digest in manifest["sourceSHA256"].items():
    p = icon_root / name
    require(p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest() == digest,
            "owner-approved master changed: " + name)

# This tests only direct obvious synchronous logs in core translation units;
# framework/plugin/indirect logging and all real-device performance remain unproved.
log = re.compile(r'(?<![\w])(?:printf|fprintf|syslog|NSLog|os_log|os_signpost|debugPrint|print)\s*\(')
for relative in (
    "NotchSixty/Audio/Realtime/N60RenderKernel.c",
    "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c",
    "NotchSixty/Audio/AudioIOEngine.swift",
):
    require(not log.search((ROOT / relative).read_text()),
            "direct synchronous logging in " + relative)

header = (ROOT / "NotchSixty/Audio/Realtime/N60MultichannelBassManagement.h").read_text()
require("N60CrossoverPreciseState highPass[" in header
        and "N60CrossoverPreciseState lowPass[" in header
        and "N60CrossoverPreciseState lfeLowPass[" in header,
        "bass management must use double-precision state at high rates")
require("N60CrossoverPreciseProcessSample(coefficients[section]" in header,
        "multichannel bass management must use matching double coefficients")
workflow = (ROOT / ".github/workflows/final-integrated-rc-qa.yml").read_text()
require("-configuration Debug" in workflow and "-configuration Release" in workflow,
        "separate Debug test and Release build lost")
require('cp -R "$RELEASE_APP" "$RC_APP"' in workflow,
        "test DMG must come from optimized Release app")
require(workflow.count("python3 ci/validate_final_rc_hardening.py") == 2,
        "hygiene audit must run in portable and macOS CI")
require(workflow.count("python3 ci/validate_pr55_multichannel_bass_management.py") == 2,
        "precise multichannel bass regression must run in both jobs")
print("Final RC: optimized Release, logging, icon, Xcode and precise bass hygiene PASS")
