#!/usr/bin/env python3
"""PR98 closure: forbid diagnostic ANC APIs from escaping into live audio paths.

A narrow allowlist, not a substitute for code review or physical isolation.
Scan all application Swift/C/H sources including newly introduced files.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source_root = root / "NotchSixty"
allowed_references = {
    "N60FFDeadlineBridgeProcess(": {
        "Audio/Realtime/N60FeedForwardDeadlineBridge.h",
        "Audio/Realtime/N60FeedForwardDeadlineBridge.c",
        "Audio/QuietZoneNativeShadowTimingTransport.swift",
    },
    "N60FFDeadlineBridgeAdvanceFaultFade(": {
        "Audio/Realtime/N60FeedForwardDeadlineBridge.h",
        "Audio/Realtime/N60FeedForwardDeadlineBridge.c",
        "Audio/QuietZoneNativeShadowTimingTransport.swift",
    },
    "QuietZoneNativeShadowTimingTransport": {
        "Audio/QuietZoneNativeShadowTimingTransport.swift",
        "Audio/QuietZoneFeedForwardClockMonitor.swift",
    },
    "QuietZoneClockGuardedShadowTransport": {
        "Audio/QuietZoneFeedForwardClockMonitor.swift",
        "Audio/QuietZoneReferenceLeakageStability.swift",
    },
    "QuietZoneLeakageGuardedShadowSession": {
        "Audio/QuietZoneReferenceLeakageStability.swift",
    },
    "QuietZoneReferenceEchoOfflineSimulator": {
        "Audio/QuietZoneReferenceEchoSuppression.swift",
    },
    "QuietZoneHardwareAcceptanceAnalyzer": {
        "Audio/QuietZoneHardwareAcceptanceProtocol.swift",
    },
}
seen = {name: set() for name in allowed_references}
for file in sorted(source_root.rglob("*")):
    if file.suffix not in {".swift", ".c", ".h", ".m", ".mm"}:
        continue
    relative = str(file.relative_to(source_root))
    data = file.read_text(errors="replace")
    for marker, permitted in allowed_references.items():
        if marker not in data:
            continue
        assert relative in permitted, (
            f"PR98 DISCONNECTED-OUTPUT INVARIANT VIOLATED: {marker} "
            f"is referenced by {relative}. Review audio-output ownership "
            "and use a separately safety-qualified live-output PR."
        )
        seen[marker].add(relative)

for marker, references in seen.items():
    assert references, f"PR98 symbol disappeared without audit review: {marker}"

header = (source_root / "Audio/Realtime/N60FeedForwardDeadlineBridge.h").read_text()
bridge = (source_root / "Audio/Realtime/N60FeedForwardDeadlineBridge.c").read_text()
assert "typedef struct {\n    double referenceFrame;\n    uint64_t hypotheticalOutputFrame;" in header
assert ".outputConnected = false" in bridge
assert ".liveANCQualified = false" in bridge
assert "float discardedLeft = 0, discardedRight = 0;" in bridge
assert "N60FeedForwardPreviewFIRProcessFrame(" in bridge
assert "N60RenderKernelProcess(" not in bridge
assert "AudioDeviceStart(" not in bridge
assert "AudioUnitRender(" not in bridge
for relative in (
    "Audio/QuietZoneHardwareAcceptanceProtocol.swift",
    "Audio/QuietZoneFeedForwardSafetyAcceptance.swift",
    "Audio/QuietZoneReferenceLeakageStability.swift",
):
    item = (source_root / relative).read_text()
    for forbidden in (
        "AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
        "N60RealtimeAudioBridgeRender(", "N60RenderKernelProcess(",
    ):
        assert forbidden not in item, (relative, forbidden)
print("PR98 final disconnected ANC source-boundary audit passed")
