from pathlib import Path

path = Path("NotchSixtyTests/NotchSixtyTests.swift")
text = path.read_text()
old = "        XCTAssertGreaterThanOrEqual(Int(N60_MAX_EQ_RENDER_SLOTS), 1_024)"
new = "        let compiledCapacity = Int(N60_MAX_EQ_BANDS) * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)\n        XCTAssertGreaterThanOrEqual(compiledCapacity, 1_024)"

if new not in text:
    if old not in text:
        raise SystemExit("Expected Phase B render-capacity assertion was not found")
    text = text.replace(old, new, 1)
    path.write_text(text)

print("PR34 Phase B XCTest capacity assertion uses Swift-visible constants.")
