from pathlib import Path

path = Path("NotchSixty/Audio/RoomCorrectionTargetDesigner.swift")
text = path.read_text()
replacements = {
    "        let effectiveLow = max(parameters.correctionLowHz, measuredLow, firstFrequency)\n":
        "        let effectiveLow = max(max(parameters.correctionLowHz, measuredLow), firstFrequency)\n",
    "        let effectiveHigh = min(parameters.correctionHighHz, measuredHigh, lastFrequency)\n":
        "        let effectiveHigh = min(min(parameters.correctionHighHz, measuredHigh), lastFrequency)\n",
    """        let maximumPositive = max(
            leftCorrection.magnitudeDB.max() ?? 0,
            rightCorrection.magnitudeDB.max() ?? 0,
            0
        )
""":
    """        let maximumPositive = max(
            max(
                leftCorrection.magnitudeDB.max() ?? 0,
                rightCorrection.magnitudeDB.max() ?? 0
            ),
            0
        )
""",
}
for old, new in replacements.items():
    if new in text:
        continue
    if text.count(old) != 1:
        raise SystemExit(f"Unexpected min/max anchor: {old!r}, count={text.count(old)}")
    text = text.replace(old, new, 1)
path.write_text(text)
