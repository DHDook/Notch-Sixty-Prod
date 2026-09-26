from pathlib import Path

path = Path("NotchSixty/Audio/StereoPlaybackControl.swift")
text = path.read_text()
old = "            guard renderIndex < UInt32(N60_MAX_EQ_RENDER_SLOTS) else {"
new = "            let compiledCapacity = UInt32(EQConfiguration.maximumBandCount * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND))\n            guard renderIndex < compiledCapacity else {"
if new not in text:
    if old not in text:
        raise SystemExit("Expected Phase B Swift render-capacity guard was not found")
    text = text.replace(old, new, 1)
path.write_text(text)
print("PR34 Phase B Swift compiled-section capacity uses Swift-visible constants.")
