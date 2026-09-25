from pathlib import Path

path = Path("NotchSixty/NotchSixtyApp.swift")
text = path.read_text()
text = text.replace('\\"', '"')
path.write_text(text)
