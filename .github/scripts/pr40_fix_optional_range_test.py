from pathlib import Path

path = Path('NotchSixtyTests/RoomCorrectionProjectControllerTests.swift')
text = path.read_text()
old = '''        XCTAssertEqual(design.effectiveCorrectionLowHz, 100, accuracy: 0.000_001)\n        XCTAssertEqual(design.effectiveCorrectionHighHz, 1_000, accuracy: 0.000_001)\n'''
new = '''        XCTAssertEqual(try XCTUnwrap(design.effectiveCorrectionLowHz), 100, accuracy: 0.000_001)\n        XCTAssertEqual(try XCTUnwrap(design.effectiveCorrectionHighHz), 1_000, accuracy: 0.000_001)\n'''
assert old in text
path.write_text(text.replace(old, new, 1))
