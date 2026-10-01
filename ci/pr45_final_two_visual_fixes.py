from pathlib import Path

root = Path(__file__).resolve().parents[1]

# 1) Hide the visible main-window title in the unified toolbar while retaining
# the semantic window title/id used by macOS and openWindow(id:).
app = root / "NotchSixty/NotchSixtyApp.swift"
text = app.read_text()
old = '''        .defaultSize(width: 1180, height: 780)\n\n        MenuBarExtra(\n'''
new = '''        .defaultSize(width: 1180, height: 780)\n        .windowToolbarStyle(.unified(showsTitle: false))\n\n        MenuBarExtra(\n'''
if old not in text:
    raise SystemExit("main window style anchor not found")
text = text.replace(old, new, 1)
app.write_text(text)

# 2) Remove HSplitView's rectangular pane chrome from Dynamics. The visual
# navigator/editor relationship does not require a draggable AppKit split pane.
dyn = root / "NotchSixty/UI/ProductionDynamicsView.swift"
text = dyn.read_text()
old = '''            HSplitView {\n                moduleNavigator\n                    .frame(minWidth: 250, idealWidth: 285, maxWidth: 330)\n\n                ScrollView {\n                    moduleEditor\n                        .padding(.horizontal, 4)\n                }\n                .frame(minWidth: 560)\n            }\n'''
new = '''            HStack(alignment: .top, spacing: 12) {\n                moduleNavigator\n                    .frame(minWidth: 250, idealWidth: 285, maxWidth: 330)\n\n                ScrollView {\n                    moduleEditor\n                        .padding(.horizontal, 4)\n                }\n                .frame(minWidth: 560)\n            }\n'''
if old not in text:
    raise SystemExit("Dynamics HSplitView anchor not found")
text = text.replace(old, new, 1)

# Make the final mask the last operation so neither the scroll host nor the
# glass compositor can paint outside the continuous rounded card.
old = '''        .scrollIndicators(.visible)\n        .background(.clear)\n        .clipShape(.rect(cornerRadius: 18))\n        .glassEffect(.regular, in: .rect(cornerRadius: 18))\n'''
new = '''        .scrollIndicators(.visible)\n        .background(.clear)\n        .glassEffect(.regular, in: .rect(cornerRadius: 18))\n        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))\n        .containerShape(RoundedRectangle(cornerRadius: 18, style: .continuous))\n'''
if old not in text:
    raise SystemExit("Dynamics navigator modifier anchor not found")
text = text.replace(old, new, 1)
dyn.write_text(text)

print("Applied final two visual acceptance fixes")
