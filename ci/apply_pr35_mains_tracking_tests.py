from pathlib import Path

path = Path("NotchSixtyTests/NotchSixtyTests.swift")
text = path.read_text()

finds_old = """        var dynamics = DynamicsConfiguration()\n        dynamics.mainsNotch.enabled = false\n        dynamics.mainsNotch.region = .hz60\n        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)\n"""
finds_new = """        var dynamics = DynamicsConfiguration()\n        dynamics.mainsNotch.enabled = false\n        dynamics.mainsNotch.region = .hz60\n        dynamics.mainsNotch.continuousTracking = true\n        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)\n"""
if text.count(finds_old) != 1:
    raise SystemExit(f"expected one offset-detector test setup, found {text.count(finds_old)}")
text = text.replace(finds_old, finds_new)

rejects_old = """        var dynamics = DynamicsConfiguration()\n        dynamics.mainsNotch.region = .hz60\n        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)\n"""
rejects_new = """        var dynamics = DynamicsConfiguration()\n        dynamics.mainsNotch.region = .hz60\n        dynamics.mainsNotch.continuousTracking = true\n        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)\n"""
if text.count(rejects_old) != 1:
    raise SystemExit(f"expected one out-of-band detector test setup, found {text.count(rejects_old)}")
text = text.replace(rejects_old, rejects_new)

path.write_text(text)
print("PR35 mains tracking tests now explicitly enable the analyzer")
