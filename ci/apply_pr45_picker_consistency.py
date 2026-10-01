#!/usr/bin/env python3
from pathlib import Path

ROOT = Path("NotchSixty/UI/ProductionRootView.swift")
EQ = Path("NotchSixty/UI/ProductionEqualizerView.swift")
APP = Path("NotchSixty/NotchSixtyApp.swift")
CLOSURE = Path(".github/workflows/pr45-closure.yml")
VALIDATOR = Path("ci/validate_pr45_control_style.py")

MODIFIER_BLOCK = '''\nstruct ProductionGlassPickerChromeModifier: ViewModifier {\n    func body(content: Content) -> some View {\n        content\n            .glassEffect(.regular.interactive(), in: .capsule)\n    }\n}\n\nextension View {\n    func productionGlassPickerChrome() -> some View {\n        modifier(ProductionGlassPickerChromeModifier())\n    }\n}\n'''


def find_matching(text: str, start: int, opening: str, closing: str) -> int:
    assert text[start] == opening
    depth = 0
    i = start
    line_comment = False
    block_comment = 0
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""

        if line_comment:
            if ch == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if ch == "/" and nxt == "*":
                block_comment += 1
                i += 2
                continue
            if ch == "*" and nxt == "/":
                block_comment -= 1
                i += 2
                continue
            i += 1
            continue
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue

        if ch == "/" and nxt == "/":
            line_comment = True
            i += 2
            continue
        if ch == "/" and nxt == "*":
            block_comment = 1
            i += 2
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        if ch == opening:
            depth += 1
        elif ch == closing:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise RuntimeError(f"Unmatched {opening} beginning at {start}")


def add_picker_chrome(text: str) -> tuple[str, int]:
    insertions: list[tuple[int, str]] = []
    cursor = 0
    while True:
        found = text.find("Picker(", cursor)
        if found < 0:
            break
        open_paren = found + len("Picker")
        close_paren = find_matching(text, open_paren, "(", ")")
        j = close_paren + 1
        while j < len(text) and text[j].isspace():
            j += 1
        if j >= len(text) or text[j] != "{":
            cursor = close_paren + 1
            continue
        close_brace = find_matching(text, j, "{", "}")
        lookahead = text[close_brace + 1: close_brace + 220]
        if ".productionGlassPickerChrome()" not in lookahead:
            line_start = text.rfind("\n", 0, found) + 1
            indent = text[line_start:found]
            insertions.append((close_brace + 1, f"\n{indent}.productionGlassPickerChrome()"))
        cursor = close_brace + 1

    for position, insertion in reversed(insertions):
        text = text[:position] + insertion + text[position:]
    return text, len(insertions)


def add_root_modifier() -> None:
    text = ROOT.read_text()
    if "struct ProductionGlassPickerChromeModifier" not in text:
        marker = "import SwiftUI\n"
        assert marker in text
        text = text.replace(marker, marker + MODIFIER_BLOCK, 1)
    ROOT.write_text(text)


def patch_ui_files() -> int:
    total = 0
    for path in sorted(Path("NotchSixty/UI").glob("*.swift")):
        text = path.read_text()
        updated, count = add_picker_chrome(text)
        if count:
            path.write_text(updated)
            total += count
            print(f"{path}: styled {count} picker(s)")
    return total


def patch_production_app_pickers() -> int:
    text = APP.read_text()
    start_marker = "private struct ProductionMenuBarView: View {"
    end_marker = "\n@main\nstruct NotchSixtyApp: App {"
    assert start_marker in text and end_marker in text
    start = text.index(start_marker)
    end = text.index(end_marker)
    segment, count = add_picker_chrome(text[start:end])
    APP.write_text(text[:start] + segment + text[end:])
    print(f"{APP}: styled {count} production picker(s)")
    return count


def patch_eq_bypass() -> None:
    text = EQ.read_text()
    marker = '''                .toggleStyle(.switch)\n\n                Button {\n                    addBand()'''
    replacement = '''                .toggleStyle(.switch)\n                .fixedSize(horizontal: true, vertical: false)\n                .layoutPriority(1)\n\n                Button {\n                    addBand()'''
    assert marker in text, "EQ Bypass toggle layout marker not found"
    text = text.replace(marker, replacement, 1)
    EQ.write_text(text)


def write_validator() -> None:
    VALIDATOR.write_text(r'''#!/usr/bin/env python3
from pathlib import Path

ui_files = sorted(Path("NotchSixty/UI").glob("*.swift"))
root = Path("NotchSixty/UI/ProductionRootView.swift").read_text()
eq = Path("NotchSixty/UI/ProductionEqualizerView.swift").read_text()
app = Path("NotchSixty/NotchSixtyApp.swift").read_text()
profiles = Path("NotchSixty/UI/ProductionProfileToolbar.swift").read_text()

assert "struct ProductionGlassPickerChromeModifier" in root, "shared production picker chrome modifier missing"
assert ".glassEffect(.regular.interactive(), in: .capsule)" in root, "production picker chrome must use interactive Liquid Glass"

for path in ui_files:
    source = path.read_text()
    picker_count = source.count("Picker(")
    chrome_count = source.count(".productionGlassPickerChrome()")
    assert chrome_count == picker_count, f"{path}: {picker_count} Picker(s) but {chrome_count} production glass chrome modifier(s)"

start_marker = "private struct ProductionMenuBarView: View {"
end_marker = "\n@main\nstruct NotchSixtyApp: App {"
assert start_marker in app and end_marker in app, "production app-shell bounds not found"
production_shell = app.split(start_marker, 1)[1].split(end_marker, 1)[0]
assert production_shell.count(".productionGlassPickerChrome()") == production_shell.count("Picker("), "tray/settings Picker styling is incomplete"

bypass_start = eq.index('Toggle("Bypass"')
bypass_end = eq.index('Button {\n                    addBand()', bypass_start)
bypass = eq[bypass_start:bypass_end]
assert ".fixedSize(horizontal: true, vertical: false)" in bypass, "EQ Bypass must remain single-line"
assert ".layoutPriority(1)" in bypass, "EQ Bypass must keep enough layout priority to avoid wrapping"

assert profiles.count(".buttonStyle(.glass)") >= 2, "Content/System toolbar menus must retain glass button styling"
print("PR45 production control-style guard passed")
''')


def patch_closure_workflow() -> None:
    text = CLOSURE.read_text()
    step = '''\n      - name: Validate PR45 production control styling\n        run: python3 ci/validate_pr45_control_style.py\n'''
    if "Validate PR45 production control styling" not in text:
        anchor = "      - name: Validate PR45 v1 release hardening\n        run: python3 ci/validate_pr45_release_hardening.py\n"
        assert anchor in text
        text = text.replace(anchor, anchor + step, 1)
    CLOSURE.write_text(text)


add_root_modifier()
ui_count = patch_ui_files()
app_count = patch_production_app_pickers()
patch_eq_bypass()
write_validator()
patch_closure_workflow()
print(f"Styled {ui_count + app_count} production Picker controls in total")
