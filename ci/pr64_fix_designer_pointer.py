#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/Audio/MultichannelCalibrationDesigner.swift")
text = path.read_text(encoding="utf-8")
needle = "targetBuffer.baseAddress,"
count = text.count(needle)
if count != 2:
    raise SystemExit(f"expected exactly 2 target buffer pointer sites, found {count}")
text = text.replace(needle, "targetBuffer.baseAddress!,")
path.write_text(text, encoding="utf-8")
