#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/Audio/CoreAudio/MultichannelCalibrationTransport.swift")
text = path.read_text(encoding="utf-8")
old = "    private var bridge: OpaquePointer?\n"
new = "    private var bridge: UnsafeMutablePointer<N60TargetedRoomMeasurementBridge>?\n"
if text.count(old) != 1:
    raise SystemExit(f"expected exactly one bridge ownership declaration, found {text.count(old)}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
print("targeted bridge pointer ownership fixed")
