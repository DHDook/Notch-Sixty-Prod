from pathlib import Path

path = Path("NotchSixtyTests/NotchSixtyTests.swift")
text = path.read_text()
text = text.replace("Float.squareRoot(2)", "Float(2).squareRoot()")
path.write_text(text)
print("PR34 Symmetry Balance Swift test bridge is present.")
