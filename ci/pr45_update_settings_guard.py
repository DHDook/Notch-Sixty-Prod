#!/usr/bin/env python3
from pathlib import Path

path = Path("ci/validate_pr42_app_shell.py")
text = path.read_text(encoding="utf-8")

old = 'source = APP.read_text(encoding="utf-8")\nrequired = ['
new = 'source = APP.read_text(encoding="utf-8")\nroot_view = (ROOT / "NotchSixty" / "UI" / "ProductionRootView.swift").read_text(encoding="utf-8")\nrequired = ['
if text.count(old) != 1:
    raise SystemExit("unable to add ProductionRootView guard source")
text = text.replace(old, new, 1)

old = '    "SettingsLink",\n'
if text.count(old) != 1:
    raise SystemExit("unexpected SettingsLink guard count")
text = text.replace(old, "", 1)

old = '''for token in required:
    if token not in source:
        fail(f"missing app-shell contract token: {token}")
'''
new = '''for token in required:
    if token not in source:
        fail(f"missing app-shell contract token: {token}")

if "SettingsLink" not in root_view or 'Label("Settings", systemImage: "gearshape")' not in root_view:
    fail("Settings must be exposed from the main production window toolbar")
'''
if text.count(old) != 1:
    raise SystemExit("unable to extend Settings placement guard")
text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
print("PR42 Settings placement guard updated")
